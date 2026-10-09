#!/bin/bash
# ══════════════════════════════════════════════════════════════
#  scripts/ci/restart.sh —— 只重启（用于 ConfigMap 类改动）
#
#  什么时候用：
#    改了 ConfigMap（掩码 / 日志格式 / env），但没改 Deployment。
#    vLLM 在【启动时】读一次配置，不会热加载 → 必须重启。
#
#  什么时候不用：
#    改了 Deployment 的 args/image → deploy.sh 会自动触发 pod 重建。
#
#  用法：  ./scripts/ci/restart.sh
# ══════════════════════════════════════════════════════════════

source "$(dirname "$0")/lib.sh"

need_cmd kubectl

stage "重启 —— 前置检查"
# restart.sh 只用于【已存在】的服务（改了 ConfigMap 要让它重新读）。新建服务请用 deploy.sh
kubectl get deploy "$DEPLOY" -n "$NS" >/dev/null 2>&1 \
  || die "deploy/$DEPLOY 不存在 —— restart.sh 只用于已存在的服务；新建请用 ./scripts/ci/deploy.sh"
kubectl get pods -l "$POD_SELECTOR" -n "$NS" | sed 's/^/   /'
# ⚠️ 缩容到 0 时没有 pod，直接 jsonpath items[0] 会崩（见 lib.sh 的 target_pod）
PRE_POD=$(target_pod)
PRE_IMAGE=$(kubectl get deploy "$DEPLOY" -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].image}')
PRE_GEN=$(kubectl get deploy "$DEPLOY" -n "$NS" -o jsonpath='{.metadata.generation}')
info "当前 pod: $PRE_POD"
info "镜像: $PRE_IMAGE"
state_write "restart_pre_pod" "$PRE_POD"
state_write "restart_pre_image" "$PRE_IMAGE"
state_write "restart_pre_gen" "$PRE_GEN"

# 快照 ConfigMap（供对比）
stage "重启 —— 快照相关 ConfigMap"
CMS=$(kubectl get deploy "$DEPLOY" -n "$NS" -o json | python3 -c '
import json,sys
d=json.load(sys.stdin)
ps=d["spec"]["template"]["spec"]
names=set()
for c in ps["containers"]:
    for x in c.get("envFrom",[]):
        n=x.get("configMapRef",{}).get("name")
        if n: names.add(n)
for v in ps["volumes"]:
    cm=v.get("configMap")
    if cm: names.add(cm["name"])
print(" ".join(sorted(names)))')
info "相关 ConfigMap: $CMS"
TS=$(date +%Y%m%d-%H%M%S)
for cm in $CMS; do
  kubectl get cm "$cm" -n "$NS" -o yaml > "$LOG_DIR/cm-$cm-$TS.yaml" 2>/dev/null || true
  ok "快照 $cm → $LOG_DIR/cm-$cm-$TS.yaml"
done

stage "重启 —— rollout restart"
confirm "确认重启 $DEPLOY？"
kubectl rollout restart deploy/"$DEPLOY" -n "$NS" | sed 's/^/   /'

if ! kubectl rollout status deploy/"$DEPLOY" -n "$NS" --timeout=900s; then
  fail "重启后 rollout 失败"
  kubectl get pods -l "$POD_SELECTOR" -n "$NS" | sed 's/^/     /'
  die "请执行 ./scripts/ci/rollback.sh"
fi

stage "重启 —— 结果"
POST_POD=$(target_pod)
kubectl get pods -l "$POD_SELECTOR" -n "$NS" | sed 's/^/   /'
info "pod: $PRE_POD → $POST_POD"
state_write "restart_post_pod" "$POST_POD"
state_write "restart_time" "$TS"

echo
info "下一步: ./scripts/ci/verify.sh"
