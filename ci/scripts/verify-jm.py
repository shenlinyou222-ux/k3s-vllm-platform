#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""scripts/ci/verify-jm.py —— jm 命名空间（jm-downloader + komga）的功能验证

判据（任一不过就退出码非 0）：
  ① 两个 Deployment 都存在
  ② spec.replicas 全部就绪（readyReplicas == replicas）
  ③ 两个 Service 的 Endpoints 非空（真的挂上了 Pod）

为什么用 kubectl 而不是 HTTP：
  · jm-downloader 的根路径可能 404，HTTP 状态码不能当判据
  · Endpoints 非空 = Service 真的选到了 Ready 的 Pod，比端口探测更直接
"""
import json
import subprocess
import sys

NS = "jm"
DEPLOYS = ["jm-downloader", "komga"]
SERVICES = ["jm-downloader", "komga"]


def kget(*args):
    out = subprocess.run(
        ["kubectl", "-n", NS, "get", *args, "-o", "json"],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        return None, out.stderr.strip()
    return json.loads(out.stdout), None


def fail(msg):
    print("❌ " + msg)
    sys.exit(1)


def main():
    for d in DEPLOYS:
        obj, err = kget("deploy", d)
        if obj is None:
            fail("Deployment %s 不存在: %s" % (d, err))
        spec = obj["spec"].get("replicas", 1)
        st = obj.get("status", {})
        ready = st.get("readyReplicas", 0) or 0
        if spec > 0 and ready < spec:
            fail("%s 未就绪: ready=%d/%d" % (d, ready, spec))
        print("✅ deploy/%s ready=%d/%d" % (d, ready, spec))

    for s in SERVICES:
        obj, err = kget("endpoints", s)
        if obj is None:
            fail("Endpoints %s 不存在: %s" % (s, err))
        subsets = obj.get("subsets") or []
        addrs = [a for sub in subsets for a in sub.get("addresses", [])]
        if not addrs:
            fail("Service %s 没有 Ready 的 Endpoint" % s)
        print("✅ svc/%s endpoints=%d" % (s, len(addrs)))

    print("✅ verify-jm 全部通过")


if __name__ == "__main__":
    main()
