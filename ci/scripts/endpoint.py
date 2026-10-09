#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""scripts/ci/endpoint.py —— 解析 vLLM 的 base URL（宿主和 Jenkins agent 里都能用）

═══ 为什么需要这个模块（踩过的坑）═══
verify-march7.py / bench.py 原来用 `hostname -I` 取本机 IP 再拼 :30800。
这在 WSL 宿主上能跑，但在【Jenkins agent pod】里不行 —— agent 镜像基于
Alpine，/bin/hostname 是 busybox 版：

    $ hostname -I
    hostname: unrecognized option: I        ← 打到 stderr
    (stdout 为空，而且 rc 仍然是 0)

⇒ `subprocess.run(...).stdout.split()[0]` 直接 IndexError: list index out of range。
2026-10-07 的构建 #9 就死在这一行。它潜伏这么久是因为：阶段⑤ 需要前面的
阶段①②③④ 全过才会执行，而在此之前从没有一次构建走到过阶段⑤。

═══ 做法 ═══
按候选列表依次探测 /health，返回第一个通的：

  ① $VLLM_URL                                          显式覆盖，最高优先级
  ② http://<service>.default.svc.cluster.local:<port>  集群内，走 Service
  ③ http://<本机 IP>:<nodePort>...                     在宿主 / WSL 上跑时

本机 IP 用 socket 探测（connect 一个不可达地址，拿内核按路由选出的源地址），
完全不依赖 hostname 的任何选项。

═══ 多目标（2026-10-08）═══
同一个集群里现在有两个 vLLM 服务，验证脚本必须知道该找哪一个：

  CI_TARGET=march7（默认）→ vllm-march7:8001，NodePort 30800/30801
  CI_TARGET=embed         → vllm-embed:8000， NodePort 30802

默认值保持 march7 —— 老调用方（verify-march7.py / bench.py）行为完全不变。
"""
import os
import socket
import urllib.request

TARGETS = {
    "march7": ("http://vllm-march7.default.svc.cluster.local:8001", (30800, 30801)),
    "embed": ("http://vllm-embed.default.svc.cluster.local:8000", (30802,)),
}
TARGET = os.environ.get("CI_TARGET", "march7")
if TARGET not in TARGETS:
    raise SystemExit(f"未知 CI_TARGET={TARGET}（可选 {'|'.join(TARGETS)}）")
SERVICE, NODEPORTS = TARGETS[TARGET]


def local_ips():
    """不依赖 hostname -I 的本机 IP 探测（按可靠性排序，去重）"""
    ips = []
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        # 不真的发包，只是让内核按路由表选出源地址
        s.connect(("10.255.255.255", 1))
        ips.append(s.getsockname()[0])
        s.close()
    except Exception:
        pass
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ips.append(info[4][0])
    except Exception:
        pass
    out = []
    for ip in ips:
        if ip and ip not in out and not ip.startswith("127."):
            out.append(ip)
    return out


def candidates():
    out = []
    env = os.environ.get("VLLM_URL")
    if env:
        out.append(env.rstrip("/"))
    out.append(SERVICE)
    for ip in local_ips():
        for p in NODEPORTS:
            out.append(f"http://{ip}:{p}")
    return out


def _alive(base, timeout=5):
    try:
        req = urllib.request.Request(base + "/health")
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status == 200
    except Exception:
        return False


def resolve(verbose=True):
    """返回第一个 /health 通 的 base URL（不带尾斜杠）。都不通就抛异常。"""
    tried = candidates()
    for c in tried:
        if _alive(c):
            if verbose:
                print(f"   端点: {c}  （从 {len(tried)} 个候选里探到的）")
            return c
    raise RuntimeError(
        "探测不到可用的 vLLM 端点。候选都试过了：\n    " + "\n    ".join(tried)
        + "\n  提示：可以用 VLLM_URL 显式指定，例如 VLLM_URL=http://1.2.3.4:30800"
    )


if __name__ == "__main__":
    print(resolve())
