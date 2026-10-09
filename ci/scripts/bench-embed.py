#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""scripts/ci/bench-embed.py —— 向量服务的性能基准（预热 3 次 + 正式 20 次）

判据：稳态单条延迟 / 吞吐。
输出格式固定，便于 verify.sh 用 grep 提取（与 bench.py 的 tok/s 对应）：
    平均 req/s  = 123.4
    平均 ms/条  = 8.1

⚠️ 为什么是 req/s 而不是 tok/s：
   embedding 模型不生成 token，没有 tok/s 这个量。两者用不同单位，
   所以 verify.sh 里 BENCH_UNIT 是按 target 选的（见 lib.sh）。
"""
import json
import os
import statistics
import sys
import time
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import endpoint as ep

MODEL = os.environ.get("EMBED_MODEL", "dmeta-small")
WARMUP = 3
ROUNDS = 20
TEXT = "看看都有哪些模型，另外关掉显存里的模型进程"


def one(url):
    body = {"model": MODEL, "input": [TEXT]}
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data,
                                 headers={"Content-Type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=60) as resp:
        json.loads(resp.read())
    return time.time() - t0


def main():
    url = (sys.argv[1] if len(sys.argv) > 1 else ep.resolve(verbose=False)) \
          + "/v1/embeddings"
    print(f"   端点: {url}")
    print(f"   模型: {MODEL}")

    print(f"   ── 预热 {WARMUP} 次（不计入）──")
    for i in range(WARMUP):
        dt = one(url)
        print(f"      预热{i+1}: {dt*1000:7.2f} ms")

    print(f"   ── 正式 {ROUNDS} 次 ──")
    lat = []
    for i in range(ROUNDS):
        dt = one(url)
        lat.append(dt)
        print(f"      第{i+1:2}次: {dt*1000:7.2f} ms")

    ms = statistics.mean(lat) * 1000
    rps = 1.0 / statistics.mean(lat)
    print()
    print(f"   平均 req/s  = {rps:.1f}")
    print(f"   平均 ms/条  = {ms:.2f}")
    print(f"   中位数 ms   = {statistics.median(lat)*1000:.2f}")
    print(f"   最快/最慢   = {min(lat)*1000:.2f} / {max(lat)*1000:.2f} ms")
    return 0


if __name__ == "__main__":
    sys.exit(main())
