#!/bin/bash
# ══════════════════════════════════════════════════════════════
#  scripts/ci/lib.sh —— CI/CD 公共库
#
#  设计原则（每条都来自 2026-10-06 那次实战的教训）：
#    ① 失败即停（set -euo pipefail），不要"看起来成功了"
#    ② 每步有判据，判据不通过就 die
#    ③ 绝对路径，禁止相对路径
#    ④ 改之前先备份，且备份要可验证
#    ⑤ 破坏性操作要人工确认
#    ⑥ 记录状态（镜像 tag / 提交号），否则无法回滚
# ══════════════════════════════════════════════════════════════

set -euo pipefail

# ── 路径 ──
# ⭐ 代码根【自己定位】，不写死 /srv/k3s-vllm-platform —— 同一份脚本在两种场景都对：
#      · Jenkins：脚本在 agent 的 workspace 检出里 → REPO = 检出目录
#        ⇒ 部署的就是【SCM 里那一版】，宿主工作区里没提交的改动影响不到它
#      · 本地手工：脚本在仓库里 → REPO = 仓库根
#    （用 BASH_SOURCE 而不是 $0：lib.sh 是被 source 的，$0 是调用者的路径）
CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$CI_DIR/../.." && pwd)"

# ⭐⭐ 线上资源清单目录 —— 这个目录下的每个 .yaml 都会被 apply
#    这是「仓库 = 唯一事实来源」的落点：
#      · 新增资源 → 往这里丢一个 yaml
#      · 修改资源 → 直接改对应文件（commit + push 后流水线才会部署）
#      · 删除资源 → ⚠️ 删文件【不会】删掉集群里的对象（apply 不删东西），
#                   要手工 kubectl delete
#    历史上这里是单个文件 k8s/vllm-mongo.yaml，只有它被管；
#    vllm-gencfg-2b / vllm-uvicorn-logcfg 两个 CM 只活在集群里（由一次性的
#    _*.sh 创建，而 _*.sh 被 .gitignore 排除）→ 从 main 重建集群会让 pod 起不来，
#    kubectl diff 也看不见它们的漂移。2026-10-07 导出并纳管。
LIVE_DIR="$REPO/k8s/live"

# ── 产物目录（state / 备份 / diff 日志）──
# ⚠️ 必须【持久化】，所以 Jenkins 里它落在宿主仓库，而不是 $REPO/logs：
#    agent 的 workspace 是 emptyDir，post.always 的 cleanWs() 会把它清掉，
#    那样回滚要用的 state 和备份就丢了。
#    Jenkinsfile 显式传 CI_ARTIFACT_DIR；本地跑就落在仓库自己的 logs/ci。
ARTIFACT_DIR="${CI_ARTIFACT_DIR:-$REPO/logs/ci}"
LOG_DIR="$ARTIFACT_DIR"
STATE_DIR="$LOG_DIR/state"

# ── 模型权重仓库 ──
# 宿主上的模型目录：PV models-pv 指向的就是它，Deployment 把它挂到容器里的 /models。
# agent pod 也靠 hostPath 挂到【相同路径】，这样预检才能校验权重本身
# （见 scripts/ci/check-models.py —— 补上 kubectl diff 看不见的那一半）。
MODELS_DIR="${CI_MODELS_DIR:-/home/user/npc-models}"
# 模型指纹清单：故意【不带】.yaml/.json 后缀 ——
# 否则 `kubectl apply -f k8s/live/` 会把它当资源去解析（kubectl 只挑
# .json/.yaml/.yml，README.md 就是这么被忽略的）。
MODELS_LOCK="${CI_MODELS_LOCK:-$LIVE_DIR/models.lock}"

# ── 目标对象（⭐ 按 CI_TARGET 选 profile）──
#  一个集群里现在有两个 vLLM 服务，脚本必须知道该管哪一个 / 该跑哪套验证：
#
#    march7（默认）  生成式 LLM  vllm-march7  验证 verify-march7.py  门槛 tok/s ≥ 100
#    embed           向量服务    vllm-embed   验证 verify-embed.py   门槛 req/s ≥ 20
#
#  默认值保持 march7 —— 不传 CI_TARGET 时行为与之前【完全一致】。
#  Jenkins 侧由 Jenkinsfile 的 TARGET 参数映射成 CI_TARGET 传进来。
#
#  ⚠️ 两个服务用同一个 label 规则（app = Deployment 名），
#     所以下面所有 `-l app=...` 一律写 "$POD_SELECTOR"，不再写死。
TARGET="${CI_TARGET:-march7}"
case "$TARGET" in
  march7)
    DEPLOY=vllm-march7
    CONTAINER=vllm
    VERIFY_PY=verify-march7.py
    BENCH_PY=bench.py
    BENCH_UNIT="tok/s"
    BENCH_MIN_DEFAULT=100
    ;;
  embed)
    DEPLOY=vllm-embed
    CONTAINER=vllm
    VERIFY_PY=verify-embed.py
    BENCH_PY=bench-embed.py
    BENCH_UNIT="req/s"
    BENCH_MIN_DEFAULT=20
    ;;
  *)
    printf '未知 CI_TARGET=%s（可选 march7|embed）\n' "$TARGET" >&2
    exit 1
    ;;
esac
NS=default
POD_SELECTOR="app=$DEPLOY"

# ── 颜色 ──
if [ -t 1 ]; then
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_0=$'\033[0m'
else
  C_R=; C_G=; C_Y=; C_B=; C_0=
fi

mkdir -p "$LOG_DIR" "$STATE_DIR"

# ── 日志 ──
ts()   { date '+%H:%M:%S'; }
info() { printf '%s[%s]%s %s\n' "$C_B" "$(ts)" "$C_0" "$*"; }
ok()   { printf '%s[%s] ✅%s %s\n' "$C_G" "$(ts)" "$C_0" "$*"; }
warn() { printf '%s[%s] ⚠️%s %s\n' "$C_Y" "$(ts)" "$C_0" "$*"; }
fail() { printf '%s[%s] ❌%s %s\n' "$C_R" "$(ts)" "$C_0" "$*" >&2; }
die()  { fail "$*"; exit 1; }

# ── 阶段标题 ──
stage() {
  echo
  printf '%s══════════════════════════════════════════════════%s\n' "$C_B" "$C_0"
  printf '%s  %s%s\n' "$C_B" "$*" "$C_0"
  printf '%s══════════════════════════════════════════════════%s\n' "$C_B" "$C_0"
}

# ── 判据：命令存在 ──
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

# ── 判据：文件存在 ──
need_file() {
  [ -f "$1" ] || die "缺少文件: $1"
}

# ── 判据：目录存在 ──
need_dir() {
  [ -d "$1" ] || die "缺少目录: $1"
}

# ── live 目录里的所有清单文件（排序保证顺序稳定，便于比对）──
live_files() {
  find "$LIVE_DIR" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) | sort
}

# ── 目标是否被缩容到 0 副本 ──
#   ⭐ 2026-10-08 加：march7 为了把 GPU 让给别的模型被缩到 replicas=0。
#      缩容后有一堆「看着正常、实际会崩」的写法，必须统一处理（见 target_pod）。
target_scaled_to_zero() {
  [ "$(kubectl get deploy "$DEPLOY" -n "$NS" -o jsonpath='{.spec.replicas}' 2>/dev/null)" = "0" ]
}

# ── 取目标的 pod 名（没有 pod 时返回占位符，不报错）──
#   ⚠️⚠️ 千万不要直接写：
#         kubectl get pods -l "$POD_SELECTOR" -o jsonpath='{.items[0].metadata.name}'
#      目标缩容到 0 时 items 是【空数组】→ jsonpath 报
#         error executing jsonpath "{.items[0].metadata.name}":
#         array index out of bounds: index 0, length 0
#      → 非 0 退出 → lib.sh 的 set -e 让整个脚本当场挂掉。
#      实测（2026-10-08 构建 #33）：deploy.sh 的「记录发布后状态」死在这里，
#      发布阶段 FAILURE → 触发了一次完全没必要的自动回滚。
target_pod() {
  local p
  p=$(kubectl get pods -l "$POD_SELECTOR" -n "$NS" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -n "$p" ]; then
    printf '%s' "$p"
  elif target_scaled_to_zero; then
    printf '%s' "（已缩容到 0 副本）"
  else
    printf '%s' "（暂无 pod）"
  fi
}

# ── vLLM 端点探测（宿主 / Jenkins agent pod 都能用）──
#    ⚠️ 不要用 `hostname -I`：agent 镜像是 Alpine，busybox 的 hostname
#       不支持 -I（打到 stderr、stdout 为空、rc 还是 0）→ 拼出空 URL。
#       2026-10-07 构建 #9 就死在这上面（verify-march7.py 里）。
#    探测顺序与 scripts/ci/endpoint.py 保持一致（同样是按 TARGET 选服务）：
#      $VLLM_URL → 集群内 Service → 本机 IP 的 NodePort
#    ⭐ 多目标：Service 名/端口、NodePort 都跟着 $TARGET 走（见上面的 profile）
vllm_base_url() {
  local svc_port nodeports
  case "$TARGET" in
    embed) svc_port="http://vllm-embed.default.svc.cluster.local:8000"; nodeports="30802" ;;
    *)     svc_port="http://vllm-march7.default.svc.cluster.local:8001"; nodeports="30800 30801" ;;
  esac
  local c ip p
  for c in "${VLLM_URL:-}" "$svc_port"; do
    [ -n "$c" ] || continue
    if [ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "${c}/health" 2>/dev/null)" = "200" ]; then
      echo "$c"; return 0
    fi
  done
  local ips
  ips=$(python3 -c "
import socket
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.connect(('10.255.255.255', 1))
    print(s.getsockname()[0]); s.close()
except Exception:
    pass" 2>/dev/null)
  for ip in $ips; do
    [ -n "$ip" ] || continue
    for p in $nodeports; do
      c="http://${ip}:${p}"
      if [ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "${c}/health" 2>/dev/null)" = "200" ]; then
        echo "$c"; return 0
      fi
    done
  done
  return 1
}

# ── 判据：断言为真 ──
assert() {
  local desc="$1"; shift
  if "$@"; then ok "$desc"; else die "判据不通过: $desc"; fi
}

# ── 人工确认（用于破坏性操作）──
confirm() {
  local prompt="${1:-继续？}"
  if [ "${CI_YES:-0}" = "1" ]; then
    warn "$prompt （CI_YES=1，自动确认）"
    return 0
  fi
  printf '%s%s [y/N] %s' "$C_Y" "$prompt" "$C_0"
  read -r ans
  case "$ans" in y|Y|yes|YES) return 0 ;; *) die "用户取消" ;; esac
}

# ── 读/写状态（供回滚用）──
state_write() {  # state_write <key> <value>
  printf '%s\n' "$2" > "$STATE_DIR/$1"
}
state_read() {   # state_read <key>  → stdout
  [ -f "$STATE_DIR/$1" ] && cat "$STATE_DIR/$1" || echo ""
}

# ── 当前线上状态快照 ──
snapshot() {
  local f="$LOG_DIR/snapshot-$(date +%Y%m%d-%H%M%S).json"
  kubectl get deploy "$DEPLOY" -n "$NS" -o json 2>/dev/null \
    | python3 -c '
import json,sys
d=json.load(sys.stdin)
c=d["spec"]["template"]["spec"]["containers"][0]
print(json.dumps({
  "generation": d["metadata"].get("generation"),
  "image": c["image"],
  "args": c["args"],
  "env": {e["name"]: e.get("value") for e in c.get("env",[])},
  "envFrom": [x.get("configMapRef",{}).get("name") for x in c.get("envFrom",[])],
  "volumes": [v for v in d["spec"]["template"]["spec"]["volumes"]],
  "replicas": d["spec"]["replicas"],
}, ensure_ascii=False, indent=2))' > "$f" || true
  echo "$f"
}

# ── 检查工作区是否干净 ──
#    在 Jenkins 里 $REPO 是 SCM 检出的目录 → 天然干净，这个判据是自动成立的
#    （部署源就是检出内容，不可能带上没提交的改动）。
#    留着它主要是给【本地手工跑】兜底：本地 $REPO 是仓库根，可能带着未提交改动。
require_clean_git() {
  local dirty
  dirty=$(git -C "$REPO" status --porcelain | wc -l)
  if [ "$dirty" -gt 0 ]; then
    warn "工作区有 $dirty 处未提交改动："
    git -C "$REPO" status --short | head -20 | sed 's/^/     /'
    if [ "${CI_ALLOW_DIRTY:-0}" != "1" ]; then
      die "请先提交（或设 CI_ALLOW_DIRTY=1 强制继续）"
    fi
    warn "CI_ALLOW_DIRTY=1，继续"
  else
    ok "git 工作区干净"
  fi
}

# ── 记录 git 信息 ──
git_info() {
  printf 'commit=%s\nbranch=%s\ndirty=%s\n' \
    "$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo none)" \
    "$(git -C "$REPO" branch --show-current 2>/dev/null || echo none)" \
    "$(git -C "$REPO" status --porcelain | wc -l)"
}
