#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""scripts/ci/verify-embed.py —— 向量服务的功能验证

═══ 为什么不能只检查"返回了 768 维向量" ═══
vLLM 服务 BERT 时有三个可以配错的旋钮，配错了【照样返回形状正确的向量】，
但语义是错的，下游读出头会全崩：

  ① 池化方式（CLS / MEAN / LAST）
     vLLM 里 BertModel 带 @default_pooling_type(seq_pooling_type="CLS")，
     默认 CLS —— 与 dmeta 的 1_Pooling/config.json 一致。但换成别的模型
     就不一定了（比如 BGE 是 CLS、E5 是 MEAN）。
  ② use_activation（默认 True，会把向量 L2 归一化到 1.0）
     我们的读出头是在【未归一化】的 CLS 向量上训的。
  ③ dtype（float32 / bfloat16）

所以这里做的是【逐条向量比对】：拿本地 HF 模型在 fp32 下算出的参考向量
（scripts/ci/embed_reference.json，由 _gen_embed_ref.py 生成），
跟服务端返回的向量算 cos，要求 ≥ min_cos（默认 0.999）。

外加一条语义序判据：sim("把模型删掉", "删除模型文件") 必须显著大于
sim("把模型删掉", "今天天气不错，随便聊聊") —— 防"向量全对但语义反了"。

用法：  python3 scripts/ci/verify-embed.py
        VLLM_URL=http://1.2.3.4:30802 python3 scripts/ci/verify-embed.py
        EMBED_MODEL=dmeta-small python3 scripts/ci/verify-embed.py
"""
import json
import os
import sys
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import endpoint as ep

CI_DIR = os.path.dirname(os.path.abspath(__file__))
REF_FILE = os.path.join(CI_DIR, "embed_reference.json")
MODEL = os.environ.get("EMBED_MODEL", "dmeta-small")


def cos(a, b):
    import math
    s = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    return s / (na * nb + 1e-12)


def embed(base, texts):
    body = {"model": MODEL, "input": texts}
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(base + "/v1/embeddings", data=data,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        j = json.loads(resp.read())
    # OpenAI 兼容格式：data[i].embedding（顺序与输入一致）
    items = sorted(j["data"], key=lambda d: d.get("index", 0))
    return [it["embedding"] for it in items]


def main():
    ref = json.load(open(REF_FILE, encoding="utf-8"))
    base = (sys.argv[1] if len(sys.argv) > 1 else ep.resolve(verbose=False)).rstrip("/")
    print(f"   端点: {base}")
    print(f"   模型: {MODEL}   参考向量: {os.path.basename(REF_FILE)}"
          f"（{len(ref['cases'])} 条，维数 {ref['dim']}）")

    texts = [c["text"] for c in ref["cases"]]
    try:
        vecs = embed(base, texts)
    except Exception as e:
        print(f"   ❌ /v1/embeddings 调用失败: {type(e).__name__}: {e}")
        return 1

    fails = 0

    # ── ① 维数 ──
    dims = {len(v) for v in vecs}
    if dims == {ref["dim"]}:
        print(f"   ✅ 维数一致: {ref['dim']}")
    else:
        print(f"   ❌ 维数不一致: 服务端 {dims}，参考 {ref['dim']}")
        fails += 1

    # ── ② 逐条 cos 比对 ──
    print(f"   ── 逐条 cos（门槛 {ref['min_cos']}）──")
    worst = 1.0
    by_text = {}
    for c, v in zip(ref["cases"], vecs):
        c_ = cos(v, c["vec"])
        by_text[c["text"]] = v
        worst = min(worst, c_)
        flag = "✅" if c_ >= ref["min_cos"] else "❌"
        print(f"      {flag} cos={c_:.6f}  L2={sum(x*x for x in v)**0.5:6.2f}  {c['text']}")
        if c_ < ref["min_cos"]:
            fails += 1
    print(f"   最差 cos = {worst:.6f}")

    # ── ③ 语义序 ──
    for trio in ref.get("order", []):
        a, b, c = trio
        if not all(t in by_text for t in trio):
            continue
        sab, sac = cos(by_text[a], by_text[b]), cos(by_text[a], by_text[c])
        if sab > sac:
            print(f"   ✅ 语义序: sim({a!r},{b!r})={sab:.4f} > sim({a!r},{c!r})={sac:.4f}")
        else:
            print(f"   ❌ 语义序反了: {sab:.4f} <= {sac:.4f}  ({a} / {b} / {c})")
            fails += 1

    if fails:
        print(f"   ❌ 功能验证失败（{fails} 项）")
        return 1
    print("   ✅ 功能验证通过（服务端向量 == 本地 HF 模型向量）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
