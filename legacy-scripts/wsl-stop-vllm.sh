#!/bin/bash
# stop-vllm.sh —— 停掉所有 vLLM 进程
export PATH="/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin:$PATH"

echo "════════ 停止前 ════════"
nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader
echo ""
echo "  GPU 进程:"
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null | head -10
echo ""
echo "  vLLM 进程:"
ps aux | grep -E 'vllm|EngineCore' | grep -v grep | awk '{print "    PID="$2" "$11" "$12" "$13}' | head -6

echo ""
echo "════════ 执行停止 ════════"
# 逐个杀（避免自匹配）
for pid in $(ps -eo pid,cmd | grep -E 'bin/vllm|VLLM::EngineCore|vllm.entrypoints' | grep -v grep | awk '{print $1}'); do
  echo "  kill -9 $pid"
  kill -9 "$pid" 2>/dev/null
done
sleep 6

echo ""
echo "════════ 停止后 ════════"
nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader
echo ""
echo "  剩余 vLLM:"
ps aux | grep -E 'bin/vllm|VLLM::' | grep -v grep | awk '{print "    PID="$2}' | head -5
echo "  （空 = 已清干净）"

echo ""
echo "  GPU 计算进程:"
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null | head -5
echo "  （空 = GPU 已释放）"
