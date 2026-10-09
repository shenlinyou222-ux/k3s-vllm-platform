# `k8s/live/` —— 线上资源的唯一事实来源

**这个目录下的每个 `.yaml` 都会被流水线 apply。** 想看集群里跑的是什么，看这里就够了。

```
10-vllm-mongo.yaml            vLLM 主体 + Service + PV/PVC + StorageClass + 可观测性 env
20-vllm-gencfg-2b.yaml        服务端默认采样参数（475 条 logit_bias 屏蔽非中文 token）
30-vllm-uvicorn-logcfg.yaml   uvicorn / vLLM 的日志 dictConfig
40-vllm-embed.yaml            ⭐ 向量服务（vllm-embed / dmeta-embedding-zh-small，/v1/embeddings）
50-prometheus-config.yaml     ⭐ Prometheus 抓取配置（monitoring ns）
60-grafana-dashboards.yaml    ⭐ Grafana 三个仪表盘（monitoring ns，含新增的 embed 盘）
70-nvidia-device-plugin.yaml  ⭐ NVIDIA device plugin（WSL 适配版，让 nvidia.com/gpu 可调度）
```

> 数字前缀只是为了让顺序稳定、便于阅读，`kubectl apply` 本身不关心顺序。
> `.md` 之类的非 yaml 文件会被 kubectl 自动忽略，所以本文件放在这里没问题。

---

## ⭐ 现在有两个 vLLM 服务（2026-10-08 起）

同一个 PV、同一块 GPU，但是两个独立 Deployment，各自有独立的判据：

| | `vllm-march7`（10 号文件） | `vllm-embed`（40 号文件） |
|---|---|---|
| 类型 | 生成式 LLM | 向量模型（embedding） |
| 模型 | Qwen3.5-2B-March7-cn | dmeta-embedding-zh-small（8 层 / 74M） |
| 服务名 | `march7v3` | `dmeta-small` |
| 接口 | `/v1/chat/completions` | `/v1/embeddings` |
| NodePort | 30800 / 30801 | **30802** |
| runner | 默认 generate | **`--runner=pooling`** |
| 显存占比 | 0.55 | 0.15 |
| 验证脚本 | `verify-march7.py` | `verify-embed.py` |
| 性能判据 | **tok/s ≥ 100** | **req/s ≥ 20** |

**流水线按 `CI_TARGET` 选目标**（Jenkins 里是构建参数 `TARGET`）：

```bash
CI_TARGET=march7 ./ci/scripts/pipeline.sh     # 默认，管 vllm-march7
CI_TARGET=embed  ./ci/scripts/pipeline.sh     # 管 vllm-embed
```

⚠️ 自动触发（pollSCM）时没有参数 → `CI_TARGET` 为空 → lib.sh 兜底成 `march7`
→ 自动构建的默认行为与以前完全一致。

### 为什么 embedding 的判据不能只是"返回了 768 维向量"

vLLM 服务 BERT 时有三个旋钮，**配错任何一个都照样返回形状正确的向量，但语义是错的**：

| 旋钮 | 正确值 | 配错的后果 |
|---|---|---|
| `pooling_type` | `CLS` | 换成 MEAN/LAST → 向量含义完全不同 |
| `use_activation` | `False` | 默认 True 会把向量 L2 归一化到 1.0，与读出头训练时的分布不符 |
| `dtype` | `float32` | bf16 会有数值漂移 |

所以 `verify-embed.py` 做的是**逐条向量比对**：拿 `scripts/ci/embed_reference.json`
里本地 HF 模型算出的参考向量跟服务端返回的比 cos，要求 ≥ 0.999。
这个文件由 `_gen_embed_ref.py` 生成（一次性脚本，不进仓库）。

实测（2026-10-08）：**8 条全部 cos = 1.000000**，L2 范数也逐条对上。

### 怎么换 embedding 模型

和生成模型一样 —— 改一行 + 重建指纹 + push：

```bash
vim k8s/live/40-vllm-embed.yaml      # 改 --model=/models/<新目录名>
python3 scripts/ci/check-models.py --write
git add k8s/live/ && git commit -m "chore(model): 换向量模型" && git push
```

⚠️ 换模型时**必须同时确认三件事**（新模型的池化方式可能不同）：

1. `--runner=pooling` 要留着（去掉就会被当生成模型加载）
2. 池化方式 —— BERT 类模型 vLLM 默认 CLS，但 E5 类是 MEAN。换模型后
   **必须重新生成 `embed_reference.json` 并重跑 `verify-embed.py`**
3. `--pooler-config={"use_activation":false}` 要留着（除非读出头是重新训的）


---

## 怎么改 → 怎么发

```bash
# ① 改文件
vim /srv/k3s-vllm-platform/k8s/live/10-vllm-mongo.yaml

# ② commit + push（origin = 裸仓库 /srv/k3s-vllm-platform.git）
git -C /srv/k3s-vllm-platform add k8s/live/
git -C /srv/k3s-vllm-platform commit -m "chore: 调 max-model-len"
git -C /srv/k3s-vllm-platform push

# ③ 就这样。Jenkins 每 2 分钟轮询 origin，发现新提交就【自动构建 + 自动部署】。
#    想立刻跑 / 想选模式：
#    Jenkins UI → vllm-platform-deploy → Build with Parameters → MODE=full|restart-only|dry
```

**`git push` 就是部署指令。** 触发方式：Jenkinsfile 里 `triggers { pollSCM('H/2 * * * *') }`
轮询 origin（裸仓库）。为什么用轮询不用 webhook：这是单机自建，没有能发 webhook 的
Git 服务端，也不想为此装 Generic Webhook Trigger 插件并重建 Controller 镜像。
代价是最多 ~2 分钟延迟。要秒级触发就得起 Gitea，见 `k8s/legacy/README.md` 末尾的说明。

⚠️ **只有 push 上去的东西才会被部署。** 流水线**从 SCM 检出读**（agent 的 workspace），
不是读宿主的工作区 —— 本地改了但没 push 的改动进不了检出。
如果在 `k8s/live/` 里什么都没改（比如只改了文档），构建会照跑，但 `kubectl diff` 为空
→ 直接判「无需发布」→ 绿灯结束，**不会白重启服务**。

`precheck.sh` 里那道 `require_clean_git` 在 Jenkins 里是自动成立的（检出天然干净），
它主要是给本地手工跑兜底的。

---

## 改哪一类 → 选哪个 MODE

| 你改的东西 | 点 `MODE=full` 之后 | 要不要第二次操作 |
|---|---|---|
| **Deployment 的 args / image / resources / 探针 / 端口** | `apply` 改 spec → generation +1 → k8s 自动重建 pod | 不用，一次搞定 |
| **ConfigMap（本目录 20 / 30 号文件，以及 10 号里的 `vllm-observability-env`）** | `apply` 只更新 CM，**spec 没变 → 不会自动重启** | ⭐ **不用了** —— `deploy.sh` 检测到「CM 变了但 DE 没变」会**自动补一次 `rollout restart`** |
| **Service / PVC / PV / StorageClass** | `apply` 立即生效，不涉及 pod | 不用 |

这张表的第二行是 2026-10-07 补上的一个坑。补之前的行为是：

```
改 CM → apply 更新了 CM → Deployment 没变 → 不重启 → vLLM 还读着旧配置
      → 阶段④⑤⑥ 验证跑在【旧配置的 pod】上 → 全绿
      ⇒ 构建成功，但改动根本没生效（"假成功"）
```

现在 `deploy.sh` 会在 apply 前后比对 **Deployment 引用到的每个 ConfigMap 的
`resourceVersion`**，有变化且 generation 没变就自动重启，并且在日志里明说：

```
⚠️ Deployment 的 spec 没变（generation 仍为 20），但它引用的 ConfigMap 变了: vllm-observability-env
   vLLM 只在启动时读一次配置 → 自动补一次 rollout restart
   （少了这一步就是【假成功】：CM 更新了、pod 却还跑着旧配置，而验证照样全绿）
```

所以：**改任何东西都只需要 `MODE=full` 一次。**

---

## ⭐ 怎么换模型权重

### 先说一个事实：一个 PV 已经覆盖了所有模型

PV `models-pv` 指向的是**父目录** `/home/user/npc-models/`，Deployment 把它挂到容器里的
`/models`。所以「换模型」在绝大多数情况下**跟 PV 没关系**，只是改一行参数：

```
PV models-pv → /home/user/npc-models/     ← 挂到容器的 /models
                   ├── Qwen3.5-2B-March7-cn        ← 当前在跑
                   ├── Qwen3.5-0.8B-March7-cn
                   ├── Qwen3.5-0.8B-March7-v3 / -v4 / -tavern
                   ├── Qwen3.5-2B-AWQ-instruct
                   └── …
```

### 场景 A：换成 `npc-models/` 下已有的模型（最常用）

```bash
cd /srv/k3s-vllm-platform

# ① 改一行 —— 就是它
vim k8s/live/10-vllm-mongo.yaml
#    找到 args 里的：
#      - "--model=/models/Qwen3.5-2B-March7-cn"
#    改成（比如）：
#      - "--model=/models/Qwen3.5-0.8B-March7-cn"

# ② 如果这个模型以前没进过指纹清单，把它记进去
python3 scripts/ci/check-models.py --write      # 合并式，不会丢掉别的模型
python3 scripts/ci/check-models.py              # 想先看校验结果就跑这个

# ③ commit + push —— 之后什么都不用做
git add k8s/live/10-vllm-mongo.yaml k8s/live/models.lock
git commit -m "chore(model): 换成 Qwen3.5-0.8B-March7-cn"
git push
```

**之后自动发生**：pollSCM 发现新提交（≤2 分钟）→ 预检（含模型校验）→ `kubectl apply`
→ `--model=` 属于 `spec.template` → **generation +1** → k8s 自动重建 pod
→ 阶段④⑤⑥ 验证 → 全绿。

> `--write` 是**合并**式：换回来的时候只改 `--model=` 那一行就行，不用再跑它。
> 万一那个模型的权重在你不用它期间被改过，预检会报「内容变了」提醒你重新 `--write`。

### 场景 B：新增一个模型到 `npc-models/` 下

模型权重是**仓库外的产物**（1-2GB，不进 git）。所以：

```bash
# ① 把训好/量化好的模型目录放进去（宿主上，注意权限要能被 agent 的 root 读到）
ls -la /home/user/npc-models/我的新模型/
#    至少要有 config.json + 权重文件（*.safetensors / *.bin）

# ② 然后和场景 A 完全一样：改 --model= → --write → commit → push
```

### 场景 C：换到另一个存储根目录（另一块盘 / 别的路径）

`PV.spec.local.path` **创建后不可变**（实测：`spec.persistentvolumesource is immutable
after creation`），所以只能新建 PV + 新建 PVC + 改 `claimName`，三处一起改：

```yaml
# k8s/live/10-vllm-mongo.yaml
metadata: {name: models-pv-v2}            # ① PV 改名
spec.local.path: /home/user/npc-models-v2 #    指向新根目录（先在宿主上备好）
metadata: {name: models-pvc-v2}           # ② PVC 改名
spec.volumeName: models-pv-v2             #    指新 PV
volumes: [{name: models, persistentVolumeClaim: {claimName: models-pvc-v2}}]  # ③ Deployment
```

⚠️ **旧 PV/PVC 不会被 `apply` 删除** —— 它们从清单里消失后就成了孤儿，要手工收：

```bash
kubectl -n default delete pvc models-pvc      # Retain 策略 → PV 变 Released
kubectl delete pv models-pv                   # 确认旧权重不需要了再删
```

### 模型权重是怎么被校验的

`kubectl diff` 只能看见**清单里写了什么**，看不见**路径背后是什么**。所以预检
（`scripts/ci/check-models.py`）额外做两件事：

| 检查 | 拦住什么 |
|---|---|
| `--model=` 路径存在 + 必需文件齐全 | 路径写错 → 否则 vLLM 加载失败，`rollout status` 要**等满 900s** 才判失败，而这期间（`Recreate` 策略）**服务完全 DOWN** → 才回滚。最坏约 18 分钟中断 |
| 与 `models.lock` 的 sha256 指纹比对 | 权重被**就地替换**（路径没变）→ 否则 `kubectl diff` 为空、判「无需发布」，而 vLLM 还跑着旧权重 |

指纹覆盖 6 个文件（`config.json` / 权重 / `tokenizer.json` / `generation_config.json` /
`chat_template.jinja` / `output_banned_ids.pt`），全量 sha256 **约 4.4 秒**。

```bash
python3 scripts/ci/check-models.py            # 手动校验
python3 scripts/ci/check-models.py --list     # 看声明了哪些模型 + 宿主路径
python3 scripts/ci/check-models.py --write    # 更新指纹（合并）
python3 scripts/ci/check-models.py --write --prune   # 只留当前声明的模型
CI_SKIP_MODEL_CHECK=1 ...                     # 逃生口（不推荐）
```

> `models.lock` **故意不带** `.yaml` / `.json` 后缀 —— 否则 `kubectl apply -f k8s/live/`
> 会把它当 k8s 资源去解析。实测目录里 4 个文件时，kubectl 仍然只处理 10 个对象。

---

## 为什么这两个 ConfigMap 以前不在仓库里

`vllm-gencfg-2b` 和 `vllm-uvicorn-logcfg` 是 2026-10-06 用一次性的 `_*.sh` 脚本
直接建到集群里的，而 `_*.sh` 被 `.gitignore` 排除（仓库策略：只版本化基础设施，
不版本化临时脚本）。后果有两个，都已随本次纳管修掉：

1. **从 main 重建集群 → pod 起不来**（Deployment 挂载的 CM 不存在）
2. **`kubectl diff` 看不见它们的漂移** —— 屏蔽词被谁改了、改了什么，预检一无所知

`20-vllm-gencfg-2b.yaml` 是把集群里那份 JSON **美化后**存进来的（原来是一整行
8273 字节，diff 完全没法看）。值、键、键序都逐项核对过 deep-equal，唯一变化是空白。

---

## 📊 监控（2026-10-08 补上）

```
Prometheus  http://<WSL-IP>:30090        抓取间隔 5s，保留 24h
Grafana     http://<WSL-IP>:30030        用户 admin，密码见 Grafana 的 GF_SECURITY_ADMIN_PASSWORD
                                         （匿名 Viewer 也开着）
  ├─ vLLM 推理服务监控 (本地 GPU)   /d/vllm-mon        ← vllm-march7
  ├─ vLLM 向量服务监控              /d/vllm-embed-mon  ← vllm-embed ★新增
  ├─ GPU 监控 (nvidia-smi)          /d/gpu-mon
  └─ llama.cpp CPU 推理对照          /d/llamacpp-mon   （目标服务已下线）
```

### ⚠️ 补之前的状态：**两个服务都没被监控**

`prometheus-config` 这份 CM 是 12 天前用一次性脚本建到集群里的，仓库里没有。
它里面的抓取目标是：

```
vllm-qwen.default.svc.cluster.local:8000     ← 服务早已不存在 → target DOWN
llama-qwen.default.svc.cluster.local:8000    ← 服务早已不存在 → target DOWN
```

结果跑了两天的 `vllm-march7` 和刚上线的 `vllm-embed` **一条指标都没被采集**，
Grafana 上的 vLLM 曲线一直是空的。这正是本文件开头记过的
「CM 不在仓库 → 漂移无人知」那个坑，第二次踩。现已把 `prometheus-config`
和 `grafana-dashboard-vllm` 两份 CM 都导出进本目录纳管。

### 改了这两份 CM 之后要做什么

```bash
# ① Prometheus：必须手动 reload（apply 不会重启 pod）
curl -X POST http://<WSL-IP>:30090/-/reload
#    然后到 http://<WSL-IP>:30090/targets 确认 target 都是 UP

# ② Grafana：不用管 —— file provider 的 updateIntervalSeconds=10 会自己重载
#    （但要等 kubelet 把新 CM 同步到挂载卷，默认 ~60s）
```

⚠️ `deploy.sh` 的「CM 变了自动重启」逻辑只认**目标 Deployment 引用的 CM**。
这两份 CM 不属于 `vllm-march7` / `vllm-embed` 任何一方，所以不会被自动处理。

### ⭐⭐ 一个必须知道的坑：vLLM 的 e2e 延迟直方图测不了这个服务

vLLM 的 `vllm:e2e_request_latency_seconds` 桶边界是**硬编码**的
（`vllm/v1/metrics/buckets.py` 的 `REQUEST_LATENCY_BUCKETS`），**最小桶 0.3 秒**：

```
0.3, 0.5, 0.8, 1.0, 1.5, 2.0, 2.5, 5, 10, 15, 20, 30, 40, 50, 60, 120, 240, ... , 7680
```

而向量服务单条只要 **7 毫秒** → **全部 4110 条请求都落进 `le=0.3` 这一个桶**
（实测：0.3 到 +Inf 每个桶的计数完全相同，都是 4110）。
`histogram_quantile` 只能在 [0, 0.3] 之间线性插值 → 算出「p50 = 150 ms」，
**是插值产物，不是实测值（真值 7.4 ms，差 20 倍）**。
`buckets.py` 里没有任何环境变量可以覆盖这个列表。

**解法：用 `vllm:time_to_first_token_seconds`。** 它的桶是 **1 ms 起**
（`0.001, 0.005, 0.01, 0.02, 0.04, ...`），而对 pooling 模型
**TTFT 就等于端到端延迟** —— 实测两者的 `_sum`/`_count` 完全相同
（103.896 s / 3961）。所以 `embed.json` 的分位数面板用它。

| 能可靠监控 | 不能 |
|---|---|
| ✅ 可用性 `up` | ❌ **e2e 直方图的分位数**（桶太粗） |
| ✅ QPS `rate(request_success_total)` | |
| ✅ **分位数（用 TTFT 直方图）** | |
| ✅ 平均延迟 `_sum/_count`（精确） | |
| ✅ 排队/推理时间、并发、prompt token 速率 | |
| ✅ GPU（nvidia-smi exporter，指标名是 `nvidia_smi_*`） | |

---

## 🎮 GPU 资源（2026-10-08 装上了 device plugin）

```
$ kubectl describe node desktop-a00thlv
Capacity:     nvidia.com/gpu: 4        ← 装之前是 0（节点完全不认 GPU）
Allocatable:  nvidia.com/gpu: 4
Allocated:    nvidia.com/gpu  1 / 4    ← 目前只有 vllm-embed 占 1 个
```

**当前两个服务的状态（2026-10-08 晚）**

| 服务 | replicas | GPU 计数 | 实测显存 | 说明 |
|---|---|---|---|---|
| `vllm-embed` | **1** | 1 | **693 MiB** | 向量服务，在跑 |
| `vllm-march7` | **0** | 0 | 0 | ⭐ 已缩容，把 GPU 让给别的模型 |

缩容 march7 后 GPU 从 7236 MiB 降到 **4183 MiB 已用 / 3713 MiB 空闲**。
恢复它：把 `10-vllm-mongo.yaml` 的 `replicas` 改回 `1` → commit → push
（权重和 PVC 都还在，不用重新准备）。

**`timeSlicing.replicas=4`** = 最多 4 个 Pod 可以声称占用 GPU（**不是显存配额**）。
加新模型前仍然要看 `nvidia-smi` 余量 —— 这张卡只有 8151 MiB。

两个 Deployment 现在都显式声明：

```yaml
resources:
  requests: {cpu: "1", memory: "4Gi", nvidia.com/gpu: "1"}
  limits:   {cpu: "3", memory: "6Gi", nvidia.com/gpu: "1"}
```

> ⚠️ 改 `70-nvidia-device-plugin.yaml` 里的 ConfigMap 时，**必须同时把 pod 模板的
> `nvidia-device-plugin/config-version` 注解 +1** —— ConfigMap 是文件挂载，
> 改了不重建 pod，而插件只在启动时读一次配置。注解在 pod 模板里，改它会触发滚动更新。

### 装之前是什么状态、为什么

**节点上 `nvidia.com/gpu = 0`** —— k8s 完全不知道有 GPU。清单里写 `nvidia.com/gpu: 1`
会让 Pod **永远 Pending**（`Insufficient nvidia.com/gpu`），所以以前只能不写。

GPU 是靠 **dockerd 的 `default-runtime: nvidia`** 隐式注入 `/dev/dxg` 给**所有**容器的
（k3s 走 `cri-dockerd` → `dockerd`，不是内置 containerd）。**能跑，但 k8s 层完全不知情**：
不能调度、不能计量、不能做准入控制。

没装 device plugin 有两个原因，都不是"装不了"：

| # | 原因 | 修法 |
|---|---|---|
| 1 | **镜像拉不到**：dockerd 的 `HTTPS_PROXY=<proxy-host>:7897`，而 `NO_PROXY` 里没有 `nvcr.io` → 代理对 HEAD 请求返回 `unexpected EOF`（curl 直连是 200） | 把 `nvcr.io` 加进 `/etc/systemd/system/docker.service.d/http-proxy.conf` 的 `NO_PROXY` |
| 2 | **没人注意到缺它** —— 因为 GPU 隐式可用，服务一直正常跑 | 装上后才有 `nvidia.com/gpu` |

> ⚠️ 改 `NO_PROXY` 要 `systemctl restart docker`，而 **k3s 走 cri-dockerd → 所有 pod 会被杀掉**。
> 测试环境可接受（k3s 会自动重建，实测 12 个 pod 全部恢复）。生产环境要挑窗口。

### 为什么能装（前置条件实测都满足）

- k3s 用 cri-dockerd → dockerd，而 dockerd 的 `default-runtime` 已经是 `nvidia`
- `nvidia-container-toolkit` 已装，且**对 WSL 有原生支持**：`nvidia-container-cli list`
  返回的就是 `/dev/dxg` + `/usr/lib/wsl/lib/*`（不是标准 Linux 的 `/dev/nvidia*`）
- **NVML 在 WSL 上可用**：`/usr/lib/wsl/lib/libnvidia-ml.so.1` 能枚举到
  RTX 5060，`UUID=GPU-4058f132-6eda-eec6-98d3-8ef08bde432d`
- 官方镜像**不带 NVML**（依赖宿主）→ 所以挂上 WSL 的 libs 就能让它用对的那份

### 70 号文件里的三个 WSL 适配点

| 配置 | 为什么 |
|---|---|
| 挂 `/dev/dxg` + `/usr/lib/wsl/lib`，`LD_LIBRARY_PATH=/usr/lib/wsl/lib` | 镜像不带 NVML；不加这个它会走标准 ld 路径找到 `/usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1`（CUDA toolkit 带的那份，需要 `/dev/nvidia*`，在 WSL 上不工作） |
| `--fail-on-init-error=false` | 默认 true 会直接退出 → CrashLoopBackOff；WSL 上给它重试的机会 |
| `migStrategy: none` | WSL 没有 MIG，别让插件去探测 |

### ⚠️⚠️ 三条必须记住的边界（别指望它做不到的事）

**① k8s 的 GPU 资源是【整数计数】，不是显存。**

```yaml
nvidia.com/gpu: "1"     # ✅ "我要一整块 GPU"
nvidia.com/gpu: "2Gi"   # ❌ 不存在这种写法
```

**显存切分在 k8s 层做不到** —— 那是 MIG 的活（A100/H100 才有），**RTX 5060 不支持 MIG**。
显存仍然只能靠 vLLM 自己的 `--gpu-memory-utilization` / `--kv-cache-memory` 来分。

**② 在 WSL 上它只是【声明式】的，不是强制隔离。**

dockerd 的 `default-runtime=nvidia` 会给**每个**容器注入 `/dev/dxg` ——
**不申请 `nvidia.com/gpu` 的 Pod 照样能用 GPU**。所以买到的是：

- ✅ 调度准入：k8s 不让超过 N 个 GPU Pod 落地（实测申请 3 个 → Pending）
- ✅ 可见性：`kubectl describe node` 能看到 GPU、谁占了 GPU 一目了然
- ❌ 不是"没申请就用不了"

**③ `timeSlicing.replicas=2` 是管理约定，不是技术限制。**

选 2 是因为物理上就跑两个 GPU 服务，且**显存只剩 ~900 MiB，加第三个会 OOM**。
想加服务时先看显存余量再改这个数 —— 它不是显存配额，只是"允许多少个 Pod 声称要用 GPU"。

### 实测的显存占用（差分测量，因为 WSL 查不到逐进程）

```
两个服务总计   7236 MiB 已用 /  915 MiB 空闲
  vllm-march7  6543 MiB      ← 停掉 embed 后测
  vllm-embed    693 MiB      ← 基线 − march7
```

⚠️ **WSL2 上拿不到逐进程显存**：`nvidia-smi` 能列进程但显存列永远是 `N/A`；
`/proc/<pid>/fdinfo` 没有 dxg 账；cgroup 里没有 GPU 计量。
唯一可靠办法是**差分测量**（停一个测一个）。

### 回滚

```bash
kubectl delete -f k8s/live/70-nvidia-device-plugin.yaml
# 然后从两个 Deployment 里去掉 nvidia.com/gpu（否则 Pod 会 Pending！）
```

---

## ⚠️ 删除资源要手工
`kubectl apply` **不会删除**对象。把文件从这里删掉、commit、跑流水线 —— 集群里
那个对象仍然在。要删得显式来：

```bash
kubectl -n default delete <kind> <name>
```

（想要「删文件即删资源」的语义得上 Argo CD / Flux 那种 GitOps 控制器，
当前这套 apply 型流水线做不到，这是它的固有边界。）

---

## 回滚

```bash
# 改的是 Deployment（args/image/resources）
./ci/scripts/rollback.sh                    # kubectl rollout undo，最快

# 改的是 ConfigMap  ← ⚠️ undo 改不动 CM，必须用这个
./ci/scripts/rollback.sh --from-backup      # 用 precheck 的备份目录还原整个 k8s/live/
```

`precheck.sh` 每次会把整个目录备份到 `logs/ci/live-backup-<时间戳>/`
（逐文件 md5 校验过），`--from-backup` 就是用它还原，并补一次 `rollout restart`。
