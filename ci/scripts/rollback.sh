#!/bin/bash
# ══════════════════════════════════════════════════════════════
#  scripts/ci/rollback.sh —— ④ 回滚
#
#  两种模式：
#    ① kubectl rollout undo（默认）—— 回上一版 Deployment，最快
#       ⚠️ 但它【只回滚 Deployment】。ConfigMap 的改动它管不了 ——
#          如果这次改的是 CM（gencfg / observability-env / logcfg），
#          必须用模式 ② 才能真的退回去。
#    ② --from-backup —— 用 precheck 的备份目录把【集群】还原到发布前
#                    再补一次 rollout restart（apply 不会重启 pod）
#       ⚠️ 它只改集群、不动仓库文件 —— 部署源是 SCM 检出，
#          要让仓库里的 k8s/live/ 也回退得 git revert 那个 commit
#    另外可加 --to-revision=N 指定版本
#
#  用法：  ./scripts/ci/rollback.sh              （自动回上一版）
#          ./scripts/ci/rollback.sh --to-revision=5
#          ./scripts/ci/rollback.sh --from-backup  （改的是 ConfigMap 时用它）
#          CI_YES=1 ./scripts/ci/rollback.sh       （跳过确认）
# ══════════════════════════════════════════════════════════════

source "$(dirname "$0")/lib.sh"

need_cmd kubectl
need_dir "$LIVE_DIR"

MODE="undo"
TO_REV=""
for a in "$@"; do
  case "$a" in
    --to-revision=*) TO_REV="${a#*=}" ;;
    --from-backup)   MODE="backup" ;;
    *) die "未知参数: $a" ;;
  esac
done

stage "④ 回滚 —— 当前状态"
kubectl get pods -l "$POD_SELECTOR" -n "$NS" 2>/dev/null | sed 's/^/   /' || true
echo
# ⚠️ 目标可能不存在（新建的发布失败时）→ kubectl get 会失败，加 || true 别把脚本带死
info "当前镜像: $(kubectl get deploy "$DEPLOY" -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo '（不存在）')"
info "generation: $(kubectl get deploy "$DEPLOY" -n "$NS" -o jsonpath='{.metadata.generation}' 2>/dev/null || echo '（不存在）')"

# ══════════ 模式 0：本次是【新建】→ 「回滚」= 删掉它 ══════════
#   rollout undo 对新建的 Deployment 无意义（没有上一版 revision，
#   实测报 "no rollout history"）。发布前它并不存在，所以正确的回滚是删除。
if [ "$(state_read deploy_was_new)" = "1" ] && [ "$MODE" != "backup" ]; then
  stage "④ 回滚 —— 本次是新建，删除即可"
  warn "deploy/$DEPLOY 在本次发布【之前并不存在】→ 没有上一版可 undo"
  info "正确的回滚 = 把它和它的 Service 一起删掉"
  confirm "确认删除 deploy/$DEPLOY 与 svc/$DEPLOY？"
  kubectl -n "$NS" delete deploy "$DEPLOY" --ignore-not-found | sed 's/^/   /'
  kubectl -n "$NS" delete svc "$DEPLOY" --ignore-not-found | sed 's/^/   /'
  ok "已删除 —— 集群回到发布前状态"
  state_write "rollback_time" "$(date +%Y%m%d-%H%M%S)"
  stage "④ 回滚完成（模式: delete-new）"
  exit 0
fi

stage "④ 回滚 —— rollout 历史"
kubectl rollout history deploy/"$DEPLOY" -n "$NS" 2>/dev/null | sed 's/^/   /' || true

# ══════════ 模式 A：用 precheck 的备份还原【集群】══════════
if [ "$MODE" = "backup" ]; then
  stage "④ 回滚 —— 用 precheck 备份把集群还原到发布前"
  BAK=$(state_read precheck_backup)
  if [ -z "$BAK" ] || [ ! -d "$BAK" ]; then
    die "找不到 precheck 备份目录（state: $STATE_DIR/precheck_backup）"
  fi
  info "备份目录: $BAK"
  echo
  echo "   将要还原的差异（当前 live/ ← 备份）："
  diff -r "$LIVE_DIR" "$BAK" | head -40 | sed 's/^/     /' || true
  echo
  warn "⚠️ 这一步只改【集群】，不动仓库文件。"
  warn "   部署源是 SCM 检出 —— 想让仓库里的 k8s/live/ 也回退，"
  warn "   得 git revert 掉引入这个改动的那次 commit。"
  confirm "确认用这份备份覆盖集群？"

  # ⭐ 直接 apply 备份目录，【不】往 $LIVE_DIR 里抄：
  #    在 Jenkins 里 $LIVE_DIR 是 agent 的临时检出（emptyDir），
  #    抄进去只会被 post 的 cleanWs() 清掉，还会造成
  #    "文件已经回退了" 的错觉 —— 其实仓库一点没变。
  kubectl apply -f "$BAK" | sed 's/^/   /'
  ok "集群已按备份还原"

  # ⚠️ apply 不会重启 pod：如果还原涉及 ConfigMap，必须显式 restart
  warn "apply 不会重启 pod —— 补一次 rollout restart 让配置真正生效"
  kubectl rollout restart deploy/"$DEPLOY" -n "$NS" | sed 's/^/   /'
  if ! kubectl rollout status deploy/"$DEPLOY" -n "$NS" --timeout=900s; then
    die "回滚后 rollout 仍失败 —— 需要人工介入"
  fi
  ok "回滚完成（模式: backup）"

# ══════════ 模式 B：rollout undo ══════════
else
  stage "④ 回滚 —— kubectl rollout undo"

  # ⭐⭐ rollout undo 只回滚 Deployment —— ConfigMap 它管不了。
  #     所以先把备份里的 ConfigMap 还原回去（不重启），再 undo；
  #     这样 undo 触发的那一次 pod 重建就会带上【旧配置】。
  #     少了这一步，"回滚"之后的 pod 会带着【新配置】重新起来 —— 等于没回滚。
  CM_RESTORED=0
  BAK=$(state_read precheck_backup)
  if [ -n "$BAK" ] && [ -d "$BAK" ]; then
    info "还原备份里的 ConfigMap（来自 $BAK）"
    for f in "$BAK"/*.yaml; do
      grep -q '^kind: ConfigMap' "$f" 2>/dev/null || continue
      out=$(kubectl apply -f "$f" 2>&1)
      # ⚠️ here-string 而不是 `echo "$out" | grep -q`：lib.sh 有 set -o pipefail，
      #    grep -q 命中后立刻退出 → echo 收 SIGPIPE(141) → 管道被判失败 →
      #    命中了反而走 else。详见 verify.sh 文件头的说明。
      if grep -q 'unchanged' <<< "$out"; then
        printf '     %-34s 与备份一致\n' "$(basename "$f")"
      else
        printf '     %-34s %s\n' "$(basename "$f")" "$(echo "$out" | tr '\n' ' ')"
        CM_RESTORED=$((CM_RESTORED + 1))
      fi
    done
    [ "$CM_RESTORED" -gt 0 ] && ok "$CM_RESTORED 个 ConfigMap 已还原到发布前" \
                             || ok "ConfigMap 本来就与备份一致"
  else
    warn "没有 precheck 备份目录 → 跳过 ConfigMap 还原"
    warn "（如果本次改的是 ConfigMap，这次回滚【不会】撤销它）"
  fi

  if [ -n "$TO_REV" ]; then
    info "目标 revision: $TO_REV"
    confirm "确认回滚到 revision $TO_REV？"
    kubectl rollout undo deploy/"$DEPLOY" -n "$NS" --to-revision="$TO_REV" | sed 's/^/   /'
  else
    confirm "确认回滚到上一版？"
    kubectl rollout undo deploy/"$DEPLOY" -n "$NS" | sed 's/^/   /'
  fi

  if ! kubectl rollout status deploy/"$DEPLOY" -n "$NS" --timeout=900s; then
    fail "回滚后 rollout 仍失败"
    echo
    warn "试试模式 A（从备份还原整个 k8s/live/）："
    echo "     ./scripts/ci/rollback.sh --from-backup"
    die "需要人工介入"
  fi
  ok "回滚完成（模式: undo，另还原了 $CM_RESTORED 个 ConfigMap）"
fi

# ══════════ 回滚后验证 ══════════
stage "④ 回滚 —— 验证"
kubectl get pods -l "$POD_SELECTOR" -n "$NS" | sed 's/^/   /'
echo
info "回滚后镜像: $(kubectl get deploy "$DEPLOY" -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].image}')"
info "generation: $(kubectl get deploy "$DEPLOY" -n "$NS" -o jsonpath='{.metadata.generation}')"

# 健康检查（⭐ 不用 hostname -I：agent 镜像的 busybox 不支持它）
# ⚠️ 目标缩容到 0 副本时【必然探测不到端点】—— 那不是回滚失败，是刻意的缩容。
#    不加这个判断的话，缩容状态下每次回滚都会打一行刺眼的 fail
#    （实测 2026-10-08 构建 #33 的日志里就出现了，看着像出事了其实没事）。
if target_scaled_to_zero; then
  warn "deploy/$DEPLOY 的 replicas=0（已缩容）→ 跳过端点健康检查与功能抽查"
else
  BASE_URL=$(vllm_base_url) || BASE_URL=""
  if [ -n "$BASE_URL" ]; then
    code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' "$BASE_URL/health" 2>/dev/null || echo ERR)
    if [ "$code" = "200" ]; then ok "$BASE_URL/health → 200"; else fail "$BASE_URL/health → $code"; fi
  else
    fail "探测不到可用的 vLLM 端点（集群内 Service 和宿主 NodePort 都不通）"
  fi

  # 功能抽查（按 target 选脚本：march7 → verify-march7.py / embed → verify-embed.py）
  echo
  info "功能抽查（$VERIFY_PY）:"
  if python3 "$CI_DIR/$VERIFY_PY" >/dev/null 2>&1; then
    ok "功能验证通过"
  else
    warn "功能验证未通过 —— 但回滚已完成，可能是回滚到的版本本身有问题"
  fi
fi

state_write "rollback_time" "$(date +%Y%m%d-%H%M%S)"
stage "④ 回滚完成"
