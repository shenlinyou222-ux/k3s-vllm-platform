# 01 · 架构

> 目标不是"把 vLLM 跑起来"，而是**让每一次发布都留下可核验的判据**。

---

## 一、组件地图

```
┌─ 开发侧（宿主 / WSL）────────────────────────────────────────────────────┐
│  编辑器改文件 → git commit → git push                                   │
│  （origin = 一个裸仓库；单机自建，没有能发 webhook 的 Git 服务端）          │
└────────────────────────────────┬────────────────────────────────────────┘
                                 │
┌─ CI 控制面（ns: cicd）──────────▼────────────────────────────────────────┐
│  deploy/jenkins            Controller，派生镜像 dsh/jenkins:1.0（86 插件） │
│    · JCasC 脚本化建账号 ops（allowsSignup: false）                        │
│    · 管理员密码从 secret/jenkins-auth 注入（JCasC 里写 ${JENKINS_ADMIN_PASSWORD}）│
│    · Service NodePort 30080(UI) / 30500(agent 隧道)                       │
│    · PVC jenkins-home (10Gi, local-path-retain)                          │
│    · triggers: pollSCM('H/2 * * * *') ← 这就是「git push = 部署指令」      │
│    · 动态 agent：Kubernetes 插件，每 build 一个 pod，用完即删              │
│        模板 label=wsl-docker, runAsUser=0（docker.sock 是 root:docker）    │
│        挂载：docker.sock / 裸仓库 / 模型权重目录                           │
└────────────────────────────────┬────────────────────────────────────────┘
                                 │ 脚本从【SCM 检出】读，不是宿主工作区
┌─ 发布流程（agent pod 内）───────▼────────────────────────────────────────┐
│  ① precheck.sh   ② deploy.sh   ③ verify.sh ×3 层   ④ rollback.sh        │
│  产物（state / 备份 / diff）写到 CI_ARTIFACT_DIR（宿主仓库）              │
│  因为 agent 的 workspace 是 emptyDir，post 的 cleanWs() 会清掉它          │
└────────────────────────────────┬────────────────────────────────────────┘
                                 │ kubectl apply -f k8s/live/
┌─ 数据面（单节点 k3s on WSL2，RTX 5060 8GB sm_120）───────────────────────┐
│                                                                          │
│  ns: default                                                             │
│   ├─ ConfigMap vllm-observability-env     17 个 VLLM_* env（显式钉住）    │
│   ├─ ConfigMap vllm-gencfg-2b            475 条 logit_bias（屏蔽非中文 token）│
│   ├─ ConfigMap vllm-uvicorn-logcfg       uvicorn/vLLM dictConfig         │
│   ├─ StorageClass local-path-retain      Retain：数据不允许丢             │
│   ├─ PV models-pv → /srv/.../npc-models   ★一个 PV 覆盖所有模型           │
│   │   └─ PVC models-pvc (ReadOnlyMany)                                   │
│   ├─ Deployment vllm-march7              生成式 LLM / v1/chat/completions │
│   │   · dsh/vllm-openai-patched:1.1      （+logit_bias 白名单补丁）        │
│   │   · --kv-cache-memory=1Gi + --gpu-memory-utilization=0.55            │
│   │   · Service NodePort 30800 / 30801                                   │
│   ├─ Deployment vllm-embed               向量服务 / v1/embeddings         │
│   │   · --runner=pooling --dtype=float32                                 │
│   │   · --pooler-config={"use_activation":false}                         │
│   │   · Service NodePort 30802                                           │
│   └─ Deployment llama-asr                CPU 语音转写（llama.cpp, GGUF）   │
│       · 不申请 GPU ——「零显存」设计，把卡留给真正需要的模型                 │
│       · Service NodePort 30803                                           │
│                                                                          │
│  ns: monitoring                                                          │
│   ├─ ConfigMap prometheus-config         scrape_interval 5s / 保留 24h    │
│   │   Service NodePort 30090（--web.enable-lifecycle → 支持 /-/reload）   │
│   └─ ConfigMap grafana-dashboard-vllm    4 个 dashboard json              │
│       Service NodePort 30030                                             │
│                                                                          │
│  ns: kube-system                                                         │
│   └─ DaemonSet nvidia-device-plugin      → nvidia.com/gpu 0 → 4          │
│       ★ WSL 适配版（见 docs/04）                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## 二、「唯一事实来源」是 `k8s/live/` 这个**目录**

```bash
kubectl apply -f k8s/live/        # 目录里每个 .yaml 都会被 apply
```

三条推论，都是刻意的：

| 推论 | 好处 |
|---|---|
| 新增资源 = 往目录里丢一个 yaml | **不用改脚本**，不用改 Jenkinsfile |
| `README.md` / `models.lock` 放在同一目录也不会被 apply | kubectl 只挑 `.json/.yaml/.yml`。所以 `models.lock` **故意不带**这两个后缀 —— 否则会被当成 k8s 资源解析 |
| 数字前缀（`10-` `20-` …）只是可读性 | `kubectl apply` 不关心顺序 |

**边界**：`apply` 型流水线**不会删对象**。把 yaml 从目录里删掉 → 集群里那个对象还在，
成了孤儿。想要「删文件即删资源」的语义得上 Argo CD / Flux —— 见
[docs/06](06-limitations.md)。

---

## 三、为什么用「轮询裸仓库」而不是 webhook

事实约束：这是**单机自建**。

- 没有一个能发 webhook 的 Git 服务端（origin 是本地裸仓库）
- 也不想为了 webhook 去装 Generic Webhook Trigger 插件并重建 Controller 镜像

所以：`triggers { pollSCM('H/2 * * * *') }` 轮询 origin，代价是**最多 ~2 分钟延迟**。
本地单机完全够用；要秒级触发就得起 Gitea。

**关键推论：只有 push 上去的东西才会被部署。**
流水线从 **SCM 检出**读（agent 的 workspace），不是读宿主工作区
（`lib.sh` 用 `BASH_SOURCE` 自己定位代码根，所以同一份脚本在检出目录和本地仓库里都对）。

由此还推出一个良性行为：**在 `k8s/live/` 里什么都没改时，`kubectl diff` 为空
→ 直接判「无需发布」→ 绿灯结束，不会白重启服务。**
（用 `exit 2` 而不是 `exit 0` 来区分「无需发布」和「预检通过」，
这样 Jenkinsfile 才能对两者走不同的分支。这个 `2` 曾经被 `sh -xe` 吃成红色失败，
见 [docs/05](05-runbook.md)。）

---

## 四、为什么 Jenkinsfile 里没有判据

**设计原则：Jenkinsfile 不重复实现任何逻辑，只调 `ci/scripts/` 下的脚本。**

三个收益，每条都兑现过：

| 收益 | 兑现 |
|---|---|
| 脚本能手工跑（不依赖 Jenkins） | `pipeline.sh` 就是"本地版 Jenkins" |
| 本地调试和 CI 行为完全一致 | 同一份 `verify.sh` 在两种环境跑同一个判据 |
| **Jenkins 挂了也不影响发布能力** | 直接 `./ci/scripts/pipeline.sh` |

有一处例外是被逼出来的：Jenkinsfile 的 stage 里有几处**内联的 kubectl 调用**
（环境自检、记录结果、post），它们需要一个 shell 变量。为了让「不重复实现逻辑」
这条原则不被破坏，**没有**把 `case` 判断抄进 Jenkinsfile，而是加了一个
`target.sh` 把 profile 暴露出去：

```groovy
eval "$(bash "$WORKSPACE/ci/scripts/target.sh")"
kubectl -n "$NS" get deploy "$DEPLOY" -o wide
```

> ⚠️ 必须用 `bash` 调 —— agent 镜像的 `/bin/sh` 是 busybox ash，**没有 `BASH_SOURCE`**，
> `lib.sh` 定位代码根会失败。

---

## 五、一个集群、两个（三个）服务：`CI_TARGET` profile

```bash
CI_TARGET=march7 ./ci/scripts/pipeline.sh    # 默认，管 vllm-march7
CI_TARGET=embed  ./ci/scripts/pipeline.sh    # 管 vllm-embed
bash ci/scripts/target.sh --print            # 看当前 profile
```

profile 定义在 [`lib.sh`](../ci/scripts/lib.sh) 顶部：

| 变量 | march7 | embed |
|---|---|---|
| `DEPLOY` | `vllm-march7` | `vllm-embed` |
| `CONTAINER` | `vllm` | `vllm` |
| `VERIFY_PY` | `verify-march7.py` | `verify-embed.py` |
| `BENCH_PY` | `bench.py` | `bench-embed.py` |
| `BENCH_UNIT` | `tok/s` | `req/s` |
| `BENCH_MIN_DEFAULT` | **100** | **20** |
| Service / NodePort | `:8001` / `30800 30801` | `:8000` / `30802` |

两条防线：

1. **不传 `CI_TARGET` 时兜底成 `march7`** → 行为与之前完全一致。
   Jenkins 侧由构建参数 `TARGET` 映射；**自动触发（pollSCM）时没有参数**
   → `params.TARGET` 为 null → `CI_TARGET` 为空 → 兜底成 march7。
2. 两个服务用同一个 label 规则（`app = Deployment 名`），所以所有 `-l app=...`
   一律写 `"$POD_SELECTOR"`，不再写死。

> 顺带一个不在 profile 里、但被 `check-models.py` 自动覆盖的：
> `llama-asr` 的 `--model` 写法和 vLLM 不同（llama.cpp 不支持 `--model=PATH`，
> 值是下一行的独立列表项），`check-models.py` 两种写法都解析 —— 否则它
> 完全不在预检管辖内。

---

## 六、为什么把 ConfigMap 也纳入版本控制

`vllm-gencfg-2b` 和 `vllm-uvicorn-logcfg` 最初是**用一次性 `_*.sh` 脚本直接建到集群里**的，
而 `_*.sh` 被 `.gitignore` 排除（仓库策略：只版本化基础设施，不版本化临时脚本）。
后果有两个，都在 2026-10-07 被修掉：

1. **从 main 重建集群 → pod 起不来**（Deployment 挂载的 CM 不存在）
2. **`kubectl diff` 看不见它们的漂移** —— 屏蔽词被谁改了、改了什么，预检一无所知

`20-vllm-gencfg-2b.yaml` 是把集群里那份 JSON **美化后**存进来的
（原来是一整行 8273 字节，diff 完全没法看）。值、键、键序逐项核对过 deep-equal，
唯一变化是空白。

**这个坑后来第二次踩**：`prometheus-config` 和 `grafana-dashboard-vllm` 也是
一次性脚本建的，没进仓库 → 里面的抓取目标早就烂了（指向两个已不存在的服务）
→ 跑了两天的 `vllm-march7` 和刚上线的 `vllm-embed` **一条指标都没被采集**，
Grafana 上曲线一直是空的。2026-10-08 导出并纳管。

> 教训：**「不在仓库里」= 「漂移无人知」**。这份文档目录下每个 CM 的头部注释里
> 都写了「改了之后要做什么」—— 因为不同 CM 的生效方式不一样：
> - vLLM 的 CM：`deploy.sh` 检测到「CM 变了但 DE 没变」→ 自动补 `rollout restart`
> - Prometheus 的 CM：**必须手动 `curl -X POST .../-/reload`**（它不属于任何 Deployment）
> - Grafana 的 CM：file provider 的 `updateIntervalSeconds: 10` 会自己重载
> - device plugin 的 CM：**必须同时把 pod 模板的 `config-version` 注解 +1**（见 docs/04）
