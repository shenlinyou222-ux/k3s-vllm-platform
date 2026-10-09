#!/bin/bash
# ══════════════════════════════════════════════════════════════
#  scripts/ci/verify.sh —— ③ 验证（日志 + 功能 + 性能）
#
#  ⭐ 按 CI_TARGET 选一套判据（profile 定义在 lib.sh）：
#
#    march7（生成式 LLM，vllm-march7）
#      ① 日志层：V2 runner / 掩码生效 / 无 error
#      ② 功能层：三月七 prompt 正常 + 英文被挡 + 无乱码（verify-march7.py）
#      ③ 性能层：稳态吞吐 ≥ 100 tok/s（bench.py）
#
#    embed（向量服务，vllm-embed）
#      ① 日志层：启动完成 / 池化配置解析正确 / 无 error
#      ② 功能层：服务端向量逐条比对本地 HF 参考向量 cos ≥ 0.999 + 语义序（verify-embed.py）
#      ③ 性能层：稳态 ≥ 20 req/s（bench-embed.py）
#
#  ⭐ 为什么 embedding 的判据不能是"返回了 768 维向量"：
#    池化方式（CLS/MEAN/LAST）、use_activation、dtype 三样配错任何一样，
#    服务照样返回形状正确的向量 —— 但语义是错的，下游读出头会全崩。
#    唯一可靠的判据是拿本地模型算出的参考向量逐条比对（见 verify-embed.py）。
#
#  ⭐ --layer 让 Jenkinsfile 的 ④⑤⑥ 三个阶段共用这一份逻辑
#    （Jenkinsfile 不重复实现任何判据 —— 这是这套流水线的设计原则）：
#      verify.sh --layer=log    只跑日志层
#      verify.sh --layer=func   只跑功能层
#      verify.sh --layer=bench  只跑性能层
#
#  ⚠️⚠️ 一个踩过的坑：不要写 `echo "$LOGS" | grep -q PATTERN`
#     lib.sh 里有 `set -o pipefail`，而 `grep -q` 命中后会【立刻退出】、
#     关掉管道 → 还在写的 echo 收到 SIGPIPE（退出码 141）→ pipefail 把整条
#     管道判成【失败】。于是：**命中了反而走 else 分支**。
#     实测（2026-10-08）：vllm-march7 的 pod 跑了 13h、日志 5495 行，
#     `echo "$LOGS" | grep -q "Using V2 Model Runner"` 明明能 grep 到，
#     却报「没找到」→ 日志层 2 项判据误判失败。
#     短日志（几十行）时 echo 能在 grep 退出前写完，所以这个 bug 一直潜伏
#     （Jenkins 里每次都是刚重启的新 pod → 日志短 → 从不触发）。
#     最危险的是"无错误"那条判据：日志里【真有 error】时会被误报成干净。
#     正确写法：用 here-string —— `grep -q PATTERN <<< "$LOGS"`
#     （here-string 没有上游进程，不存在 SIGPIPE）。
#
#  用法：  ./scripts/ci/verify.sh
#          CI_TARGET=embed ./scripts/ci/verify.sh
#          BENCH_MIN=120 ./scripts/ci/verify.sh    （提高性能门槛）
# ══════════════════════════════════════════════════════════════

source "$(dirname "$0")/lib.sh"

need_cmd kubectl
need_cmd python3

LAYERS="log func bench"
for a in "$@"; do
  case "$a" in
    --layer=*) LAYERS="${a#*=}" ;;
    *) die "未知参数: $a" ;;
  esac
done
want() { case " $LAYERS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

FAILS=0
check() {  # check <描述> <命令...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    ok "$desc"
  else
    fail "$desc"
    FAILS=$((FAILS + 1))
  fi
}

info "目标: $TARGET  →  deploy/$DEPLOY  功能验证 $VERIFY_PY  门槛 $BENCH_MIN_DEFAULT $BENCH_UNIT"
info "本次跑的层: $LAYERS"

# ⭐⭐ 目标被缩到 0 副本 → 【跳过】验证，不是失败。
#   2026-10-08 加：march7 为了把 GPU 让给别的模型被缩到 replicas=0。这时候：
#     · 没有 pod      → kubectl logs 拿不到 → 日志层会 die
#     · 服务不响应     → 功能层必然失败
#     · 没有请求       → 性能层必然失败
#   但这不是"发布失败"，是【刻意的缩容】。所以直接跳过并返回 0。
#   ⚠️ 跳过验证 ≠ 没发布：apply 仍然执行了（副本数确实被改成 0），只是没东西可验证。
if [ "$(kubectl get deploy "$DEPLOY" -n "$NS" -o jsonpath='{.spec.replicas}' 2>/dev/null)" = "0" ]; then
  warn "deploy/$DEPLOY 的 replicas=0（已缩容，不提供服务）→ 跳过验证"
  info "恢复方式：把 k8s/live/ 里对应的 replicas 改回 1 → commit → push"
  stage "③ 验证结果（跳过）"
  ok "缩容状态，无需验证 ✅"
  exit 0
fi

# ══════════ ① 日志层 ══════════
if want log; then
stage "③ 验证 —— 日志层"
LOGS=$(kubectl logs deploy/"$DEPLOY" -n "$NS" -c "$CONTAINER" 2>/dev/null || echo "")

if [ -z "$LOGS" ]; then
  die "拿不到日志（pod 可能没起来）"
fi
info "日志 $(( $(printf '%s' "$LOGS" | wc -l) )) 行"

if [ "$TARGET" = "march7" ]; then
  # ①-1 用的是 V2 runner（不是回退的 V1）
  #      ⚠️ here-string，不是管道 —— 见文件头 SIGPIPE 的说明
  if grep -q "Using V2 Model Runner" <<< "$LOGS"; then
    ok "Model Runner = V2"
  else
    if grep -q "does not yet support" <<< "$LOGS"; then
      fail "Model Runner 回退到 V1（自定义 logits processor 触发的）"
    else
      fail "没找到 'Using V2 Model Runner'"
    fi
    FAILS=$((FAILS + 1))
  fi

  # ①-2 掩码生效
  if grep -q "overridden by /gencfg" <<< "$LOGS"; then
    N=$(grep -o "logit_bias" <<< "$LOGS" | wc -l)
    ok "掩码生效（日志里有 logit_bias，$N 行）"
  else
    fail "掩码没生效（日志里没有 'overridden by /gencfg'）"
    warn "常见原因：/gencfg/generation_config.json 里带了 _from_model_config（会让 HF 丢掉 logit_bias）"
    FAILS=$((FAILS + 1))
  fi
else
  # ⭐ embed：服务起来了
  if grep -qE "Application startup complete|Starting vLLM server" <<< "$LOGS"; then
    ok "vLLM API server 启动完成"
  else
    fail "日志里没有启动完成的迹象"
    FAILS=$((FAILS + 1))
  fi

  # ⭐⭐ embed 的关键日志判据（实测的真实输出，2026-10-08）：
  #   Resolved pooling config: pooling_type=CLS(source=sentence_transformers),
  #     tok_pooling_type=ALL(source=model_default),
  #     use_activation=False(source=user), supported_tasks=('embed', 'token_embed')
  #
  #   这一行把三个最容易配错的旋钮全暴露了：
  #     · pooling_type    —— 必须 CLS（dmeta 的 1_Pooling/config.json 要求；
  #                          实测 vLLM 是 source=sentence_transformers 自动读到的）
  #     · use_activation  —— 必须 False（我们显式传的 --pooler-config）
  #     · supported_tasks —— 必须含 embed（证明 --runner=pooling 生效）
  #   配错的后果是「照样返回 768 维向量，但语义错」→ 下游读出头全崩，
  #   所以要在日志层就卡住，而不是等人工发现。
  if grep -q "Resolved pooling config" <<< "$LOGS"; then
    POOL_LINE=$(grep -o "Resolved pooling config: .*" <<< "$LOGS" | tail -1)
    ok "池化配置已解析：$POOL_LINE"
    if grep -q "pooling_type=CLS" <<< "$POOL_LINE"; then
      ok "pooling_type = CLS"
    else
      fail "pooling_type 不是 CLS（dmeta 要求 CLS 池化）"
      FAILS=$((FAILS + 1))
    fi
    if grep -q "use_activation=False" <<< "$POOL_LINE"; then
      ok "use_activation = False（读出头是在未归一化向量上训的）"
    else
      fail "use_activation 不是 False —— 向量会被 L2 归一化，与训练时分布不符"
      FAILS=$((FAILS + 1))
    fi
    if grep -q "embed" <<< "$POOL_LINE"; then
      ok "supported_tasks 含 embed（--runner=pooling 生效）"
    else
      fail "supported_tasks 里没有 embed —— runner 没走 pooling"
      FAILS=$((FAILS + 1))
    fi
  else
    fail "日志里没有 'Resolved pooling config'（vLLM 没能确定池化方式）"
    FAILS=$((FAILS + 1))
  fi
fi

# ①-3 无错误（两个 target 通用）
#      ⚠️ 这条尤其不能写成管道：日志【真有 error】时管道会因 SIGPIPE 判失败，
#         于是走 else 分支报「无 error」—— 假阴性，方向最危险。
if grep -qi -e "traceback" -e "error" -e "exception" <<< "$LOGS"; then
  fail "日志里有错误："
  grep -i -e "traceback" -e "error" -e "exception" <<< "$LOGS" | head -5 | sed 's/^/       /'
  FAILS=$((FAILS + 1))
else
  ok "日志无 error / traceback"
fi
fi

# ══════════ ② 功能层 ══════════
if want func; then
stage "③ 验证 —— 功能层（$VERIFY_PY）"
if python3 "$CI_DIR/$VERIFY_PY"; then
  ok "功能验证通过"
else
  fail "功能验证失败"
  FAILS=$((FAILS + 1))
fi
fi

# ══════════ ③ 性能层 ══════════
if want bench; then
stage "③ 验证 —— 性能层（$BENCH_PY，门槛 $BENCH_MIN_DEFAULT $BENCH_UNIT）"
BENCH_MIN="${BENCH_MIN:-$BENCH_MIN_DEFAULT}"
BENCH_OUT="$LOG_DIR/bench-$(date +%Y%m%d-%H%M%S).txt"
if python3 "$CI_DIR/$BENCH_PY" 2>&1 | tee "$BENCH_OUT" | tail -8; then
  if [ "$BENCH_UNIT" = "tok/s" ]; then
    VAL=$(grep -oE '平均 tok/s  = [0-9.]+' "$BENCH_OUT" | grep -oE '[0-9.]+' || echo 0)
  else
    VAL=$(grep -oE '平均 req/s  = [0-9.]+' "$BENCH_OUT" | grep -oE '[0-9.]+' || echo 0)
  fi
  info "稳态: $VAL $BENCH_UNIT（门槛 $BENCH_MIN）"
  if python3 -c "import sys; sys.exit(0 if float('$VAL') >= float('$BENCH_MIN') else 1)"; then
    ok "性能达标"
  else
    fail "性能不达标（$VAL < $BENCH_MIN）"
    FAILS=$((FAILS + 1))
  fi
else
  fail "性能基准跑失败"
  FAILS=$((FAILS + 1))
fi
fi

# ══════════ 汇总 ══════════
stage "③ 验证结果（$LAYERS）"
if [ "$FAILS" -gt 0 ]; then
  fail "$FAILS 项判据未通过"
  echo
  warn "⇒ 请执行: CI_TARGET=$TARGET ./scripts/ci/rollback.sh"
  exit 1
fi
ok "全部判据通过 ✅"
[ -n "${BENCH_OUT:-}" ] && info "日志: $BENCH_OUT"
exit 0
