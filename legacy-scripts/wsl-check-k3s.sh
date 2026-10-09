#!/bin/bash
# check-k3s.sh —— 检查 k3s 状态
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

echo "════════ 1. k3s 进程 ════════"
ps aux 2>/dev/null | grep -E 'k3s|kubelet|containerd' | grep -v grep | head -5

echo ""
echo "════════ 2. kubectl ════════"
for p in ~/.local/bin/kubectl /usr/local/bin/kubectl /usr/bin/kubectl; do
  [ -x "$p" ] && { echo "  ✓ $p"; "$p" version --client 2>/dev/null | head -2; break; }
done
command -v kubectl 2>/dev/null && kubectl version --client 2>&1 | head -2

echo ""
echo "════════ 3. kubeconfig ════════"
ls -la ~/.kube/config /etc/rancher/k3s/k3s.yaml 2>/dev/null

echo ""
echo "════════ 4. Pods ════════"
if command -v kubectl >/dev/null 2>&1; then
  kubectl get pods -A 2>&1 | head -15
else
  echo "  kubectl 不可用"
fi

echo ""
echo "════════ 5. vLLM 相关 ════════"
ps aux 2>/dev/null | grep -i vllm | grep -v grep | head -3

echo ""
echo "════════ 6. 当前监听端口 ════════"
ss -tlnp 2>/dev/null | grep -E 'LISTEN' | head -15
