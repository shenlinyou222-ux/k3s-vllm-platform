#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""make-before.py —— 从【已改】的 manifest 反向推出【改前】版本

为什么需要它：
  第 0.3 步的备份没做成，而 manifest 已经被改了。
  「改完再 cp 一份」得到的是【改后的副本】，不是备份 —— 没法当对比基线。
  所以用「反向补丁」精确减掉那三行，重建出改前版本。

用法：  python3 /srv/k3s-vllm-platform/k8s/make-before.py
产物：  ~/vllm-mongo.yaml.before
"""
import os

P = "/srv/k3s-vllm-platform/k8s/live/10-vllm-mongo.yaml"
OUT = os.path.expanduser("~/vllm-mongo.yaml.before")

s = open(P, encoding="utf-8").read()

# 反向：把 add 脚本加进去的三处，原样减掉
REMOVALS = [
    '          - "--log-config-file=/logcfg/uvicorn.json"\n',
    '        - {name: uvicorn-logcfg, mountPath: /logcfg, readOnly: true}\n',
    '      - name: uvicorn-logcfg\n        configMap: {name: vllm-uvicorn-logcfg}\n',
]

for r in REMOVALS:
    n = s.count(r)
    assert n == 1, f"要删的行出现 {n} 次（应为 1 次）：{r!r}"
    s = s.replace(r, "")

open(OUT, "w", encoding="utf-8").write(s)
print(f"✅ 已生成 {OUT}")

# 自检：三个标记必须全部归零，否则说明反向补丁不干净
ok = True
for k in ("--log-config-file", "uvicorn-logcfg", "vllm-uvicorn-logcfg"):
    c = s.count(k)
    print(f"   剩余 {k!r} = {c}   {'✅' if c == 0 else '❌'}")
    ok = ok and c == 0
assert ok, "反向补丁不干净，停下"
print("   自检通过")
