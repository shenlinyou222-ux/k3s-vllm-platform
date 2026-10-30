#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""scripts/ci/verify-mask.py —— vllm-mask（剧情掩码服务）的功能验证

判据（任一不过就退出码非 0）：
  ① /v1/models 里有 q17b-flex
  ② 一次 chat 能返回非空中文
  ③ 输出没有乱码（\\ufffd）

为什么这三条：
  · 模型列表 → 证明 OpenAI 兼容端点活着
  · 中文输出 → 证明 tokenizer / 权重没被 patch 破坏
  · 无乱码   → 证明 KV 掩码没有把上下文切坏
"""
import json
import os
import re
import sys
import urllib.request

BASE = os.environ.get("VLLM_URL") or "http://vllm-mask.default.svc.cluster.local:8000"
MODEL = os.environ.get("VLLM_MODEL", "q17b-flex")
CJK = re.compile(r"[\u4e00-\u9fff]")


def get(path, timeout=10):
    req = urllib.request.Request(BASE + path, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", "ignore")


def post(path, body, timeout=120):
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        BASE + path, data=data, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8", "ignore"))


def fail(msg):
    print("❌ " + msg)
    sys.exit(1)


def main():
    print("端点: " + BASE)

    try:
        models = get("/v1/models")
    except Exception as e:
        fail("端点不可达: %r" % (e,))
    if MODEL not in models:
        fail("模型列表里没有 %s: %s" % (MODEL, models[:200]))
    print("✅ /v1/models 含 " + MODEL)

    body = {
        "model": MODEL,
        "messages": [
            {"role": "system", "content": "你是游戏剧情助手，只根据给定对白回答。"},
            {"role": "user", "content": "用一句话介绍你自己。"},
        ],
        "temperature": 0.0,
        "max_tokens": 48,
        "chat_template_kwargs": {"enable_thinking": False},
    }
    # vLLM 刚 rollout 完时模型可能还在加载，重试到 120s
    import time
    text, last = "", None
    for attempt in range(12):
        try:
            d = post("/v1/chat/completions", body, timeout=30)
            text = d["choices"][0]["message"]["content"] or ""
            if text.strip():
                break
        except Exception as e:
            last = e
        time.sleep(10)
    if not text.strip():
        fail("chat 请求失败: %r" % (last,))

    if not text.strip():
        fail("返回为空")
    if "\ufffd" in text:
        fail("输出含乱码: %r" % text)
    if not CJK.search(text):
        fail("输出没有中文: %r" % text)

    print("✅ 中文输出: " + text.strip()[:60])
    print("✅ verify-mask 全部通过")


if __name__ == "__main__":
    main()
