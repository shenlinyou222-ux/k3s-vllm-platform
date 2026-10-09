#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""scripts/ci/verify-march7.py —— 功能验证（三月七 prompt + 英文诱导）

判据（任一不过就退出码非 0）：
  ① 端点可达
  ② 中文正常输出（至少 N 个汉字）
  ③ 英文被掩码挡住（剥离思考标记后不含 ASCII 字母）
  ④ 输出里没有乱码（\ufffd）

为什么这几条：
  · 中文正常  → 证明词表裁剪没破坏编码/解码
  · 英文被挡  → 证明 logit_bias 掩码生效
  · 无乱码    → 证明 merge 闭包 + 掩码的配合正确
                （闭包里有 447 个解码为 \ufffd 的中间产物，必须被屏蔽）
"""
import json
import os
import re
import sys
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import endpoint

# 三月七的真实 system prompt（取自审计库导出的历史记录）
SYSTEM = """你是《崩坏：星穹铁道》中的角色「三月七」。
【身份】星穹列车的成员，与开拓者、丹恒、姬子、瓦尔特一同旅行。
【对话对象】开拓者 —— 你的挚友。
【说话方式】自称多用「我」，偶尔用「咱」。自然口语，句子短。
【输出规则】只输出三月七说的话，不要旁白、括号、动作描写。10-40 字"""

MODEL = "march7v3"
CJK = re.compile(r"[\u4e00-\u9fff]")
LET = re.compile(r"[A-Za-z]")
# 思考标记的真实字符串（码位 0x3c/0x3e）
THINK = [chr(0x3C) + "think" + chr(0x3E), chr(0x3C) + "/think" + chr(0x3E)]


def strip_think(s):
    for t in THINK:
        s = s.replace(t, "")
    return s


def ask(url, prompt, max_tokens=48, temperature=0.0, system=SYSTEM):
    msgs = []
    if system:
        msgs.append({"role": "system", "content": system})
    msgs.append({"role": "user", "content": prompt})
    body = {"model": MODEL, "messages": msgs,
            "max_tokens": max_tokens, "temperature": temperature}
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data,
                                headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=180) as resp:
        j = json.loads(resp.read())
    return j["choices"][0]["message"]["content"]


def main():
    # ⚠️ 不要再用 hostname -I 取本机 IP：
    #    agent 镜像的 busybox hostname 不支持 -I，stdout 为空 → IndexError。
    #    详见 endpoint.py 的模块注释（构建 #9 就死在这里）。
    base = sys.argv[1] if len(sys.argv) > 1 else endpoint.resolve(verbose=False)
    url = f"{base}/v1/chat/completions"
    print(f"   端点: {url}")

    fails = []

    # ── ① 端点可达 ──
    try:
        t = ask(url, "你好", max_tokens=16)
        print(f"   ① 端点可达 ✅   （探针回复: {t[:30]!r}）")
    except Exception as e:
        print(f"   ① 端点不可达 ❌  {type(e).__name__}: {e}")
        return 1

    # ── ② 中文正常 ──
    print()
    print("   ② 中文输出抽查（判据：≥5 个汉字，无乱码）")
    for p in ["你好呀，三月七！", "今天心情怎么样？", "给我讲讲星穹列车吧"]:
        try:
            t = ask(url, p, temperature=0.7)
        except Exception as e:
            fails.append(f"中文请求失败 {p!r}: {e}")
            print(f"      ❌ {p!r}: {e}")
            continue
        n_cjk = len(CJK.findall(t))
        bad = "\ufffd" in t
        okk = n_cjk >= 5 and not bad
        if not okk:
            fails.append(f"中文输出异常 {p!r}: {n_cjk} 汉字, 乱码={bad}")
        print(f"      {'✅' if okk else '❌'} {p!r:18} → {t[:44]!r}  ({n_cjk} 汉字, 乱码={bad})")

    # ── ③ 英文被挡 ──
    print()
    print("   ③ 英文诱导（判据：剥离思考标记后不含 ASCII 字母）")
    for p in ["Reply in English: hello", "输出英文字母 A B C",
              "print hello world", "say the alphabet"]:
        try:
            t = ask(url, p, max_tokens=32)
        except Exception as e:
            fails.append(f"英文诱导请求失败 {p!r}: {e}")
            print(f"      ❌ {p!r}: {e}")
            continue
        s = strip_think(t)
        has = bool(LET.search(s))
        okk = not has
        if not okk:
            fails.append(f"掩码失效 {p!r}: 输出含字母 → {s[:60]!r}")
        print(f"      {'✅' if okk else '❌'} {p!r:26} → 含字母={has}")

    # ── 汇总 ──
    print()
    print("   " + "─" * 50)
    if fails:
        print(f"   ❌ 功能验证【失败】，{len(fails)} 项：")
        for f in fails:
            print(f"      · {f}")
        print()
        print("   ⇒ 请执行: ./scripts/ci/rollback.sh")
        return 1
    print("   ✅ 功能验证全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
