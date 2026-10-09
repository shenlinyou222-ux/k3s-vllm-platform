#!/bin/bash
# ══════════════════════════════════════════════════════════════
#  scripts/ci/precheck.sh —— ① 预检
#
#  做五件事：
#    1. 检查 git 工作区干净
#    2. ⭐ 校验模型权重（路径存在 + 指纹没变）—— 见 check-models.py 的说明
#    3. 备份整个 k8s/live/ 目录（逐文件 md5 可验证）
#    4. kubectl apply --dry-run=server（服务端校验）
#    5. kubectl diff（显示差异，人工确认）+ 快照线上状态
#
#  ⭐ 管的是【一个目录】k8s/live/ 而不是一个文件 —— 那里面的每个 yaml
#     都会被 apply。新增资源就往里丢文件，不用改脚本。
#
#  为什么必须有这一步：
#    2026-10-06 实战中，kubectl diff 抓到了我误改的
#    `--max-num-seqs=64 → 2048` —— 没有 diff 就会静默上线。
#
#  用法：  ./scripts/ci/precheck.sh
#  跳过确认： CI_YES=1 ./scripts/ci/precheck.sh
# ══════════════════════════════════════════════════════════════

source "$(dirname "$0")/lib.sh"

need_cmd kubectl
need_cmd git
need_cmd python3

stage "① 预检 —— git 状态"
require_clean_git
git_info | sed 's/^/     /'

# ══════════════════════════════════════════════════════════════
#  ⭐ 预检 —— 模型权重校验
#
#  kubectl diff 只能看见【清单里写了什么】，看不见【路径背后是什么】。
#  所以有两种情况流水线原先完全无感，这里把它们提前暴露：
#
#    ① --model= 指向一个不存在的路径
#       → vLLM 加载失败 → rollout status 要等满 900s 才判失败
#       → 而这期间（strategy: Recreate）服务是完全 DOWN 的 → 才回滚。
#         最坏约 18 分钟中断。这一步在【秒级】就拦住。
#
#    ② 某个模型目录里的权重被【就地替换】了（路径没变）
#       → kubectl diff 为空 → 判「无需发布」→ 而 vLLM 还跑着旧权重。
#         靠 k8s/live/models.lock 里的 sha256 指纹比对抓出来。
# ══════════════════════════════════════════════════════════════
stage "① 预检 —— 模型权重校验"
if [ "${CI_SKIP_MODEL_CHECK:-0}" = "1" ]; then
  warn "CI_SKIP_MODEL_CHECK=1 → 跳过模型权重校验（不推荐）"
else
  python3 "$CI_DIR/check-models.py" || die "模型权重校验不通过 —— 见上面的说明"
fi

stage "① 预检 —— 备份当前 manifest 目录"
need_dir "$LIVE_DIR"
TS=$(date +%Y%m%d-%H%M%S)
BAK="$LOG_DIR/live-backup-$TS"
rm -rf "$BAK"
mkdir -p "$BAK"
cp -a "$LIVE_DIR"/. "$BAK"/

# ⭐ 备份必须可验证（逐文件 md5 一致才算备份成功）
NF=0
for f in $(live_files); do
  b="$BAK/$(basename "$f")"
  M1=$(md5sum "$f" | cut -d' ' -f1)
  M2=$(md5sum "${b}" | cut -d' ' -f1)
  [ "$M1" = "$M2" ] || die "备份校验失败：$(basename "$f")  $M1 != $M2"
  NF=$((NF + 1))
done
[ "$NF" -gt 0 ] || die "$LIVE_DIR 里没有 .yaml（是不是目录搞错了？）"
ok "备份已校验: $BAK"
ok "文件数 = $NF"
for f in $(live_files); do
  printf '     %s\n' "$(basename "$f")"
done

stage "① 预检 —— 服务端校验（dry-run）"
if ! kubectl apply -f "$LIVE_DIR" --dry-run=server 2>&1 | tee "$LOG_DIR/dryrun-$TS.txt"; then
  die "dry-run 失败，详见 $LOG_DIR/dryrun-$TS.txt"
fi
ok "服务端校验通过"

stage "① 预检 —— 差异（kubectl diff）"
DIFF_FILE="$LOG_DIR/diff-$TS.txt"
# kubectl diff 有差异时返回 1，这是正常的，所以不能 set -e 直接死
kubectl diff -f "$LIVE_DIR" > "$DIFF_FILE" 2>&1 || true

if [ ! -s "$DIFF_FILE" ]; then
  warn "没有差异 —— 线上已是最新，无需发布"
  warn "（改了东西却没有差异？检查两件事：文件是否放在 $LIVE_DIR/ 下、内容是否真的和集群不同）"
  exit 2          # ⭐ 用 2 而不是 0：让 pipeline.sh 能区分"无需发布"和"预检通过"
fi

echo "  差异如下（+ 新增 / - 删除）："
echo "  ────────────────────────────────────────────"
grep -E '^[+-]' "$DIFF_FILE" | grep -v '^[+-][+-]' | sed 's/^/  /'
echo "  ────────────────────────────────────────────"
echo "  完整 diff: $DIFF_FILE"

# ⭐ 差异统计 —— 帮人判断"这是不是我想改的"
ADD=$(grep -cE '^\+' "$DIFF_FILE" || true)
DEL=$(grep -cE '^-' "$DIFF_FILE" || true)
info "差异规模: +$ADD 行 / -$DEL 行"

stage "① 预检 —— 快照线上状态（供回滚）"
SNAP=$(snapshot)
ok "快照: $SNAP"
state_write "precheck_snapshot" "$SNAP"
state_write "precheck_backup" "$BAK"
state_write "precheck_diff" "$DIFF_FILE"
state_write "precheck_time" "$TS"

echo
warn "请【逐行核对】上面的差异，确认这就是你想改的"
confirm "确认无误，可以进入发布？"

stage "① 预检完成"
ok "备份  : $BAK"
ok "快照  : $SNAP"
ok "差异  : $DIFF_FILE"
echo
info "下一步: ./scripts/ci/deploy.sh"
