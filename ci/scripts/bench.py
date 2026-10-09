#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""scripts/ci/bench.py —— 性能基准（预热 3 次 + 正式 10 次）

判据：稳态平均吞吐（tok/s）
输出格式固定，便于 verify.sh 用 grep 提取：
    平均 tok/s  = 123.4
"""
import json
import os
import statistics
import sys
import time
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import endpoint as ep

MODEL = "march7v3"
WARMUP = 3
ROUNDS = 10
MAX_TOKENS = 64


def one(url):
    body = {"model": MODEL,
            "messages": [{"role": "user", "content": "你好，介绍一下你自己"}],
            "max_tokens": MAX_TOKENS, "temperature": 0.7}
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data,
                                headers={"Content-Type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=180) as resp:
        j = json.loads(resp.read())
    dt = time.time() - t0
    n = j.get("usage", {}).get("completion_tokens", 0)
    return n, dt, (n / dt if dt else 0.0)


def main():
    # ⚠️ 不要再用 hostname -I（agent 镜像的 busybox 版不支持，stdout 为空
    #    → IndexError）。详见 endpoint.py 的模块注释。
    url = (sys.argv[1] if len(sys.argv) > 1 else ep.resolve(verbose=False)) \
          + "/v1/chat/completions"
    print(f"   端点: {url}")

    print(f"   ── 预热 {WARMUP} 次（不计入）──")
    for i in range(WARMUP):
        n, dt, tps = one(url)
        print(f"      预热{i+1}: {n:3} tok / {dt:5.2f}s = {tps:6.1f} tok/s")

    print(f"   ── 正式 {ROUNDS} 次 ──")
    res = []
    for i in range(ROUNDS):
        n, dt, tps = one(url)
        res.append(tps)
        print(f"      第{i+1:2}次: {n:3} tok / {dt:5.2f}s = {tps:6.1f} tok/s")

    print()
    print(f"   平均 tok/s  = {statistics.mean(res):.1f}")
    print(f"   中位数      = {statistics.median(res):.1f}")
    print(f"   最快/最慢   = {max(res):.1f} / {min(res):.1f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
