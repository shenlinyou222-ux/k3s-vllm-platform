#!/bin/bash
# audit-k3s.sh —— 审计 k3s 所有工作负载
export PATH="/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin:$PATH"

echo "════════ 1. 所有 Pod ════════"
kubectl get pods -A -o wide 2>&1 | grep -vE 'kube-system.*Running.*(coredns|traefik|local-path|metrics|svclb)' | head -20

echo ""
echo "════════ 2. 所有 Deployment/StatefulSet/DaemonSet ════════"
kubectl get deploy,sts,ds -A 2>&1 | grep -vE 'kube-system|monitoring' | head -20

echo ""
echo "════════ 3. 所有 Service ════════"
kubectl get svc -A 2>&1 | grep -vE 'kube-system|monitoring|kubernetes ' | head -20

echo ""
echo "════════ 4. 各工作负载详情（创建时间 + 镜像）════════"
for ns in default; do
  for kind in deploy sts; do
    for name in $(kubectl get $kind -n $ns -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
      AGE=$(kubectl get $kind $name -n $ns -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)
      IMG=$(kubectl get $kind $name -n $ns -o jsonpath='{.spec.template.spec.containers[*].image}' 2>/dev/null | tr ' ' ',')
      REP=$(kubectl get $kind $name -n $ns -o jsonpath='{.spec.replicas}' 2>/dev/null)
      RDY=$(kubectl get $kind $name -n $ns -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
      echo "  [$kind] $name  replicas=$REP ready=$RDY  created=$AGE"
      echo "          image: ${IMG:0:100}"
    done
  done
done

echo ""
echo "════════ 5. GPU 占用 ════════"
nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null | head -5

echo ""
echo "════════ 6. 各 Pod 的资源占用 ════════"
kubectl top pod -A 2>&1 | grep -vE 'kube-system|monitoring' | head -12

echo ""
echo "════════ 7. 磁盘占用（镜像 + 存储）════════"
echo "  镜像:"
docker images 2>/dev/null | grep -vE '^REPOSITORY' | awk '{printf "    %-60s %s\n", $1":"$2, $4}' | head -15
echo ""
echo "  PVC:"
kubectl get pvc -A 2>&1 | grep -v kube-system | head -10
echo ""
echo "  local-path 存储:"
du -sh /var/lib/rancher/k3s/storage/* 2>/dev/null | head -10
