# ci/scripts —— 发布流水线

> 这套脚本既是**手工发布工具**，也是 **Jenkins 流水线的本体**。
> Jenkinsfile 不重复实现任何逻辑，只调这里的脚本 —— 所以本地调试和 CI 行为完全一致。

---

## 一、你的工作流（Trae 改 → WSL 脚本）

```
① Trae 里改文件 → Ctrl+S 保存
        ↓
② WSL 里：git add -A && git commit -m "..."
        ↓
③ ./ci/scripts/pipeline.sh          ← 预检 → 发布 → 验证（失败自动回滚）
        ↓
   或分开跑（推荐第一次这样做，看得清楚）：
      ./ci/scripts/precheck.sh       ← 看 diff，人工确认
      ./ci/scripts/deploy.sh
      ./ci/scripts/verify.sh
```

### ⚠️ 第一步永远是 commit

**Jenkins 里**：流水线从 **SCM 检出**读（agent 的 workspace），部署的就是你推上去的那一版
—— 没提交的东西根本进不了检出，所以这里不需要额外检查。

**本地手工跑**：`$REPO` 是仓库根，`precheck.sh` 会检查工作区是否干净，**没提交就拒绝继续**
（可以用 `CI_ALLOW_DIRTY=1` 强制，但不建议）。原因：没有 commit 就没有"这次改了哪些文件"
的准确记录，出问题无法精确定位。

> 脚本靠 `BASH_SOURCE` 自己定位代码根（见 `lib.sh`），所以同一份脚本在
> Jenkins 检出目录和本地仓库里都对。产物（state / 备份 / diff）则固定写到
> `CI_ARTIFACT_DIR`（Jenkins 传宿主路径，本地默认 `$REPO/logs/ci`）——
> 因为 agent 的 workspace 用完就被 `cleanWs()` 清掉，回滚要用的 state 不能放那儿。

---

## 二、六条脚本，各管什么

| 脚本 | 做什么 | 什么时候用 |
|---|---|---|
| **`precheck.sh`** | git 检查 → **可验证备份** → dry-run → **diff** → 快照 | ⭐ **每次发布前必跑** |
| **`deploy.sh`** | apply → 等 rollout → 记录前后状态 | 预检通过后 |
| **`verify.sh`** | 日志层 + 功能层 + 性能层，三层判据 | 发布后 |
| **`rollback.sh`** | rollout undo / 从备份还原 | 验证失败时 |
| **`restart.sh`** | 只重启 pod | **改了 ConfigMap 时**（见下） |
| **`pipeline.sh`** | 一键串联上面全部 | 熟练之后 |

### 辅助脚本

| 脚本 | 作用 |
|---|---|
| `verify-march7.py` | 功能验证（march7）：三月七 prompt + 英文诱导 + 乱码检查 |
| `bench.py` | 性能基准（march7）：预热 3 次 + 正式 10 次，判据 tok/s |
| **`verify-embed.py`** | 功能验证（embed）：服务端向量逐条比对本地 HF 参考向量 cos ≥ 0.999 |
| **`bench-embed.py`** | 性能基准（embed）：预热 3 次 + 正式 20 次，判据 req/s |
| **`embed_reference.json`** | embed 的参考向量（由一次性脚本 `_gen_embed_ref.py` 生成） |
| **`target.sh`** | 把 `CI_TARGET` 的 profile 暴露给 Jenkinsfile 里的内联 kubectl 调用 |
| `endpoint.py` | 按 `CI_TARGET` 探测端点（Service → NodePort），两个服务共用 |
| `lib.sh` | 公共库（日志 / 判据 / 状态 / 人工确认 / **target profile**） |

---

## ⭐ 三、`CI_TARGET`：一个集群里两个服务

2026-10-08 起集群里有两个 vLLM 服务，所有脚本按 `CI_TARGET` 分派：

| `CI_TARGET` | Deployment | 功能验证 | 性能判据 |
|---|---|---|---|
| `march7`（默认） | `vllm-march7` | `verify-march7.py` | **tok/s ≥ 100** |
| `embed` | `vllm-embed` | `verify-embed.py` | **req/s ≥ 20** |

```bash
CI_TARGET=embed ./ci/scripts/pipeline.sh          # 发向量服务
CI_TARGET=embed ./ci/scripts/verify.sh            # 只验证
CI_TARGET=embed ./ci/scripts/rollback.sh          # 回滚向量服务
bash ci/scripts/target.sh --print                 # 看当前 profile

./ci/scripts/verify.sh --layer=log                # 只跑日志层
./ci/scripts/verify.sh --layer=func               # 只跑功能层
./ci/scripts/verify.sh --layer=bench              # 只跑性能层
```

profile 定义在 `lib.sh` 顶部（`DEPLOY` / `CONTAINER` / `VERIFY_PY` / `BENCH_PY` /
`BENCH_UNIT` / `BENCH_MIN_DEFAULT` / `POD_SELECTOR`）。**不传 `CI_TARGET` 时行为与
以前完全一致**（走 march7）。Jenkins 侧由构建参数 `TARGET` 映射成 `CI_TARGET`。

`--layer` 让 Jenkinsfile 的 ④⑤⑥ 三个阶段共用同一份判据逻辑
（Jenkinsfile 不重复实现任何判据 —— 这是本套流水线的设计原则）。

---

## 三、⭐ 关键区分：改了什么，就用哪条路

| 你改了什么 | 走哪条路 | 为什么 |
|---|---|---|
| **`k8s/live/` 里的 Deployment**（args / image / resources） | `pipeline.sh` | apply 改 spec → k8s 自动重建 pod |
| **`k8s/live/` 里的任意 ConfigMap** | `pipeline.sh`（`MODE=full` 一次就够） | ⭐ `deploy.sh` 检测到「CM 变了但 DE 没变」会**自动补一次重启** |
| **Service / PVC / PV / StorageClass** | `pipeline.sh` | apply 立即生效，不涉及 pod |
| **源码**（`proxy_mongo.py` 等） | 先构建镜像，再 `pipeline.sh` | 镜像变了才有意义 |
| **只想知道改对了没** | `pipeline.sh --dry` | 只跑预检，不动线上 |

**⚠️ 2026-10-07 修掉的一个坑**：以前「改 ConfigMap → `kubectl apply`」是**假成功** ——
CM 更新了，但 vLLM 只在启动时读一次配置，pod 不重建就还跑着旧值，而流水线照样全绿。
现在 `deploy.sh` 会在 apply 前后比对 Deployment 引用到的每个 ConfigMap 的
`resourceVersion`，变了就自动重启，日志里明说。所以**改什么都只需要 `MODE=full` 一次**。

---

## 四、常用命令

```bash
cd /srv/k3s-vllm-platform

# ── 完整流程（推荐第一次分开跑）──
git add -A && git commit -m "改了什么"
./ci/scripts/precheck.sh        # 看 diff，确认
./ci/scripts/deploy.sh
./ci/scripts/verify.sh

# ── 一键（熟练后）──
./ci/scripts/pipeline.sh

# ── 只改了 ConfigMap ──
./ci/scripts/pipeline.sh --restart-only

# ── 只预检，不动线上 ──
./ci/scripts/pipeline.sh --dry

# ── 无人值守（跳过人工确认）──
CI_YES=1 ./ci/scripts/pipeline.sh

# ── 回滚 ──
./ci/scripts/rollback.sh                    # 回上一版
./ci/scripts/rollback.sh --from-backup      # 用 precheck 的备份还原
./ci/scripts/rollback.sh --to-revision=5    # 回到指定 revision

# ── 提高性能门槛 ──
BENCH_MIN=120 ./ci/scripts/verify.sh
```

---

## 五、三层验证判据（`verify.sh`）

```
── CI_TARGET=march7（生成式 LLM）──
① 日志层
   · 有 "Using V2 Model Runner"        ← 没回退到 V1
   · 有 "overridden by /gencfg"        ← 掩码生效
   · 无 error / traceback

② 功能层（verify-march7.py）
   · 端点可达
   · 中文正常（≥5 汉字，无 \ufffd 乱码）
   · 英文被挡（剥离思考标记后无 ASCII 字母）

③ 性能层（bench.py）
   · 稳态吞吐 ≥ BENCH_MIN（默认 100 tok/s）

── CI_TARGET=embed（向量服务）──
① 日志层
   · 有 "Application startup complete"  ← 服务起来了
   · 有 "Resolved pooling config: pooling_type=CLS"      ← 池化方式对
   · 该行里 use_activation=False                          ← 没被 L2 归一化
   · 该行里 supported_tasks 含 embed                      ← --runner=pooling 生效
   · 无 error / traceback

② 功能层（verify-embed.py）
   · 8 条文本的服务端向量 vs 本地 HF 参考向量，cos ≥ 0.999
   · 语义序：sim(把模型删掉, 删除模型文件) > sim(把模型删掉, 今天天气不错)

③ 性能层（bench-embed.py）
   · 稳态 ≥ BENCH_MIN（默认 20 req/s）
```

**任一层失败 → 退出码非 0 → `pipeline.sh` 自动回滚。**

> ⭐ embed 的 ① 不是摆设：vLLM 服务 BERT 时有三个旋钮（`pooling_type` /
> `use_activation` / `dtype`），**配错任何一个都照样返回形状正确的向量，但语义是错的**。
> ① 在日志层卡住，② 用逐条向量比对做最终裁决。详见 `k8s/live/README.md`。


---

## 六、目录结构

```
ci/
├── Jenkinsfile         # 声明式流水线（只编排，不实现判据）
├── agent/
│   └── Dockerfile      # Jenkins Agent 镜像
└── scripts/
    ├── lib.sh              # 公共库（含 LIVE_DIR = k8s/live/ 与 target profile）
    ├── precheck.sh         # ① 预检（备份整个 live 目录 + dry-run + diff）
    ├── deploy.sh           # ② 发布（apply 目录 + ⭐ CM 变了自动重启）
    ├── verify.sh           # ③ 验证（三层，--layer 可选）
    ├── rollback.sh         # ④ 回滚（undo / --from-backup）
    ├── restart.sh          # 只重启（ConfigMap 类改动）
    ├── pipeline.sh         # 一键串联（本地版 Jenkins）
    ├── target.sh           # 把 CI_TARGET 的 profile 暴露给 Jenkinsfile
    ├── endpoint.py         # 端点探测（$VLLM_URL → Service → NodePort）
    ├── verify-march7.py    # 功能验证（生成式 LLM）
    ├── bench.py            # 性能基准（生成式 LLM，tok/s）
    ├── verify-embed.py     # 功能验证（向量服务，逐条 cos 比对）
    ├── bench-embed.py      # 性能基准（向量服务，req/s）
    ├── embed_reference.json# 向量参考数据
    └── check-models.py     # 模型权重 sha256 指纹校验

k8s/live/               # ⭐ 线上资源的唯一事实来源（目录里每个 yaml 都会被 apply）
├── README.md           # 怎么改 / 怎么发 / 回滚（kubectl 会忽略非 yaml）
├── 10-vllm-mongo.yaml          # vLLM 主体 + Service + PV/PVC + StorageClass
├── 20-vllm-gencfg-2b.yaml      # 服务端默认采样参数（475 条 logit_bias）
├── 30-vllm-uvicorn-logcfg.yaml # 日志 dictConfig
├── 40-vllm-embed.yaml          # 向量服务
├── 50-prometheus-config.yaml   # Prometheus 抓取配置
├── 60-grafana-dashboards.yaml  # 4 个 Grafana 仪表盘
├── 70-nvidia-device-plugin.yaml# NVIDIA device plugin（WSL 适配版）
├── 80-llama-asr.yaml           # CPU 语音转写
└── models.lock                 # 模型权重指纹（故意不带 .yaml 后缀）

logs/ci/                # 产物目录（Jenkins 里是宿主路径，见 CI_ARTIFACT_DIR）
├── state/              # 状态文件（供回滚读取）
│   ├── precheck_backup     ← precheck 的备份【目录】
│   ├── precheck_snapshot   ← 发布前快照
│   ├── deploy_was_new      ← 本次是不是新建（决定回滚用 delete 还是 undo）
│   ├── deploy_pre_image    ← 发布前镜像
│   ├── deploy_restarted    ← 本次是否补了重启（1/0）
│   └── deploy_post_image   ← 发布后镜像
├── live-backup-*/          ← k8s/live/ 的整目录备份（逐文件 md5 校验）
├── diff-*.txt              ← kubectl diff 输出
├── dryrun-*.txt            ← dry-run 输出
├── snapshot-*.json         ← 线上状态快照
├── cm-*-*.yaml             ← ConfigMap 快照
└── bench-*.txt             ← 性能基准结果（本仓库只搬了这些，见 benchmarks/）
```

---

## 七、设计原则（每条都来自 2026-10-06 那次实战）

| 原则 | 为什么 |
|---|---|
| **失败即停**（`set -euo pipefail`） | "看起来成功了"是最危险的 |
| **每步有判据** | 判据不通过就 `die`，不往下走 |
| **备份必须 md5 可验证** | 大小相同 ≠ 内容相同 |
| **diff 必须人工确认** | ⭐ 曾靠它抓到误改的 `--max-num-seqs=64 → 2048` |
| **状态落盘** | 没有状态就没法精确回滚 |
| **绝对路径** | 相对路径在 Jenkins Agent 里会失效 |
| **脚本即流水线** | Jenkins 挂了也不影响发布能力 |

---

## 八、Jenkins 上线后的差异

| | 手工（现在） | Jenkins |
|---|---|---|
| 触发 | 手动敲命令 | git push / 点按钮 |
| 环境 | 你的 WSL shell | Agent 容器（同样的脚本） |
| 日志 | 终端 | Jenkins UI 保留 30 次 |
| 确认 | `confirm` 交互 | `CI_YES=1` 跳过 |
| 回滚 | 手动跑 | `post.failure` 自动 |

**⇒ 脚本不变，只是换个地方调。** 这就是"先写脚本再上 Jenkins"的意义。

---

## 九、故障速查

| 症状 | 原因 | 处理 |
|---|---|---|
| `请先提交` | 工作区脏 | `git add -A && git commit` |
| `没有差异 —— 无需发布`（退出 2） | Deployment 没变 | 改的是 ConfigMap？用 `--restart-only` |
| `rollout 超时` | 2B 启动要 3-5 分钟 | 等；或看 `kubectl describe pod` |
| `不是 V2 runner` | 用了自定义 logits processor | 检查有没有 `--logits-processors` |
| `掩码没生效` | `_from_model_config` 丢了 logit_bias | 见下 |
| `性能不达标` | GPU 被占 / 模型不对 | `nvidia-smi` 看显存 |
| **`没找到 'Using V2 Model Runner'` 但 grep 明明有** | ⭐ **`echo \| grep -q` + `set -o pipefail` 的 SIGPIPE 陷阱** | 见下 |
| embed: `pooling_type 不是 CLS` | 换了非 BERT 系模型（E5 是 MEAN） | 显式传 `--pooler-config={"pooling_type":"CLS"}` |
| embed: `use_activation 不是 False` | `--pooler-config` 没写或写错 | 补上 `use_activation:false` |

### ⚠️⚠️ `echo "$X" | grep -q PATTERN` 在 `set -o pipefail` 下会误判

**症状**：日志里明明有 `Using V2 Model Runner`，`verify.sh` 却报「没找到」。

**根因**：
```
lib.sh 里有 set -o pipefail
grep -q 命中后会【立刻退出】并关掉管道
→ 还在写的 echo 收到 SIGPIPE（退出码 141）
→ pipefail 把整条管道判成【失败】
⇒ 命中了反而走 else 分支
```

**为什么潜伏这么久**：短日志（几十行）时 `echo` 能在 `grep` 退出前写完，不触发。
Jenkins 里每次验证的都是**刚重启的新 pod**（日志短）→ 从不触发。
2026-10-08 拿一个跑了 13h、日志 5495 行的 pod 测才暴露出来。

**最危险的是「无错误」那条判据**：日志里**真有 error** 时会被管道误判成失败 →
走 else → 报「✅ 日志无 error」——**假阴性**，方向最危险。

**正确写法**（here-string 没有上游进程，不存在 SIGPIPE）：
```bash
grep -q PATTERN <<< "$LOGS"        # ✅
echo "$LOGS" | grep -q PATTERN     # ❌
```


### ⚠️ 掩码没生效的头号原因

`/gencfg/generation_config.json` 里**不能有 `_from_model_config`** —— 它会让 HF 从模型 config 重建，**静默丢掉 `logit_bias`**。

```json
// ✅ 正确
{"eos_token_id": 54793, "logit_bias": {...}}

// ❌ 错误（logit_bias 会被丢掉）
{"_from_model_config": true, "eos_token_id": 54793, "logit_bias": {...}}
```

**验证方法**：
```bash
kubectl logs deploy/vllm-march7 -c vllm | grep -o "overridden by /gencfg: .\{0,40\}"
# 应该看到 {'logit_bias': {...}}
```
