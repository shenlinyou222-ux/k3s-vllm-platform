#!/bin/bash
# ══════════════════════════════════════════════════════════════
#  scripts/ci/target.sh —— 把 lib.sh 的 target profile 暴露给 Jenkinsfile
#
#  为什么需要它：
#    lib.sh 里的 DEPLOY / POD_SELECTOR / VERIFY_PY / BENCH_PY 是按
#    CI_TARGET 算出来的（march7 → vllm-march7，embed → vllm-embed）。
#    但 Jenkinsfile 的 stage 里有几处【内联的 kubectl 调用】（环境自检、
#    记录结果、post），它们需要一个 shell 变量。
#
#    Jenkinsfile 的设计原则是「不重复实现任何逻辑，只调 scripts/ci/ 下的脚本」
#    —— 所以不把 case 判断抄进 Jenkinsfile，而是从这里取：
#
#      eval "$(bash "$WORKSPACE/scripts/ci/target.sh")"
#      kubectl -n "$NS" get deploy "$DEPLOY" -o wide
#
#    ⚠️ 必须用 bash 调（agent 镜像的 /bin/sh 是 busybox ash，
#       没有 BASH_SOURCE，lib.sh 定位代码根会失败）。
#
#  用法：
#      eval "$(bash scripts/ci/target.sh)"     # 取赋值语句
#      bash scripts/ci/target.sh --print       # 人类可读
# ══════════════════════════════════════════════════════════════

source "$(dirname "$0")/lib.sh"

if [ "${1:-}" = "--print" ]; then
  printf 'CI_TARGET    = %s\n' "$TARGET"
  printf 'DEPLOY       = %s\n' "$DEPLOY"
  printf 'POD_SELECTOR = %s\n' "$POD_SELECTOR"
  printf 'NS           = %s\n' "$NS"
  printf 'CONTAINER    = %s\n' "$CONTAINER"
  printf 'VERIFY_PY    = %s\n' "$VERIFY_PY"
  printf 'BENCH_PY     = %s\n' "$BENCH_PY"
  printf 'BENCH_UNIT   = %s\n' "$BENCH_UNIT"
  printf 'BENCH_MIN    = %s\n' "$BENCH_MIN_DEFAULT"
  exit 0
fi

# 默认：输出可直接 eval 的赋值语句（值都不含空格，不需要引号）
cat <<EOF
TARGET=$TARGET
DEPLOY=$DEPLOY
POD_SELECTOR=$POD_SELECTOR
NS=$NS
CONTAINER=$CONTAINER
VERIFY_PY=$VERIFY_PY
BENCH_PY=$BENCH_PY
BENCH_UNIT=$BENCH_UNIT
BENCH_MIN_DEFAULT=$BENCH_MIN_DEFAULT
EOF
