# ══════════════════════════════════════════════════════════════
#  scripts/ci/agent/Dockerfile —— Jenkins Agent 镜像（权威 recipe）
#
#  为什么需要自建：
#    官方 jenkins/inbound-agent 里【没有】docker / kubectl / git / python3，
#    而我们的流水线全都要用。
#
#  为什么用 Alpine（不是 Debian）：
#    Debian 的 apt-get 装 git+python3+docker-cli 要下载 100+ MB，很慢。
#    Alpine 的 apk 包小得多，同样的工具集快 5-10 倍。
#
#  工具清单（对应流水线的实际需求）：
#    docker   —— 构建镜像（⭐ 用宿主 docker.sock，命中 30.7GB 层缓存）
#    kubectl  —— 预检/apply/rollout/rollback
#    git      —— 记录 commit、状态检查
#    python3  —— verify-march7.py / bench.py
#    jq       —— 解析 JSON
#    envsubst —— 渲染 manifest 模板（gettext 提供）
#
#  构建：
#    docker build -t dsh/jenkins-agent:1.1 scripts/ci/agent/
#    （或在 WSL 里跑 /srv/k3s-vllm-platform/_build-agent-1.1.sh，带自检）
# ══════════════════════════════════════════════════════════════
FROM jenkins/inbound-agent:alpine

USER root

# ── 基础工具（apk：小、快）──
RUN apk add --no-cache \
      docker-cli \
      kubectl \
      git \
      python3 \
      py3-pip \
      jq \
      gettext \
      bash \
      curl \
      ca-certificates \
      tzdata \
 && cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime \
 && echo "Asia/Shanghai" > /etc/timezone

# ══════════════════════════════════════════════════════════════
#  ⭐⭐ 1.1 版唯一的改动：跳过 git 的 dubious ownership 检查
#
#  现象（1.0 上实测）：
#     agent pod 里以 root(uid 0) 跑，仓库 /srv/k3s-vllm-platform
#     属主是 uid 1000(user) —— 因为它是 WSL 的 drvfs 挂载
#     ⇒ git 直接拒绝操作：
#         fatal: detected dubious ownership in repository at '/srv/k3s-vllm-platform'
#
#  原因：git ≥ 2.35.2 为修 CVE-2022-24765 加的保护，属主与当前
#       用户不一致就拒绝（防的是「共享目录里被塞了恶意 .git」）。
#
#  修法：写进【系统级】配置 /etc/gitconfig
#        · 对 root 和 jenkins 都生效，不依赖 $HOME / $XDG_CONFIG_HOME
#        · 一次烘进镜像，流水线里不用每条 git 命令都加 -c safe.directory
#
#  ⚠️ '*' = 信任所有目录。本地单人开发环境可以这么干；
#     多租户共享的 CI 上应该改成具体路径（如 safe.directory /srv/k3s-vllm-platform）。
# ══════════════════════════════════════════════════════════════
RUN git config --system --add safe.directory '*'

# ── 自检 1：工具齐全（构建期就暴露问题，而不是等到跑流水线）──
RUN set -eux; \
    for t in docker kubectl git python3 jq envsubst bash; do \
      command -v "$t" >/dev/null || { echo "缺少: $t"; exit 1; }; \
    done; \
    echo "✅ 工具齐全"

# ── 自检 2：safe.directory 真的写进去了 ──
RUN set -eux; \
    v=$(git config --system --get-all safe.directory); \
    [ "$v" = "*" ] || { echo "❌ safe.directory 没写对: '$v'"; exit 1; }; \
    echo "✅ safe.directory = $v"

# 回到 jenkins 用户（但 k8s 里我们会用 runAsUser: 0，因为 docker.sock 是 root:docker）
USER jenkins
