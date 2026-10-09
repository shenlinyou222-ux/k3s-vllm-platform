#!/bin/bash
# deploy-mongo-audit.sh —— 部署 vLLM + MongoDB 审计
export PATH="/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin:$PATH"

echo "════════ 1. 生成清单 ════════"
/home/user/vllm-venv/bin/python /srv/k3s-vllm-platform/build_manifest_mongo.py 2>&1

echo ""
echo "════════ 2. 清理旧 vLLM ════════"
kubectl delete deployment vllm-march7 --ignore-not-found --force --grace-period=0 2>&1 | head -1
kubectl delete svc vllm-march7 --ignore-not-found 2>&1 | head -1
kubectl delete cm vllm-plugins --ignore-not-found 2>&1 | head -1
kubectl delete pvc audit-data-pvc --ignore-not-found 2>&1 | head -1
for p in $(kubectl get pods -l app=vllm-march7 -o name 2>/dev/null); do
  kubectl delete "$p" --force --grace-period=0 2>&1 | head -1
done
sleep 8

echo ""
echo "════════ 3. 应用 ════════"
kubectl apply -f /srv/k3s-vllm-platform/k8s/live 2>&1

echo ""
echo "════════ 4. 等 PVC ════════"
for i in $(seq 1 12); do
  sleep 5
  B=$(kubectl get pvc -l app=vllm-march7 --no-headers 2>/dev/null | grep -c Bound)
  echo "  [$((i*5))s] $B/3"
  [ "$B" = "3" ] && break
done

echo ""
echo "════════ 5. 等 Pod ════════"
for i in $(seq 1 60); do
  sleep 10
  POD=$(kubectl get pod -l app=vllm-march7 -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  RD=$(kubectl get pod "$POD" -o jsonpath='{.status.containerStatuses[*].ready}' 2>/dev/null)
  ST=$(kubectl get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null)
  echo "  [$((i*10))s] $ST ready=[$RD]"
  echo "$RD" | grep -q "true true" && { echo "  ✅ 就绪"; break; }
  [ "$ST" = "Failed" ] && break
done

echo ""
echo "════════ 6. 代理是否连上 MongoDB ════════"
POD=$(kubectl get pod -l app=vllm-march7 -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
kubectl logs "$POD" -c log-proxy 2>&1 | grep -iE 'mongo|proxy|audit' | head -8

echo ""
echo "════════ 7. 发请求（写入 MongoDB）════════"
sleep 5
cat > /tmp/tm2.py <<'PYEOF'
import json, urllib.request, time, re
CARD = """你是《崩坏：星穹铁道》中的角色「三月七」。
【身份】星穹列车的成员，与开拓者、丹恒、姬子、瓦尔特一同旅行。
【对话对象】开拓者 —— 你的挚友。
【说话方式】自称多用「我」，偶尔用「咱」。自然口语，句子短。
【输出规则】只输出三月七说的话，不要旁白、括号、动作描写。10-40 字。"""
foreign = re.compile(r'[\u0600-\u06FF\u0400-\u04FF\uAC00-\uD7AF\u3040-\u30FF\u0590-\u05FF\u0E00-\u0E7F\u0900-\u097F\u1F300-\u1FAFF]')
bad = 0
for u in ["你好", "今天好累啊", "你在干嘛", "谢谢你", "那我先走了", "你在看星星吗"]:
    body = json.dumps({"model":"march7v3",
        "messages":[{"role":"system","content":CARD},{"role":"user","content":u}],
        "max_tokens":60,"temperature":0.85}, ensure_ascii=False).encode()
    req = urllib.request.Request("http://127.0.0.1:30800/v1/chat/completions",
                                 data=body, headers={"Content-Type":"application/json"})
    t0=time.time()
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            d = json.loads(r.read())
        o = d["choices"][0]["message"]["content"].strip()
        if foreign.findall(o):
            bad += 1; print(f"  ⚠️ {u:<12} → {o}")
        else:
            print(f"  ✅ {u:<12} → {o[:48]}  ({round((time.time()-t0)*1000)}ms)")
    except Exception as e:
        print(f"  ✗ {u} → {str(e)[:70]}")
print(f"\n  含外来字符: {bad}/6")
PYEOF
/home/user/vllm-venv/bin/python /tmp/tm2.py 2>&1

echo ""
echo "════════ 8. MongoDB 里的数据 ════════"
MPOD=$(kubectl get pod -l app=mongodb -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
kubectl exec "$MPOD" -- mongosh "mongodb://localhost:27017/vllm_audit?directConnection=true" --quiet --eval "
var c = db.requests.countDocuments({});
print('  文档数: ' + c);
print('  索引: ' + db.requests.getIndexes().map(i => i.name).join(', '));
print('');
print('  最近 2 条:');
db.requests.find({}, {seq:1, rid:1, ms:1, model:1, n_messages:1, reply:1, 'usage.total_tokens':1, _id:0})
  .sort({ts_epoch:-1}).limit(2).forEach(d => print('    ' + JSON.stringify(d)));
" 2>&1

echo ""
echo "════════ 9. 代理日志（看写入）════════"
kubectl logs "$POD" -c log-proxy --tail=12 2>&1 | tail -12
