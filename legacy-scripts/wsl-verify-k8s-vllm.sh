#!/bin/bash
# verify-k8s-vllm.sh —— 验证 k8s 里的 vLLM
export PATH="/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin:$PATH"

echo "════════ 1. Pod / Service / Endpoints ════════"
kubectl get pods -l app=vllm-march7 -o wide 2>&1
echo ""
kubectl get svc vllm-march7 2>&1
echo ""
kubectl get endpoints vllm-march7 2>&1

echo ""
echo "════════ 2. GPU 占用 ════════"
nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null | head -3

echo ""
echo "════════ 3. 访问测试 ════════"
echo "  NodePort (127.0.0.1:30800):"
timeout 10 curl -s http://127.0.0.1:30800/v1/models 2>&1 | head -c 250
echo ""
echo ""
echo "  Service (ClusterIP 10.43.134.0:8000):"
timeout 10 curl -s http://10.43.134.0:8000/v1/models 2>&1 | head -c 200
echo ""
echo ""
echo "  Pod IP (10.42.0.63:8000):"
timeout 10 curl -s http://10.42.0.63:8000/v1/models 2>&1 | head -c 200
echo ""

echo ""
echo "════════ 4. 推理测试 ════════"
cat > /tmp/test_infer.py <<'PYEOF'
import json, urllib.request, time
CARD = """你是《崩坏：星穹铁道》中的角色「三月七」。
【身份】星穹列车的成员，与开拓者、丹恒、姬子、瓦尔特一同旅行。
【对话对象】开拓者 —— 你的挚友。
【说话方式】自称多用「我」，偶尔用「咱」。自然口语，句子短。
【输出规则】只输出三月七说的话，不要旁白、括号、动作描写。10-40 字。"""
for u in ["你好", "早上好", "今天好累啊"]:
    body = json.dumps({"model":"march7v3",
        "messages":[{"role":"system","content":CARD},{"role":"user","content":u}],
        "max_tokens":50,"temperature":0.85}, ensure_ascii=False).encode()
    req = urllib.request.Request("http://127.0.0.1:30800/v1/chat/completions",
                                 data=body, headers={"Content-Type":"application/json"})
    t0=time.time()
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            d = json.loads(r.read())
        print(f"  {u:<12} → {d['choices'][0]['message']['content'].strip()}  ({round((time.time()-t0)*1000)}ms)")
    except Exception as e:
        print(f"  {u}  ✗ {e}")
PYEOF
~/vllm-venv/bin/python /tmp/test_infer.py 2>&1

echo ""
echo "════════ 5. 请求日志（kubectl logs）════════"
kubectl logs -l app=vllm-march7 --tail=30 2>&1 | grep -iE 'received request|request_id|Engine 000' | tail -10
