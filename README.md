# k3s-vLLM-platform

> 单节点 k3s GPU 推理平台的 **CI/CD + 可观测性** 工程。
> 不是"我在 k3s 里跑了 vLLM"这种教程级 demo —— 真正的东西在 `ci/scripts/`：
> **一套把「发布到底生效了没有」变成可执行判据的验证工程。**

---

## 30 秒看懂卖点

| # | 问题 | 一般做法 | 这里的做法 | 证据 |
|---|---|---|---|---|
| 1 | 「apply 成功了」≠「改动生效了」 | `kubectl apply` + `rollout status` 就收工 | apply 前后比对 Deployment **引用到的每个 ConfigMap 的 `resourceVersion`**，CM 变了而 generation 没变 → **自动补 `rollout restart`** | [`deploy.sh:104-139`](ci/scripts/deploy.sh#L104-L139) |
| 2 | ConfigMap 改了但 pod 不重启 = **「假成功」**：验证全绿、配置是旧的 | 靠人记得重启 | 把上面这条做成流水线的一步，并在日志里明说原因 | 见 [docs/02](docs/02-deployment-pipeline.md) |
| 3 | `set -o pipefail` + `grep -q` 的 **SIGPIPE 假阴性**：命中了反被判失败 | 潜伏几个月，短日志时复现不出来 | 用 here-string 替代管道（`grep -q PAT - <<< "$VAR"`），并在代码里写清为什么 | [`verify.sh:28-39`](ci/scripts/verify.sh#L28-L39) |
| 4 | 「返回了 768 维向量」= 验证通过？**三个旋钮配错照样返回形状对的向量，但语义是错的** | 检查维度/状态码 | **逐条向量比对**本地 HF 参考向量，cos ≥ 0.999；实测 8/8 = 1.000000 | [`verify-embed.py`](ci/scripts/verify-embed.py)、[`embed_reference.json`](ci/scripts/embed_reference.json) |
| 5 | `--model=` 路径写错 → 要等 `rollout status` 满 **900s** 才失败，而这期间服务完全 DOWN | 等它超时 | 预检阶段做**模型权重 sha256 指纹校验**（6 文件，全量约 **4.4 秒**） | [`check-models.py`](ci/scripts/check-models.py)、[`models.lock`](k8s/live/models.lock) |
| 6 | 权重被**就地替换**（路径没变）→ `kubectl diff` 为空 → 判「无需发布」→ 服务还跑着旧权重 | 无感 | 同上，用指纹清单抓 | 同上 |
| 7 | `kubectl ... -o jsonpath='{.items[0]...}'` 在 **replicas=0** 时数组越界 → `set -e` 崩 → 触发**没必要的自动回滚** | 无感 | `target_pod()` 占位函数 | [`lib.sh:141-165`](ci/scripts/lib.sh#L141-L165)，构建 #33 实测 |
| 8 | 指标算出来 p50=150 ms，真值 **7.4 ms** —— **偏 20 倍** | 直接信 `histogram_quantile` | 定位到 vLLM 的 `e2e_request_latency_seconds` **硬编码最小桶 0.3s**，而服务 7ms → 全落一个桶，插值产物。改用 `time_to_first_token_seconds`（**1ms 起桶**） | [docs/03](docs/03-observability.md) |
| 9 | GPU 在 k8s 里 **完全不可见**（靠 dockerd 隐式注入），不能调度/计量 | 就这么跑 | 装 WSL 适配版 device plugin，`nvidia.com/gpu` **0 → 4**；解掉 3 个 WSL 特有适配点 | [`70-nvidia-device-plugin.yaml`](k8s/live/70-nvidia-device-plugin.yaml)、[docs/04](docs/04-gpu-on-wsl2.md) |

**再加一条工程纪律**：Jenkinsfile **不重复实现任何判据** —— 只调 `ci/scripts/` 下的脚本。
所以同一套逻辑本地能手工跑、CI 能跑、Jenkins 挂了也照样能发布。

---

## 架构

```
                        ┌──────────────────────────────────────────────┐
   git push             │  Jenkins Controller (ns: cicd)               │
  ───────────► 裸仓库 ──►│  · JCasC 脚本化建账号（密码从 Secret 注入）    │
              (origin)  │  · Kubernetes 插件【动态创建】agent pod        │
                        │    （不用常驻 agent，不用人工拿 JENKINS_SECRET）│
                        └───────────────────┬──────────────────────────┘
                       pollSCM('H/2 * * * *') 每 2 分钟轮询
                                            ▼
                        ┌──────────────────────────────────────────────┐
                        │  Agent pod (label: wsl-docker, runAsUser: 0) │
                        │  挂宿主 docker.sock / 裸仓库 / 模型权重目录    │
                        │                                              │
                        │  ① precheck.sh   git 干净 → 权重 sha256 指纹  │
                        │                  → md5 可验证备份 → dry-run    │
                        │                  → kubectl diff → 快照        │
                        │  ② deploy.sh     apply → CM 变了补 restart    │
                        │                  → rollout status (900s)     │
                        │  ③ verify.sh     日志层 / 功能层 / 性能层      │
                        │  ④ rollback.sh   rollout undo / --from-backup│
                        └───────────────────┬──────────────────────────┘
                                            │ kubectl apply -f k8s/live/
                                            ▼
   ┌──────────────────────────── 单节点 k3s (WSL2) ────────────────────────────┐
   │                                                                          │
   │  ns: default                            ns: monitoring                   │
   │  ├─ deploy/vllm-march7   生成式 LLM      ├─ prometheus  (抓 5s / 留 24h)   │
   │  │   NodePort 30800 / 30801            └─ grafana     (4 个仪表盘)        │
   │  ├─ deploy/vllm-embed    向量服务                                          │
   │  │   NodePort 30802        ns: kube-system                                │
   │  ├─ deploy/llama-asr     CPU 语音      └─ nvidia-device-plugin (DaemonSet) │
   │  │   NodePort 30803        → nvidia.com/gpu 可调度                        │
   │  └─ PV models-pv → /srv/.../npc-models （一个 PV 覆盖所有模型）             │
   └──────────────────────────────────────────────────────────────────────────┘
```

**硬件**：单卡 RTX 5060（8 GB，**sm_120**），集群连续运行 14 天，
上面同时跑 3 个推理服务 + 监控 + CI。

---

## 30 秒上手（本地手工跑，不依赖 Jenkins）

```bash
git clone <this-repo> && cd k3s-vllm-platform

# ① 改清单
vim k8s/live/10-vllm-mongo.yaml

# ② 看差异（不改线上）—— 这一步曾经抓到误改的 --max-num-seqs=64 → 2048
./ci/scripts/precheck.sh
CI_TARGET=embed ./ci/scripts/precheck.sh     # 管向量服务那套判据

# ③ 发布（CM 变了会自动补 rollout restart）
./ci/scripts/deploy.sh

# ④ 三层验证
./ci/scripts/verify.sh                        # 日志层 + 功能层 + 性能层
./ci/scripts/verify.sh --layer=log            # 只跑某一层

# ⑤ 出问题
./ci/scripts/rollback.sh                      # rollout undo
./ci/scripts/rollback.sh --from-backup        # 改的是 ConfigMap 时用这个
```

一键跑完 + **失败自动回滚**：

```bash
./ci/scripts/pipeline.sh
CI_YES=1 ./ci/scripts/pipeline.sh             # 无人值守
./ci/scripts/pipeline.sh --dry                # 只预检
```

**两个服务靠 `CI_TARGET` 分派**（默认 `march7`，不传时行为与单服务时完全一致）：

| `CI_TARGET` | Deployment | 功能验证 | 性能判据 |
|---|---|---|---|
| `march7`（默认） | `vllm-march7` | `verify-march7.py` | **tok/s ≥ 100** |
| `embed` | `vllm-embed` | `verify-embed.py` | **req/s ≥ 20** |

---

## 实测数字（都有出处）

| 指标 | 实测 | 门槛 | 出处 |
|---|---|---|---|
| 生成服务稳态吞吐 | **141.8 – 160.3 tok/s** | ≥ 100 | [`benchmarks/results/`](benchmarks/results/) |
| 向量服务吞吐 | **113.6 req/s** | ≥ 20 | [`bench-20261008-121737.txt`](benchmarks/results/bench-20261008-121737.txt) |
| 向量服务单条延迟（中位） | **7.60 ms** | — | 同上 |
| 向量功能验证 | **8/8 条 cos = 1.000000** | ≥ 0.999 | [`verify-embed.py`](ci/scripts/verify-embed.py) + `embed_reference.json` |
| 模型权重指纹校验 | **6 文件 / 全量约 4.4 秒** | — | [`check-models.py`](ci/scripts/check-models.py) |
| 节点 `nvidia.com/gpu` | **0 → 4**（`timeSlicing.replicas=4`） | — | [`70-nvidia-device-plugin.yaml`](k8s/live/70-nvidia-device-plugin.yaml) |
| 显存实测 | march7 **6543 MiB** / embed **693 MiB**（差分测量） | — | [`k8s/live/README.md`](k8s/live/README.md) |
| 流水线运行次数 | **34 次构建 / 30 SUCCESS**（见下方口径说明） | — | 见「数字口径」 |

> ### 数字口径（诚实标注）
> - `34 构建 / 30 SUCCESS` 来自工作仓库里的 Jenkins 构建记录，是本仓库**抽取时由作者提供**的。
>   内核证据是本仓库里交叉出现的构建号引用：**#7 #9 #13 #24 #33** ——
>   其中 **#33 的存在证明至少跑过 33 次构建**（[`lib.sh:152`](ci/scripts/lib.sh#L152)、
>   [`rollback.sh:156`](ci/scripts/rollback.sh#L156) 都记了这次）。
>   「30 SUCCESS」这个比值我**无法在仓库内独立复核**。
> - 吞吐数字来自 `benchmarks/results/` 里 8 份真实的 CI 性能产物。

---

## ⚠️ 诚实边界（这套东西做不到什么）

> 这一节是**主动写出来**的 —— 一个只讲自己优点的 README 不值得信。
> 完整版在 [docs/06-limitations.md](docs/06-limitations.md)。

| 缺口 | 后果 |
|---|---|
| **没有 ArgoCD / Flux** | 这是 **apply 型**流水线：**删掉 yaml 不会删掉集群对象**。删资源必须手工 `kubectl delete`。 |
| **无 HPA**（全集群 0 个） | 突发流量没有自动扩容。单卡 8GB 的显存上限本来就是硬约束，扩容也只能扩到 --gpu-memory-utilization 允许的程度。 |
| **无 livenessProbe** | 进程假死（不是崩溃）不会被 k8s 重启，只有 readiness 会把流量摘掉。 |
| **Prometheus 用 emptyDir** | **无持久化**：重启丢 24h 数据。 |
| **无日志采集栈** | 没有 Loki/ELK，历史日志只在 `kubectl logs` 的容器 ring buffer 里，pod 一删就没了。 |
| **MongoDB 审计通道已死** | deployment 已不存在，只剩 PVC 和 NodePort 残留在集群里。 |
| **无 Terraform / 无 helm chart 化** | 集群本身（k3s 安装、GPU 驱动、docker 代理）靠文档 + 手工，不可重现。 |
| **GPU 隔离是「声明式」的** | WSL 上 dockerd 的 `default-runtime=nvidia` 会给**每个**容器注入 `/dev/dxg` —— 不申请 `nvidia.com/gpu` 的 Pod 照样能用 GPU。买到的是**调度准入 + 可见性**，不是强制隔离。 |
| **`timeSlicing.replicas` 不是显存配额** | 它只是"允许多少个 Pod 声称要用 GPU"。槽位调大不会变出显存。 |

---

## 目录结构

```
k3s-vllm-platform/
├── README.md                    ← 你在这里
├── docs/
│   ├── 01-architecture.md       组件地图 + 为什么这么分
│   ├── 02-deployment-pipeline.md ⭐ precheck → deploy → verify → rollback
│   ├── 03-observability.md       ⭐ 桶边界 20 倍偏差 / emptyDir / TTFT 替代 e2e
│   ├── 04-gpu-on-wsl2.md         ⭐ device plugin 三个适配点 + 三条边界
│   ├── 05-runbook.md             故障速查（SIGPIPE / CM 假成功 / jsonpath 越界 /
│   │                                NodePort DNAT / 掩码失效 / rollout 超时）
│   └── 06-limitations.md         ⭐ 主动写缺口 + 想清楚「下一步该做什么」
├── k8s/
│   ├── live/                     ⭐ 线上资源唯一事实来源（8 个 yaml + models.lock）
│   ├── jenkins/                  Jenkins Controller / JCasC / RBAC / Secret 模板
│   └── legacy/                   历史 manifest（不参与部署，只供查阅）
├── ci/
│   ├── Jenkinsfile               声明式流水线（只编排，不实现判据）
│   ├── agent/Dockerfile          Jenkins Agent 镜像
│   └── scripts/                  ⭐ 14 个脚本 —— 这套系统的本体
├── benchmarks/results/           8 份 CI 性能产物 + A/B 纪律说明
├── dashboards/                   4 个 Grafana dashboard JSON（可直接 Import）
├── tools/                        sync_k3s_endpoint.py + k3s-endpoints.json
└── legacy-scripts/               早期 wsl-*.sh（已被 CI 取代，作历史）
```

---

## 脱敏声明

本仓库是从一个私人工作仓库里**抽取**出来的，公开前做过脱敏：

- 明文凭据 → 占位符（`REPLACE_ME_...`）+ 说明该走 Secret 注入
- 内网 IP / 个人宿主路径 / 项目代号 → 通用占位符（`<WSL-IP>`、`/srv/...`）
- `logs/ci/` 里的 diff / snapshot / live-backup **没有搬**（可能含内部信息），
  只搬了 `bench-*.txt` 作为性能证据

细节见 [docs/06-limitations.md](docs/06-limitations.md) 末尾与各文件内的 `脱敏说明` 注释。

---

## 许可

MIT（见 `LICENSE`）。清单与脚本按「原样」提供，不含任何模型权重。
