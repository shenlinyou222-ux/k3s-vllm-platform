#!/bin/bash
# ══════════════════════════════════════════════════════════════
#  scripts/ci/deploy.sh —— ② 发布
#
#  做四件事：
#    1. kubectl apply -f k8s/live/（整个目录，不是单个文件）
#    2. ⭐ Deployment 的 spec 没变、但它引用的 ConfigMap 变了
#       → 自动补一次 rollout restart（否则就是"假成功"）
#    3. kubectl rollout status（等到就绪或超时）
#    4. 记录发布后的状态（供回滚对比）
#
#  ⚠️⚠️ 为什么必须有第 2 步：
#     k8s 不会因为 ConfigMap 变了就重建 pod（我们的 pod 模板上也没有
#     checksum 注解），而 vLLM 只在【启动时】读一次配置。
#     所以「改 CM → apply」在旧逻辑下的真实后果是：
#        CM 更新了 → pod 没重启 → 阶段④⑤⑥ 验证跑在【旧配置】的 pod 上
#        → 全绿 → 你以为上线了，其实没有。
#     这不是推测：pod 模板的 annotations 只有 kubectl.kubernetes.io/restartedAt，
#     vllm-observability-env 只通过 envFrom 消费、gencfg/logcfg 是启动时读的
#     文件挂载 —— 三条都实测确认过。
#     这里用 ConfigMap 的 resourceVersion 前后比对，把这种情况堵掉。
#
#  ⚠️ 前置：必须先跑过 precheck.sh（它做了备份 + diff 确认）
#
#  用法：  ./scripts/ci/deploy.sh
#          ./scripts/ci/deploy.sh --skip-precheck   （跳过前置检查，不推荐）
# ══════════════════════════════════════════════════════════════

source "$(dirname "$0")/lib.sh"

need_cmd kubectl
need_dir "$LIVE_DIR"

SKIP=0
[ "${1:-}" = "--skip-precheck" ] && SKIP=1

# ── 前置：确认跑过 precheck ──
if [ "$SKIP" = "0" ]; then
  stage "② 发布 —— 前置检查"
  BAK=$(state_read precheck_backup)
  if [ -z "$BAK" ] || [ ! -d "$BAK" ]; then
    die "没找到 precheck 的备份目录。请先跑 ./scripts/ci/precheck.sh（或用 --skip-precheck 强制）"
  fi
  ok "precheck 备份存在: $BAK"

  SNAP=$(state_read precheck_snapshot)
  [ -n "$SNAP" ] && [ -f "$SNAP" ] && ok "precheck 快照存在: $SNAP" || warn "没有快照（不影响发布，但回滚信息不全）"
fi

# ── 记录发布前状态 ──
#  ⚠️⚠️ 目标可能是【新建】的 Deployment（新增一个服务时）—— 此时 kubectl get 返回
#     NotFound，而 lib.sh 有 set -e → 脚本当场死掉，连 apply 都走不到。
#     实测（2026-10-08 构建 #24，新增 vllm-embed）：
#       Error from server (NotFound): deployments.apps "vllm-embed" not found
#       → ③ 发布阶段 FAILURE → 后面 ④⑤⑥⑦ 全被 skip
#     所以这里三处都加 2>/dev/null || true，并把「是不是新建」记进 state 供回滚用。
stage "② 发布 —— 记录发布前状态"
PRE_IMAGE=$(kubectl get deploy "$DEPLOY" -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
PRE_GEN=$(kubectl get deploy "$DEPLOY" -n "$NS" -o jsonpath='{.metadata.generation}' 2>/dev/null || true)
PRE_REV=$(kubectl rollout history deploy/"$DEPLOY" -n "$NS" -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}' 2>/dev/null || echo "?")

if [ -z "$PRE_IMAGE" ]; then
  warn "deploy/$DEPLOY 目前不存在 → 本次是【新建】"
  state_write "deploy_was_new" "1"
  PRE_IMAGE="（新建）"; PRE_GEN="（新建）"; PRE_REV="（新建）"
else
  state_write "deploy_was_new" "0"
fi
state_write "deploy_pre_image" "$PRE_IMAGE"
state_write "deploy_pre_gen" "$PRE_GEN"
state_write "deploy_pre_rev" "$PRE_REV"
info "发布前镜像: $PRE_IMAGE"
info "发布前 generation: $PRE_GEN"
info "发布前 revision: $PRE_REV"

# ══════════════════════════════════════════════════════════════
#  ⭐ 收集 Deployment 引用到的 ConfigMap（envFrom + volumes）
#     这些是「改了必须重启才生效」的东西
# ══════════════════════════════════════════════════════════════
refd_cms() {
  # ⚠️ 目标不存在（新建场景）时 kubectl get 会失败 → 空输入给 python 会抛异常。
  #    加 2>/dev/null + || true，让它安静地返回空。
  kubectl get deploy "$DEPLOY" -n "$NS" -o json 2>/dev/null | python3 -c '
import json,sys
try:
    ps=json.load(sys.stdin)["spec"]["template"]["spec"]
except Exception:
    print(""); raise SystemExit
names=set()
for c in ps.get("containers",[]):
    for x in (c.get("envFrom") or []):
        n=(x.get("configMapRef") or {}).get("name")
        if n: names.add(n)
for v in (ps.get("volumes") or []):
    n=(v.get("configMap") or {}).get("name")
    if n: names.add(n)
print(" ".join(sorted(names)))' 2>/dev/null || true
}

cm_rv() {   # cm_rv <name> → resourceVersion（对象不存在则 MISSING）
  kubectl get cm "$1" -n "$NS" -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null || echo MISSING
}

REFS=$(refd_cms)
RV_BEFORE=$(mktemp)
for c in $REFS; do printf '%s %s\n' "$c" "$(cm_rv "$c")" >> "$RV_BEFORE"; done
info "Deployment 引用的 ConfigMap: ${REFS:-（无）}"

# ── 应用 ──
stage "② 发布 —— kubectl apply -f k8s/live/"
if ! kubectl apply -f "$LIVE_DIR" 2>&1 | tee "$LOG_DIR/apply-$(date +%Y%m%d-%H%M%S).txt"; then
  die "apply 失败"
fi

# ── 判断该不该重启 ──
CHANGED=""
for c in $REFS; do
  old=$(awk -v k="$c" '$1==k{print $2}' "$RV_BEFORE")
  now=$(cm_rv "$c")
  [ "$now" = "$old" ] || CHANGED="$CHANGED $c"
done
rm -f "$RV_BEFORE"

POST_GEN=$(kubectl get deploy "$DEPLOY" -n "$NS" -o jsonpath='{.metadata.generation}')

if [ "$POST_GEN" != "$PRE_GEN" ]; then
  ok "generation: $PRE_GEN → $POST_GEN（Deployment 的 spec 变了，k8s 会自动重建 pod）"
  state_write "deploy_restarted" "0"
elif [ -n "$CHANGED" ]; then
  warn "Deployment 的 spec 没变（generation 仍为 $PRE_GEN），但它引用的 ConfigMap 变了:$CHANGED"
  info "vLLM 只在启动时读一次配置 → 自动补一次 rollout restart"
  info "（少了这一步就是【假成功】：CM 更新了、pod 却还跑着旧配置，而验证照样全绿）"
  kubectl rollout restart deploy/"$DEPLOY" -n "$NS" | sed 's/^/   /'
  state_write "deploy_restarted" "1"
else
  warn "generation 没变（$PRE_GEN），引用的 ConfigMap 也没变"
  info "本次差异只涉及非 Pod 资源（Service / PVC / PV / StorageClass）→ 已 apply，不需要重启"
  state_write "deploy_restarted" "0"
fi

# ── 等待就绪 ──
stage "② 发布 —— 等待 rollout（2B 需要 3-5 分钟）"
if ! kubectl rollout status deploy/"$DEPLOY" -n "$NS" --timeout=900s; then
  fail "rollout 超时/失败"
  echo
  warn "诊断信息："
  kubectl get pods -l "$POD_SELECTOR" -n "$NS" | sed 's/^/     /'
  kubectl describe pod -l "$POD_SELECTOR" -n "$NS" 2>/dev/null | tail -30 | sed 's/^/     /'
  die "请执行 ./scripts/ci/rollback.sh 回滚"
fi

# ── 记录发布后状态 ──
stage "② 发布 —— 记录发布后状态"
POST_IMAGE=$(kubectl get deploy "$DEPLOY" -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].image}')
# ⚠️ 用 target_pod 而不是直接 jsonpath items[0] —— 缩容到 0 时 items 为空数组，
#    jsonpath 会报 "array index out of bounds" 并让 set -e 挂掉整个脚本
#    （实测 2026-10-08 构建 #33 就死在这一行，还触发了没必要的自动回滚）
POST_POD=$(target_pod)
state_write "deploy_post_image" "$POST_IMAGE"
state_write "deploy_post_gen" "$POST_GEN"
state_write "deploy_post_pod" "$POST_POD"
state_write "deploy_time" "$(date +%Y%m%d-%H%M%S)"

kubectl get pods -l "$POD_SELECTOR" -n "$NS" | sed 's/^/     /'
info "镜像: $PRE_IMAGE"
info "    → $POST_IMAGE"

stage "② 发布完成"
ok "pod: $POST_POD"
echo
info "下一步: ./scripts/ci/verify.sh   （日志验证 + 功能验证 + 性能基准）"
warn "如果验证失败: ./scripts/ci/rollback.sh"
