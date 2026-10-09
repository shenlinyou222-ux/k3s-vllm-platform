#!/bin/bash
# redeploy-vllm.sh —— 用 digest 重新部署
export PATH="/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin:$PATH"

echo "════════ 1. 删掉卡住的 Deployment ════════"
kubectl delete deployment vllm-march7 --ignore-not-found --force --grace-period=0 2>&1 | head -2
kubectl delete svc vllm-march7 --ignore-not-found 2>&1 | head -2
# 清掉残留 pod
for p in $(kubectl get pods -l app=vllm-march7 -o name 2>/dev/null); do
  kubectl delete "$p" --force --grace-period=0 2>&1 | head -1
done
sleep 5

echo ""
echo "════════ 2. 确认镜像在本地 ════════"
docker images --digests 2>&1 | grep -E 'REPOSITORY|vllm' | head -3

echo ""
echo "════════ 3. 应用新 Deployment（digest）════════"
kubectl apply -f /srv/k3s-vllm-platform/k8s/vllm-deployment.yaml 2>&1

echo ""
echo "════════ 4. 等 Pod ════════"
for i in $(seq 1 48); do
  sleep 10
  POD=$(kubectl get pod -l app=vllm-march7 -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  ST=$(kubectl get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null)
  RD=$(kubectl get pod "$POD" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)
  RS=$(kubectl get pod "$POD" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)
  echo "  [$((i*10))s] $ST ready=$RD restarts=$RS"
  [ "$RD" = "true" ] && { echo "  ✅ 就绪"; break; }
  [ "$ST" = "Failed" ] && break
done

echo ""
echo "════════ 5. 状态 ════════"
kubectl get pods -l app=vllm-march7 -o wide 2>&1
kubectl get svc vllm-march7 2>&1

echo ""
echo "════════ 6. 日志（尾部）════════"
kubectl logs -l app=vllm-march7 --tail=20 2>&1 | tail -20
