#!/bin/bash
# deploy-vllm.sh —— 部署 vLLM 到 k3s
export PATH="/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin:$PATH"

echo "════════ 1. 停掉 WSL 裸跑的 vLLM（释放 GPU）════════"
pkill -9 -f 'vllm serve' 2>/dev/null
pkill -9 -f 'VLLM::' 2>/dev/null
sleep 5
nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader | sed 's/^/  显存: /'

echo ""
echo "════════ 2. 清理旧资源 ════════"
kubectl delete deployment vllm-march7 --ignore-not-found --force --grace-period=0 2>&1 | head -2
kubectl delete svc vllm-march7 --ignore-not-found 2>&1 | head -2
kubectl delete pod gpu-test --ignore-not-found --force --grace-period=0 2>&1 | head -2
sleep 3

echo ""
echo "════════ 3. 应用 Deployment ════════"
kubectl apply -f /srv/k3s-vllm-platform/k8s/vllm-deployment.yaml 2>&1

echo ""
echo "════════ 4. 等 Pod 就绪 ════════"
for i in $(seq 1 60); do
  sleep 10
  ST=$(kubectl get pod -l app=vllm-march7 -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
  RD=$(kubectl get pod -l app=vllm-march7 -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null)
  echo "  [$((i*10))s] phase=$ST ready=$RD"
  [ "$RD" = "true" ] && { echo "  ✅ 就绪"; break; }
  [ "$ST" = "Failed" ] && { echo "  ❌ 失败"; break; }
done

echo ""
echo "════════ 5. Pod 状态 ════════"
kubectl get pods -l app=vllm-march7 -o wide 2>&1
echo ""
kubectl get svc vllm-march7 2>&1
echo ""
kubectl get endpoints vllm-march7 2>&1

echo ""
echo "════════ 6. 最近日志 ════════"
kubectl logs -l app=vllm-march7 --tail=25 2>&1 | tail -25

echo ""
echo "════════ 7. 测试服务 ════════"
sleep 5
for url in http://127.0.0.1:30800/v1/models http://$(hostname -I | awk '{print $1}'):30800/v1/models; do
  echo -n "  $url : "
  timeout 10 curl -s "$url" 2>&1 | head -c 150
  echo ""
done
