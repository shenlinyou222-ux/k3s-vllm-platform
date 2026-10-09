#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
sync_k3s_endpoint.py —— 把 k3s 服务端点同步到各应用配置

为什么需要：
  · k3s NodePort 走 iptables DNAT，不产生 listen socket
  · WSL2 的 localhostForwarding 只转发有 listen socket 的端口
  · 所以 Windows 的 127.0.0.1 访问不到 NodePort
  · 但 Windows 可以访问 WSL 的 IP

做两件事：
  ① 读 WSL IP，可选地更新一个「下游应用」的 base_url（默认 SillyTavern）
  ② 输出一份端点清单 JSON

⚠️ 公开版说明：原版把 WSL IP、宿主仓库路径、下游应用路径都写死在代码里。
   这里全部改成环境变量 —— 换机器/换路径不用改代码。

用法：
    python3 sync_k3s_endpoint.py
    ST_SETTINGS=/path/to/settings.json python3 sync_k3s_endpoint.py
    WSL_IP=<wsl-ip> python3 sync_k3s_endpoint.py     # 跳过自动探测

环境变量：
    WSL_IP          直接指定 WSL IP（跳过 wsl.exe 探测）
    WSL_IP_FILE     缓存 WSL IP 的文件（默认 <repo>/wsl-ip.txt）
    ST_SETTINGS     下游应用的 settings.json；不设则跳过第 ① 步
    ENDPOINTS_OUT   端点清单输出路径（默认 <repo>/k3s-endpoints.json）
    VLLM_MODEL      写进下游配置的模型名（默认 march7v3）
"""
import json
import os
import re
import subprocess
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

WSL_IP_FILE = os.environ.get("WSL_IP_FILE", os.path.join(REPO, "wsl-ip.txt"))
ST_SETTINGS = os.environ.get("ST_SETTINGS", "")
ENDPOINTS_OUT = os.environ.get("ENDPOINTS_OUT", os.path.join(REPO, "k3s-endpoints.json"))
VLLM_MODEL = os.environ.get("VLLM_MODEL", "march7v3")

# 端点清单：名字 / NodePort / 路径前缀
ENDPOINTS = [
    ("vLLM（生成式 LLM）", 30800, "/v1"),
    ("vLLM（直连，绕过代理）", 30801, "/v1"),
    ("vLLM（向量服务）", 30802, "/v1"),
    ("llama.cpp ASR（语音转写）", 30803, ""),
    ("MongoDB", 30017, ""),
    ("Prometheus", 30090, ""),
    ("Grafana", 30030, ""),
    ("Traefik (HTTP)", 30871, ""),
    ("Traefik (HTTPS)", 30097, ""),
]


def get_wsl_ip():
    """先看缓存文件，再实时问 wsl.exe"""
    explicit = os.environ.get("WSL_IP", "").strip()
    if explicit:
        return explicit
    if os.path.exists(WSL_IP_FILE):
        ip = open(WSL_IP_FILE, encoding="utf-8").read().strip()
        if re.match(r"^\d+\.\d+\.\d+\.\d+$", ip):
            return ip
    try:
        out = subprocess.run(["wsl.exe", "-e", "bash", "-lc", "hostname -I"],
                             capture_output=True, text=True, timeout=15).stdout
        for tok in out.split():
            if re.match(r"^\d+\.\d+\.\d+\.\d+$", tok):
                return tok
    except Exception:
        pass
    return None


def main():
    ip = get_wsl_ip()
    if not ip:
        print("  ❌ 拿不到 WSL IP（可用 WSL_IP=<ip> 显式指定）")
        sys.exit(1)

    print("=" * 90)
    print(f" WSL IP: {ip}")
    print("=" * 90)

    print("\n  ── k3s 服务端点（从 Windows 访问）──")
    for name, port, path in ENDPOINTS:
        print(f"    {name:26s}  http://{ip}:{port}{path}")
    print("\n  ── 从 WSL 内访问（127.0.0.1 也可以）──")
    for name, port, path in ENDPOINTS:
        print(f"    {name:26s}  http://127.0.0.1:{port}{path}")

    # ── ① 更新下游应用 ──
    if ST_SETTINGS:
        print("\n" + "=" * 90)
        print(" 更新下游应用配置")
        print("=" * 90)
        if not os.path.exists(ST_SETTINGS):
            print(f"  ⚠ {ST_SETTINGS} 不存在，跳过")
        else:
            with open(ST_SETTINGS, encoding="utf-8-sig") as f:
                j = json.load(f)
            o = j.setdefault("oai_settings", {})
            old = o.get("custom_url")
            new = f"http://{ip}:30800/v1"
            if old != new:
                o["custom_url"] = new
                o["chat_completion_source"] = "custom"
                o["custom_model"] = VLLM_MODEL
                o["openai_model"] = VLLM_MODEL
                with open(ST_SETTINGS, "w", encoding="utf-8") as f:
                    json.dump(j, f, ensure_ascii=False, indent=4)
                print(f"  ✓ custom_url: {old} → {new}")
            else:
                print(f"  （已是最新: {new}）")

    # ── ② 写端点清单 ──
    json.dump({"wsl_ip": ip, "endpoints": [
        {"name": n, "port": p, "path": pa,
         "url_windows": f"http://{ip}:{p}{pa}",
         "url_wsl": f"http://127.0.0.1:{p}{pa}"} for n, p, pa in ENDPOINTS]},
        open(ENDPOINTS_OUT, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    print(f"\n  ✓ 端点清单: {ENDPOINTS_OUT}")

    print("\n" + "=" * 90)
    print(" 提示")
    print("=" * 90)
    print("  · WSL IP 在 WSL 重启后会变，重跑本脚本即可同步")
    print("  · 想用固定的 127.0.0.1，需管理员运行：")
    print("      netsh interface portproxy add v4tov4 listenaddress=127.0.0.1 \\")
    print(f"        listenport=30800 connectaddress={ip} connectport=30800")


if __name__ == "__main__":
    main()
