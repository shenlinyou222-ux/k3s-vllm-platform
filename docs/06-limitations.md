# 06 · 诚实边界 ⭐

> 一个只讲自己优点的 README 不值得信。
> 这一节是**主动**写出来的：这套系统**做不到什么**、哪里在裸奔、下一步该补什么。

---

## 一、按严重程度排序的缺口

### 🔴 高：会直接导致「以为安全，其实不安全」

| # | 缺口 | 后果 | 想补的话 |
|---|---|---|---|
| 1 | **没有 ArgoCD / Flux，是 apply 型流水线** | **删掉 yaml 不会删掉集群对象**。删资源必须手工 `kubectl delete`，否则静默变成孤儿 | 上 Argo CD / Flux（要引入 CRD + 控制器，单节点要评估开销） |
| 2 | **无 livenessProbe**（只有 readiness/startup） | 进程**假死**（不是崩溃）不会被 k8s 重启，只有 readiness 会把流量摘掉 | 加 `livenessProbe`；注意 vLLM 加载慢，`initialDelaySeconds` 要给足 |
| 3 | **「失败自动回滚」曾经从未生效过** | `cleanWs()` 放在 post 的 `always` 里，比 `failure` **先**跑 → 工作区被删 → 回滚脚本找不到。**实测构建 #24 才暴露** | 已修（移到 `cleanup`）。⚠️ 教训：**"有这条代码"≠"这条路径被执行过"** |
| 4 | **`MODE` 参数曾经是摆设** | UI 上选 `dry`（只预检）**照样真 apply → 真重启 vLLM** | 已修（接 `when` 表达式）。⚠️ 同一条教训 |
| 5 | **预检退出码 `2` 曾被 `sh -xe` 吃成红色失败** | 「无需发布」的正常路径在 UI 上是红叉（**构建 #7**） | 已修（`set +e`）。⚠️ 同一条教训 |

> 上面 3/4/5 三条是同一类问题：**流水线里的分支从来没有被真正走过**，
> 所以代码看起来对，行为是错的。这类 bug 只有"故意制造失败"才能发现。

### 🟠 中：能力缺失，但不致命

| # | 缺口 | 后果 | 想补的话 |
|---|---|---|---|
| 6 | **无 HPA**（全集群 **0** 个） | 突发流量没有自动扩容。**但单卡 8GB 的显存上限本来就是硬约束** —— 扩容也只能扩到 `--gpu-memory-utilization` 允许的程度，所以这条的优先级其实不高 | 真要做得先解决显存，不是加 HPA |
| 7 | **Prometheus 用 emptyDir，无持久化** | **重启丢 24h 数据** | 建 PVC + `--storage.tsdb.path` 指向它 |
| 8 | **无日志采集栈** | 没有 Loki/ELK。历史日志只在容器 ring buffer 里，**pod 一删就没了**。而 CI 每次都重建 pod → 每次发布等于丢一次历史 | Loki + promtail |
| 9 | **无告警规则** | 只有面板，没有 Alertmanager → 出问题要**人去看** | `alert.rules` + Alertmanager |
| 10 | **无 tracing** | 只有指标 + 日志，没有 span；跨服务调用链查不了 | OTel + Tempo/Jaeger |
| 11 | **无多环境** | 只有一个集群。没有 staging/生产之分，「预检 + 三层验证」就是这个空缺的替代品 | 单节点上多开 namespace 意义有限；要真做得有第二台机器 |
| 12 | **单副本 + `Recreate`** | 发布期间**服务完全不可用**（vLLM 加载要 3-5 分钟，最坏 18 分钟中断） | 用 `RollingUpdate` 会**两个 pod 抢同一块 GPU** → 需要先解决 GPU 共享 |

### 🟡 低：可维护性 / 可重现性

| # | 缺口 | 后果 | 想补的话 |
|---|---|---|---|
| 13 | **无 Terraform** | 集群本身（k3s 安装、GPU 驱动、`nvidia-container-toolkit`、docker 代理 + `NO_PROXY`）**全靠文档 + 手工**，不可重现 | Terraform / Ansible；至少写一份"从裸机到可跑"的脚本 |
| 14 | **无 helm chart 化** | 参数（模型名 / 显存比例 / NodePort）散在 yaml 里，换一套配置要手工改多处 | Helm / Kustomize。**但要承认**：单节点 8 个 yaml，Helm 的抽象成本可能高于收益 |
| 15 | **MongoDB 审计通道已死** | deployment **已不存在**，只剩 PVC 和 NodePort **残留在集群里** | 确认数据不需要后删 PVC + PV |
| 16 | **孤儿资源未清** | `cm/vllm-cn-mask`、`cm/vllm-gencfg`、20Gi + 10Gi 两个废弃 PV、16 个僵尸 ReplicaSet | 见 [docs/05 第十三节](05-runbook.md) |
| 17 | **模型权重不进版本控制** | 1-2GB 的产物，靠 **sha256 指纹清单**（`models.lock`）代替。**指纹能证明"没变"，不能证明"是对的"** | 指纹 + 可重现的训练/量化流水线 |
| 18 | **一个 PV 覆盖所有模型** | `PV.spec.local.path` **创建后不可变**（实测 `persistentvolumesource is immutable after creation`）→ 换存储根目录要新建 PV + PVC + 改 `claimName`，三处一起改 | 可接受；已写进文档 |

---

## 二、这套系统的**根本**弱点（不是功能缺失，是设计假设）

> 这一条比上面全部加起来都重要。

### 假设 1：判据的质量 = 参考数据的质量

`verify-embed.py` 的威力来自 `embed_reference.json` —— 但那份参考向量
是**用一次性脚本（`_gen_embed_ref.py`，不进仓库）在本地 HF 上算出来的**。

**如果参考向量本身算错了（比如生成时用错了池化方式），三层验证会全绿，而服务是错的。**
只是把"错的"系统性地固化下来。

**缓解**：另有语义序判据（`sim(把模型删掉, 删除模型文件) > sim(把模型删掉, 今天天气不错)`）
—— 它防的是"向量全对但语义反了"，能抓一部分这类错误。
**但这不是完全的证明。**

### 假设 2：性能判据是**单机、空载、串行**的

`bench.py` 是预热 3 次 + 正式 10 次**串行**请求。它测的是**单流延迟**，
**不是吞吐上限**。

- 并发 64 时的表现、显存压力下的退化、长上下文下的行为 —— **都不在判据内**
- 所以「性能达标」只意味着「单流没退化」，不意味着「服务能扛」

**缓解**：CPU/内存的 limits 是按**实测并发**（cgroup `cpu.stat`，并发 8/16/32）定的，
不是拍的。但那是**资源**判据，不是**性能**判据。

### 假设 3：`nvidia.com/gpu` 在 WSL 上是【声明式】的，不是强制隔离

dockerd 的 `default-runtime=nvidia` 会给**每个**容器注入 `/dev/dxg`
→ **不申请 `nvidia.com/gpu` 的 Pod 照样能用 GPU**。

买到的是：

- ✅ **调度准入**：k8s 不让超过 N 个 GPU Pod 落地（实测申请 3 个 → Pending）
- ✅ **可见性**：`kubectl describe node` 看到 GPU、谁占了 GPU 一目了然
- ❌ **不是**"没申请就用不了"

**⇒ 「显存隔离」在这台机器上完全靠 vLLM 自己的
`--gpu-memory-utilization` / `--kv-cache-memory` 自我约束。**
一个写错的 Pod 就能把整卡吃光，而 k8s 不会阻止它。

### 假设 4：单节点 = 没有真正的高可用

- k3s 单节点、单 GPU、单副本
- `systemctl restart docker`（为了改 `NO_PROXY`）会**杀掉所有 pod**
- 节点本身挂了就全挂

**⇒ 「14 天连续运行」是一个**可用性观察**，不是一个**可用性保证**。**
它的真实含义是：这 14 天里没有人重启过 docker，也没有人拔过电源。

---

## 三、还想过但**没做**的事（以及为什么）

| 想法 | 为什么没做 |
|---|---|
| **Gitea + Generic Webhook Trigger**（秒级触发，替代 2 分钟轮询） | 只为省 2 分钟延迟而多一个要运维的服务，单机不划算。已写清代价 |
| **DCGM exporter**（比 nvidia-smi exporter 专业） | **DCGM 官方不支持 WSL2** |
| **MIG**（真正的显存切分） | **RTX 5060 不支持 MIG**（A100/H100 才有） |
| **`timeSlicing` 调大到更多副本** | **槽位变多不会变出显存**。这张卡只有 8151 MiB |
| **RollingUpdate** 替代 `Recreate` | 会**两个 pod 抢同一块 GPU**，先解决共享问题 |
| **把 `_*.sh` 一次性脚本也版本化** | 仓库策略：只版本化基础设施。**代价已经付过了** —— 两个 CM 因此漂移（见下） |
| **模型权重进 git** | 1-2GB × 多个。用指纹清单代替 |
| **把 `embed_reference.json` 的生成脚本也进仓库** | ⚠️ **这其实是个该补的缺口** —— 参考数据不可重现，等于判据的"锚点"不可重现 |

---

## 四、已付过代价的教训（值得单独记）

### 「不在仓库里」=「漂移无人知」—— 同一个坑踩了两次

**第一次**：`vllm-gencfg-2b` 和 `vllm-uvicorn-logcfg` 是用一次性 `_*.sh`
直接建到集群里的，而 `_*.sh` 被 `.gitignore` 排除。后果：

1. **从 main 重建集群 → pod 起不来**（Deployment 挂载的 CM 不存在）
2. **`kubectl diff` 看不见它们的漂移**

**第二次**：`prometheus-config` 和 `grafana-dashboard-vllm` 也是同样来源。
后果更隐蔽：里面的抓取目标早就烂了（指向两个已不存在的服务）→
跑了两天的 `vllm-march7` 和刚上线的 `vllm-embed` **一条指标都没被采集**，
Grafana 上曲线一直是空的 —— **而且没有人注意到**。

> **「服务在跑」和「服务在被观测」是两件事。** 第二次踩之所以更危险，
> 是因为它不报错：面板只是"空着"。

### 「有这条代码」≠「这条路径被执行过」

三条同一类问题（见第一节 3/4/5）：失败自动回滚、`MODE` 参数、退出码 `2`。
它们的共同点是**代码看起来完全正确**，而 bug 只在特定条件下触发，
而那个条件**从来没出现过**：

- 自动回滚：#24 之前**从来没有构建失败过**
- SIGPIPE 假阴性：Jenkins 里每次都是**刚重启的新 pod**（日志短）→ 从不触发

**⇒ 验证一条错误处理路径的唯一办法是故意制造那个错误。**
（这次是靠"拿一个跑了 13h 的 pod 测"和"真的让一次构建失败"发现的。）

### 「看起来成功了」是最危险的

`set -euo pipefail` + 每步有判据，就是对这条的工程回答。
最典型的就是 **「假成功」**：CM 更新了、pod 还跑着旧配置、而验证照样全绿。

---

## 五、如果你要复用这套东西，先改这几处

| 优先级 | 要改什么 | 在哪里 |
|---|---|---|
| 🔴 | **凭据不要写明文** | `k8s/jenkins/jenkins-secret.yaml`（现在是 `REPLACE_ME_...`）。推荐 SealedSecret / SOPS |
| 🔴 | **Grafana 的 `GF_SECURITY_ADMIN_PASSWORD` 走 `valueFrom` + Secret** | 本仓库**不含** Grafana Deployment（它从来没进过仓库）—— 你自己写的时候别抄成明文 |
| 🔴 | 路径占位符 | `/srv/k3s-vllm-platform` / `/srv/k3s-vllm-platform.git` → 你的路径 |
| 🟠 | 模型路径 | `MODELS_DIR`（`lib.sh` 与 `check-models.py` 都用它，可用 `CI_MODELS_DIR` 覆盖） |
| 🟠 | NodePort | `30800/30801/30802/30803` 与 `30030/30080/30090/30097/30500/30871`（有占用冲突就换） |
| 🟠 | 生成 `models.lock` | `python3 ci/scripts/check-models.py --write`（**换模型后必做**，否则预检会拦住你） |
| 🟠 | 生成 `embed_reference.json` | 换 embedding 模型后**必须**重新生成并重跑 `verify-embed.py` |
| 🟡 | `safe.directory '*'` | agent Dockerfile 里为了本地单人环境放宽了；**多租户 CI 上要改成具体路径** |

---

## 六、脱敏记录

公开前对这个仓库做过的处理（细节见各文件内的 `脱敏说明` 注释）：

| 类别 | 处理 |
|---|---|
| **明文凭据（1）** | Jenkins 管理员密码 → `REPLACE_ME_...` 占位符 + 说明该走 Secret 注入 |
| **明文凭据（2）** | Grafana 的 `GF_SECURITY_ADMIN_PASSWORD` 原值 → 指向该字段并注明本仓库**不含** Grafana Deployment；文档里原来的固定 `admin` 默认口令组合也一并去掉了 |
| **内网 IP** | `<WSL-IP>` / `<proxy-host>` 占位符（RFC1918 地址本身不算敏感，但没必要公开；同时避免读者以为这是可直连的地址） |
| **个人宿主路径** | `/mnt/e/<私仓>` → `/srv/k3s-vllm-platform`；私仓的裸仓库路径 → `/srv/k3s-vllm-platform.git` |
| **项目代号** | 统一成 `k3s-vllm-platform`（包括 `part-of` 标签、JCasC `systemMessage`、Jenkins job 名） |
| **下游应用配置** | `tools/sync_k3s_endpoint.py` 里写死的第三方应用设置路径 → 环境变量 `ST_SETTINGS` |
| **CI 产物** | `logs/ci/` 里的 `diff-*` / `snapshot-*` / `live-backup-*` / `apply-*` / `cm-*` **没有搬**（可能含内部信息）→ **只搬了 `bench-*.txt`** 作为性能证据 |
| **一次性脚本** | `_*.sh` / `_*.py`（几百个）**没有搬** —— 它们是被 `.gitignore` 排除的临时脚本，且大量含个人路径 |
| **WSL IP 缓存文件** | `wsl-ip.txt` 没有搬，并已加进 `.gitignore`（机器 IP 不该进仓库） |

### 刻意**保留**的两类

| 保留 | 理由 |
|---|---|
| `legacy-scripts/wsl-verify-k8s-vllm.sh` 里的 `ClusterIP 10.43.x.x` / `Pod IP 10.42.x.x` | k3s 的**默认** Service/Pod CIDR，且这两个地址**每次重建都会变**。它们在这里的作用是演示「NodePort / Service / Pod IP 三层要分开查」这个排查方法 —— 抹掉就没法读了 |
| `ops@k3s-vllm.local` 之类的**假**域名/邮箱 | 占位性质，不可达 |

> 自查命令（读者可复用）：
> ```bash
> git grep -i -nE 'password|passwd|token|secret|api[_-]?key'
> ```
> 剩下的匹配应该全部是**占位符、字段名（如 `tokenizer.json`、`max_tokens`）、
> 或"该走 Secret 注入"之类的说明文字** —— 这条判断我逐条过了一遍，
> 结果见仓库的首次 commit 说明。
