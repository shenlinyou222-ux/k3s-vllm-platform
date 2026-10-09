#!/bin/bash
# ══════════════════════════════════════════════════════════════
#  scripts/ci/pipeline.sh —— 一键流水线（本地版 Jenkins）
#
#  流程：
#     预检 → 发布 → 验证
#     任一失败 → 自动回滚
#
#  这就是 Jenkinsfile 会调的那套东西。写在这里是为了：
#    ① 手工能跑（不依赖 Jenkins）
#    ② Jenkins 上线后，Jenkinsfile 只是换个地方调它
#
#  用法：
#     ./scripts/ci/pipeline.sh                  # 全流程（人工确认 diff）
#     CI_YES=1 ./scripts/ci/pipeline.sh         # 无人值守
#     ./scripts/ci/pipeline.sh --no-verify      # 跳过验证（不推荐）
#     ./scripts/ci/pipeline.sh --restart-only   # 只重启（ConfigMap 改动）
#     ./scripts/ci/pipeline.sh --dry           # 只预检
# ══════════════════════════════════════════════════════════════

source "$(dirname "$0")/lib.sh"

need_cmd kubectl

DO_VERIFY=1
MODE="full"
for a in "$@"; do
  case "$a" in
    --no-verify)    DO_VERIFY=0 ;;
    --restart-only) MODE="restart" ;;
    --dry)          MODE="dry" ;;
    *) die "未知参数: $a" ;;
  esac
done

START=$(date +%s)
stage "流水线开始"
git_info | sed 's/^/   /'
info "模式: $MODE  验证: $DO_VERIFY  自动确认: ${CI_YES:-0}"

# ══════════ 只重启模式 ══════════
if [ "$MODE" = "restart" ]; then
  bash "$CI_DIR/restart.sh" || { fail "重启失败"; exit 1; }
  if [ "$DO_VERIFY" = "1" ]; then
    bash "$CI_DIR/verify.sh" || {
      fail "验证失败 → 回滚"
      bash "$CI_DIR/rollback.sh"
      exit 1
    }
  fi
  ok "流水线完成（$(( $(date +%s) - START ))s）"
  exit 0
fi

# ══════════ 预检 ══════════
bash "$CI_DIR/precheck.sh"
PRECHECK_RC=$?
if [ "$PRECHECK_RC" = "2" ]; then
  warn "预检判定【无需发布】（Deployment 无差异）"
  warn "如果你改的是 ConfigMap，请用: ./scripts/ci/pipeline.sh --restart-only"
  exit 0
fi
if [ "$PRECHECK_RC" != "0" ]; then
  fail "预检失败（退出码 $PRECHECK_RC）—— 没有做任何改动"
  exit 1
fi

if [ "$MODE" = "dry" ]; then
  ok "只预检模式，结束（$(( $(date +%s) - START ))s）"
  exit 0
fi

# ══════════ 发布 ══════════
if ! bash "$CI_DIR/deploy.sh"; then
  fail "发布失败 → 尝试回滚"
  bash "$CI_DIR/rollback.sh" || fail "回滚也失败 —— 需要人工介入！"
  exit 1
fi

# ══════════ 验证 ══════════
if [ "$DO_VERIFY" = "1" ]; then
  if ! bash "$CI_DIR/verify.sh"; then
    fail "验证失败 → 自动回滚"
    bash "$CI_DIR/rollback.sh" || fail "回滚也失败 —— 需要人工介入！"
    exit 1
  fi
fi

# ══════════ 完成 ══════════
stage "流水线完成"
ok "耗时 $(( $(date +%s) - START ))s"
info "pod: $(target_pod)"
info "镜像: $(kubectl get deploy "$DEPLOY" -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].image}')"
echo
info "建议：把这次改动提交到 git"
echo "     git add -A && git commit -m '...'"
