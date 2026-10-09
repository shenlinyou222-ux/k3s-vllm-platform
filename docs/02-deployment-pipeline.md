# 02 · 发布流水线 ⭐

> `precheck` → `deploy` → `verify` → `rollback`
> 四个阶段，每个阶段都有**可执行判据**，判据不过就 `die`，不往下走。

设计原则（每条都来自一次实战）：

| 原则 | 为什么 |
|---|---|
| **失败即停**（`set -euo pipefail`） | "看起来成功了"是最危险的 |
| **每步有判据** | 判据不通过就停，不带着未知状态往下走 |
| **备份必须 md5 可验证** | 大小相同 ≠ 内容相同 |
| **diff 必须人工确认** | ⭐ 曾靠它抓到误改的 `--max-num-seqs=64 → 2048` |
| **状态落盘** | 没有状态就没法精确回滚 |
| **绝对路径** | 相对路径在 Jenkins Agent 里会失效 |
| **脚本即流水线** | Jenkins 挂了也不影响发布能力 |

---

## ① `precheck.sh` —— 预检（每次发布前必跑）

五件事：

```
1. git 工作区干净          require_clean_git
2. ⭐ 模型权重校验          check-models.py
3. 备份整个 k8s/live/      逐文件 md5 校验
4. 服务端校验              kubectl apply --dry-run=server
5. kubectl diff + 快照     → 人工确认
```

### 为什么必须有第 2 步：`kubectl diff` 只看得见「清单里写了什么」

**看不见「路径背后是什么」。** 所以有两种情况原本完全无感：

| 情况 | 不校验的后果 |
|---|---|
| `--model=` 指向**不存在的路径** | vLLM 加载失败 → `rollout status` 要等满 **900s** 才判失败 → 而这期间（`strategy: Recreate`）**服务完全 DOWN** → 才回滚。**最坏约 18 分钟中断。** |
| 模型目录里的权重被**就地替换**（路径没变） | `kubectl diff` 为空 → 判「无需发布」→ **而 vLLM 还跑着旧权重** |

`check-models.py` 把这两件事都提前到**秒级**暴露：

- 从 `k8s/live/*.yaml` 里解析 Deployment 声明的 `--model=` / `--served-model-name`
- 检查宿主模型目录存在、必需文件齐全（HF 格式要 `config.json`；GGUF 格式的"配置"在文件头里，
  所以有 `.gguf` 就不要求 `config.json`）
- 与 `k8s/live/models.lock` 里的 **sha256 指纹**比对

指纹覆盖 **6 个文件**（`config.json` / 权重 / `tokenizer.json` /
`generation_config.json` / `chat_template.jinja` / `output_banned_ids.pt`），
全量 sha256 **约 4.4 秒**。

```bash
python3 ci/scripts/check-models.py            # 校验（precheck.sh 会调它）
python3 ci/scripts/check-models.py --list     # 看声明了哪些模型 + 宿主路径
python3 ci/scripts/check-models.py --write    # 更新指纹（★合并式，不会丢别的模型）
python3 ci/scripts/check-models.py --write --prune   # 只留当前声明的模型
CI_SKIP_MODEL_CHECK=1 ...                     # 逃生口（不推荐）
```

> `--write` 是**合并**式的理由：换模型是高频操作。
> · 首次用某模型 → 改 `--model=` + `--write` 记下它
> · 以后换回来 → **只改 `--model=` 就行**，不用再 `--write`
> · 而且如果那个模型的权重在你不用它期间被改过，换回去时预检会报
>   「内容变了」→ 提醒你重新 `--write`

### 退出码约定

| 退出码 | 含义 |
|---|---|
| `0` | 预检通过，可以发布 |
| `2` | **没有差异 —— 无需发布**（线上已是最新） |
| 其他 | 预检失败 |

> ⭐ 用 `2` 而不是 `0`，是为了让 `pipeline.sh` / Jenkinsfile 能区分
> 「无需发布」和「预检通过」。这个约定曾经在 Jenkins 里被吃掉一次 ——
> Jenkins 的 `sh` 步骤默认以 `sh -xe` 跑，`-e` 让 `exit 2` 当场判失败，
> 后面的 `echo "RC=$?"` 根本执行不到 → 明明该走「无需发布」的正常路径，
> UI 上却是红叉（**构建 #7** 就是死在这里）。
> 修法：`set +e; bash precheck.sh; echo "RC=$?"`。

还有一个配套的坑：`returnStdout: true` 会把 precheck 的 stdout **全部捕获走**，
不显式 `echo` 出来的话，构建日志里只剩一句「预检退出码 = N」——
**diff 内容、模型权重校验、备份路径一个都看不见**。

### 备份必须可验证

```bash
cp -a "$LIVE_DIR"/. "$BAK"/
for f in $(live_files); do
  [ "$(md5sum "$f" | cut -d' ' -f1)" = "$(md5sum "$BAK/$(basename $f)" | cut -d' ' -f1)" ] \
    || die "备份校验失败"
done
[ "$NF" -gt 0 ] || die "$LIVE_DIR 里没有 .yaml（是不是目录搞错了？）"
```

最后那个 `-gt 0` 不是多余的：目录搞错会导致「备份成功，但一个文件都没备」。

---

## ② `deploy.sh` —— 发布 ⭐⭐ 本节是整套系统的核心

四件事：

```
1. kubectl apply -f k8s/live/（整个目录）
2. ⭐ CM 变了但 DE 没变 → 自动补一次 rollout restart
3. kubectl rollout status --timeout=900s
4. 记录发布后状态（供回滚对比）
```

### 第 2 步：堵住「假成功」

**k8s 不会因为 ConfigMap 变了就重建 pod**（pod 模板上也没有 checksum 注解），
而 **vLLM 只在启动时读一次配置**。

所以「改 CM → apply」在旧逻辑下的真实后果是：

```
改 CM → apply 更新了 CM → Deployment 没变 → 不重启 → vLLM 还读着旧配置
      → 阶段④⑤⑥ 验证跑在【旧配置的 pod】上 → 全绿
      ⇒ 构建成功，但改动根本没生效（"假成功"）
```

**这不是推测**，三条都实测确认过：pod 模板的 annotations 只有
`kubectl.kubernetes.io/restartedAt`；`vllm-observability-env` 只通过 `envFrom` 消费；
`gencfg` / `logcfg` 是启动时读的文件挂载。

**解法**（[`deploy.sh:104-139`](../ci/scripts/deploy.sh#L104-L139)）：
在 apply **前后**比对 Deployment 引用到的每个 ConfigMap 的 `resourceVersion`：

```bash
# 收集 DE 引用到的 CM（envFrom + volumes）
refd_cms() { kubectl get deploy "$DEPLOY" -n "$NS" -o json | python3 -c '...' ; }
cm_rv()    { kubectl get cm "$1" -n "$NS" -o jsonpath='{.metadata.resourceVersion}'; }

# apply 前记下来 → apply → 再读一遍 → 比对
POST_GEN=$(kubectl get deploy "$DEPLOY" -o jsonpath='{.metadata.generation}')

if [ "$POST_GEN" != "$PRE_GEN" ]; then
  ok  "generation: $PRE_GEN → $POST_GEN（spec 变了，k8s 会自动重建 pod）"
elif [ -n "$CHANGED" ]; then
  warn "Deployment 的 spec 没变（generation 仍为 $PRE_GEN），但它引用的 ConfigMap 变了:$CHANGED"
  info "vLLM 只在启动时读一次配置 → 自动补一次 rollout restart"
  info "（少了这一步就是【假成功】：CM 更新了、pod 却还跑着旧配置，而验证照样全绿）"
  kubectl rollout restart deploy/"$DEPLOY"
else
  warn "generation 没变，引用的 ConfigMap 也没变"
  info "本次差异只涉及非 Pod 资源（Service / PVC / PV / StorageClass）→ 已 apply，不需要重启"
fi
```

**⇒ 改任何东西都只需要 `MODE=full` 一次。**

改了哪一类 → 会发生什么：

| 你改的东西 | apply 之后 | 要不要第二次操作 |
|---|---|---|
| Deployment 的 args / image / resources / 探针 / 端口 | generation +1 → k8s 自动重建 pod | 不用 |
| **ConfigMap**（20 / 30 号文件，以及 10 号里的 `vllm-observability-env`） | apply 只更新 CM，spec 没变 | ⭐ **不用** —— 上面那一步补重启 |
| Service / PVC / PV / StorageClass | apply 立即生效，不涉及 pod | 不用 |

> ⚠️ **这个逻辑只认「目标 Deployment 引用的 CM」。**
> `prometheus-config` / `grafana-dashboard-vllm` 不属于 `vllm-march7`/`vllm-embed`
> 任何一方 → **不会被自动处理**；device plugin 的 CM 同理。
> 这三份 CM 各自的生效方式见 [docs/01 第六节](01-architecture.md)。

### 第 3 步：等就绪

`rollout status --timeout=900s`。2B 模型启动要 **3-5 分钟**，超时给足。

超时后的动作不是静默重试，而是**打印诊断信息 + `die`**：

```bash
if ! kubectl rollout status deploy/"$DEPLOY" -n "$NS" --timeout=900s; then
  fail "rollout 超时/失败"
  kubectl get pods -l "$POD_SELECTOR" -n "$NS"
  kubectl describe pod -l "$POD_SELECTOR" -n "$NS" | tail -30
  die "请执行 ./ci/scripts/rollback.sh 回滚"
fi
```

### 两个「不存在/缩容」的边界（都实测踩过）

**（a）目标是新建的 Deployment** → `kubectl get` 返回 NotFound，而 `lib.sh` 有 `set -e`
→ 脚本当场死掉，**连 apply 都走不到**：

```
Error from server (NotFound): deployments.apps "vllm-embed" not found
→ ③ 发布阶段 FAILURE → 后面 ④⑤⑥⑦ 全被 skip
```
（2026-10-08 **构建 #24**，新增 `vllm-embed` 时）

修法：三处 `kubectl get` 都加 `2>/dev/null || true`，并把「是不是新建」记进 state
供回滚用（`deploy_was_new`）。

**（b）删减资源** rollback 相关 —— 见下面 ④。

---

## ③ `verify.sh` —— 三层判据

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
③ 性能层（bench.py：预热 3 次 + 正式 10 次）
   · 稳态吞吐 ≥ BENCH_MIN（默认 100 tok/s）

── CI_TARGET=embed（向量服务）──
① 日志层
   · 有 "Application startup complete"
   · "Resolved pooling config: pooling_type=CLS"   ← 池化方式对
   · 该行里 use_activation=False                    ← 没被 L2 归一化
   · 该行里 supported_tasks 含 embed                ← --runner=pooling 生效
   · 无 error / traceback
② 功能层（verify-embed.py）
   · 8 条文本的服务端向量 vs 本地 HF 参考向量，cos ≥ 0.999
   · 语义序：sim(把模型删掉, 删除模型文件) > sim(把模型删掉, 今天天气不错)
③ 性能层（bench-embed.py：预热 3 次 + 正式 20 次）
   · 稳态 ≥ BENCH_MIN（默认 20 req/s）
```

**任一层失败 → 退出码非 0 → `pipeline.sh` / Jenkinsfile 自动回滚。**

### ⭐ 为什么 embedding 的判据不能是「返回了 768 维向量」

vLLM 服务 BERT 时有**三个旋钮，配错任何一个都照样返回形状正确的向量，但语义是错的**：

| 旋钮 | 正确值 | 配错的后果 |
|---|---|---|
| `pooling_type` | `CLS` | 换成 MEAN/LAST → 向量含义完全不同 |
| `use_activation` | `False` | 默认 True 会把向量 L2 归一化到 1.0，与读出头训练时的分布不符 |
| `dtype` | `float32` | bf16 会有数值漂移 |

所以唯一的可靠判据是**逐条向量比对**：拿本地 HF 模型在 fp32 下算出的参考向量
（`embed_reference.json`，由一次性脚本 `_gen_embed_ref.py` 生成）跟服务端返回的比 cos。

**实测（2026-10-08）：8 条全部 cos = 1.000000**，L2 范数也逐条对上。

①（日志层）不是摆设：它把这**三个旋钮一次全暴露在日志里** ——

```
Resolved pooling config: pooling_type=CLS(source=sentence_transformers),
  tok_pooling_type=ALL(source=model_default),
  use_activation=False(source=user), supported_tasks=('embed', 'token_embed')
```

配错的后果是「照样返回 768 维向量、但语义错」→ **下游读出头全崩**，
所以要在日志层就卡住，而不是等人工发现。

### `--layer` 参数

```bash
./ci/scripts/verify.sh --layer=log      # 只跑日志层
./ci/scripts/verify.sh --layer=func     # 只跑功能层
./ci/scripts/verify.sh --layer=bench    # 只跑性能层
```

让 Jenkinsfile 的 ④⑤⑥ 三个阶段**共用同一份判据逻辑** ——
Jenkinsfile 不重复实现任何判据，这是本套流水线的设计原则。

### ⭐⭐ SIGPIPE 假阴性：`echo | grep -q` + `set -o pipefail`

这是最隐蔽的一个坑，值得单独讲（见 [`verify.sh:28-39`](../ci/scripts/verify.sh#L28-L39)
和 [docs/05](05-runbook.md)）。

```bash
grep -q PATTERN <<< "$LOGS"        # ✅ here-string：没有上游进程，不存在 SIGPIPE
echo "$LOGS" | grep -q PATTERN     # ❌ pipefail 下会误判
```

**根因**：`grep -q` 命中后**立刻退出**并关掉管道 → 还在写的 `echo` 收到
**SIGPIPE（退出码 141）** → `pipefail` 把整条管道判成**失败** → **命中了反而走 else 分支**。

**为什么潜伏这么久**：短日志（几十行）时 `echo` 能在 `grep` 退出前写完，不触发。
Jenkins 里每次验证的都是**刚重启的新 pod**（日志短）→ 从不触发。
2026-10-08 拿一个跑了 13h、日志 **5495 行**的 pod 测才暴露出来。

**最危险的是「无错误」那条判据**：日志里**真有 error** 时会被管道误判成失败 →
走 else → 报「✅ 日志无 error」—— **假阴性，方向最危险。**

### 缩放到 0 时跳过验证（不是失败）

```bash
if [ "$(kubectl get deploy "$DEPLOY" -n "$NS" -o jsonpath='{.spec.replicas}')" = "0" ]; then
  warn "deploy/$DEPLOY 的 replicas=0（已缩容，不提供服务）→ 跳过验证"
  exit 0
fi
```

2026-10-08 加：march7 为了把 GPU 让给别的模型被缩到 `replicas=0`。这时候：
没有 pod → `kubectl logs` 拿不到 → 日志层会 `die`；服务不响应 → 功能层必然失败；
没有请求 → 性能层必然失败。**但这不是"发布失败"，是刻意的缩容。**

> ⚠️ **跳过验证 ≠ 没发布**：apply 仍然执行了（副本数确实被改成 0），只是没东西可验证。

---

## ④ `rollback.sh` —— 回滚

三种模式，**选错模式 = 回滚不生效**：

| 模式 | 命令 | 覆盖什么 |
|---|---|---|
| **delete-new** | 自动（state 里 `deploy_was_new=1`） | 本次是**新建**的 → "回滚" = 删掉 Deployment + Service |
| **undo**（默认） | `rollback.sh` / `--to-revision=N` | `kubectl rollout undo`，**只回滚 Deployment** |
| **backup** | `rollback.sh --from-backup` | 用 precheck 的备份目录把**整个 live 目录**还原到发布前 |

### 为什么 `undo` 不够：它管不了 ConfigMap

```bash
# ⭐⭐ rollout undo 只回滚 Deployment —— ConfigMap 它管不了。
#     所以先把备份里的 ConfigMap 还原回去（不重启），再 undo；
#     这样 undo 触发的那一次 pod 重建就会带上【旧配置】。
#     少了这一步，"回滚"之后的 pod 会带着【新配置】重新起来 —— 等于没回滚。
for f in "$BAK"/*.yaml; do
  grep -q '^kind: ConfigMap' "$f" || continue
  out=$(kubectl apply -f "$f")
  if grep -q 'unchanged' <<< "$out"; then ... else CM_RESTORED=$((CM_RESTORED+1)); fi
done
```

> 注意这里也是 **here-string 而不是管道** —— 同一个 SIGPIPE 陷阱。

### 为什么「新建」不能 undo

`rollout undo` 对新建的 Deployment 无意义（没有上一版 revision，实测报
`no rollout history`）。发布前它并不存在，所以**正确的回滚是删除**：

```bash
kubectl -n "$NS" delete deploy "$DEPLOY" --ignore-not-found
kubectl -n "$NS" delete svc    "$DEPLOY" --ignore-not-found
```

### `--from-backup` 只改集群，不动仓库

```bash
kubectl apply -f "$BAK"        # 直接 apply 备份目录
kubectl rollout restart deploy/"$DEPLOY"   # apply 不会重启 pod，必须显式 restart
```

⚠️ 它**不往 `$LIVE_DIR` 里抄**：在 Jenkins 里 `$LIVE_DIR` 是 agent 的临时检出
（emptyDir），抄进去只会被 `cleanWs()` 清掉，还会造成「文件已经回退了」的错觉
—— **其实仓库一点没变**。要让仓库里的 `k8s/live/` 也回退，得 `git revert` 那个 commit。

---

## ⑤ 自动回滚：什么时候**不该**回滚

```groovy
post {
    failure {
        script {
            // ⭐⭐ 只有【部署真正开始过】才回滚
            //     阶段①②失败就回滚 = 把一个没改过的 Deployment 滚回去
            //     —— 实测把正在服务的 vLLM 重启了，纯属自伤
            if (env.DEPLOY_STARTED == 'true') {
                sh 'bash "$WORKSPACE/ci/scripts/rollback.sh" || echo "回滚也失败 —— 需要人工介入！"'
            } else {
                echo "❌ 失败发生在【部署之前】→ 不回滚（线上没被改动）"
            }
        }
    }
    cleanup { cleanWs() }     // ⚠️ 必须在 cleanup，不能在 always
}
```

**`cleanWs()` 的位置是个真踩过的坑**：declarative pipeline 的 post 条件执行顺序是
`always → changed/fixed/regression/aborted/failure/success/... → cleanup`，
也就是 **`always` 比 `failure` 先跑**。把 `cleanWs()` 放在 `always` 里，失败时工作区
已经被删掉，`failure` 里的 rollback 根本找不到脚本：

```
+ bash .../ci/scripts/rollback.sh
bash: .../rollback.sh: No such file or directory
+ echo '回滚也失败 —— 需要人工介入！'
```

实测于 2026-10-08 **构建 #24** —— 也就是说「失败自动回滚」这个功能
**在此之前从来没有真正生效过**（一直没失败过所以没暴露）。

### 无必要回滚的一次实例（构建 #33）

`lib.sh` 的 `set -e` + `kubectl ... -o jsonpath='{.items[0].metadata.name}'`
在 `replicas=0` 时：

```
error executing jsonpath "{.items[0].metadata.name}":
array index out of bounds: index 0, length 0
```

→ 非 0 退出 → `deploy.sh` 的「记录发布后状态」死在这里 →
**发布阶段 FAILURE → 触发了一次完全没必要的自动回滚**。

修法是 `target_pod()`：拿不到 pod 名时返回占位符，并按「缩容到 0」/「暂无 pod」
给出不同文案，**不报错**。

---

## ⑥ 产物落在哪、为什么

```
$CI_ARTIFACT_DIR（Jenkins 传宿主路径；本地默认 $REPO/logs/ci）
├── state/                    供回滚读取
│   ├── precheck_backup       ← precheck 的备份【目录】
│   ├── precheck_snapshot     ← 发布前快照
│   ├── precheck_diff / precheck_time
│   ├── deploy_was_new        ← 本次是不是新建（决定回滚用 delete 还是 undo）
│   ├── deploy_pre_image / deploy_pre_gen / deploy_pre_rev
│   ├── deploy_restarted      ← 本次是否补了重启（1/0）
│   └── deploy_post_image / deploy_post_gen / deploy_post_pod
├── live-backup-<ts>/         k8s/live/ 整目录备份（逐文件 md5 校验）
├── diff-<ts>.txt             kubectl diff 输出
├── dryrun-<ts>.txt           dry-run 输出
├── snapshot-<ts>.json        线上状态快照
├── apply-<ts>.txt            apply 输出
└── bench-<ts>.txt            性能基准结果
```

> ⚠️ **必须持久化**，所以 Jenkins 里它落在**宿主**仓库而不是 `$REPO/logs`：
> agent 的 workspace 是 emptyDir，`post.always` 的 `cleanWs()` 会把它清掉，
> 那样**回滚要用的 state 和备份就丢了**。
> Jenkinsfile 显式传 `CI_ARTIFACT_DIR`；本地跑就落在仓库自己的 `logs/ci`。

---

## ⑦ Jenkinsfile 的七个阶段

| 阶段 | 内容 | 条件 |
|---|---|---|
| ① 环境自检 | 工具链 / docker 连接 / 代码来源 / 目标 profile / 集群 / 目标工作负载 | 总是 |
| ② 预检 | `set +e` 调 precheck，解析 `RC=` | 总是 |
| ③ 发布 | `restart-only` 走 `restart.sh`，否则 `deploy.sh`；**标记 `DEPLOY_STARTED`** | `NO_DEPLOY != true && MODE != dry` |
| ④ 日志验证 | `verify.sh --layer=log` | 同上 |
| ⑤ 功能验证 | `verify.sh --layer=func` | 同上 `&& !SKIP_VERIFY` |
| ⑥ 性能基准 | `verify.sh --layer=bench` | 同上 |
| ⑦ 记录结果 | pods / 镜像 / generation | 总是 |

`options`：`timeout(40min)` / `disableConcurrentBuilds()` / `timestamps()` /
`buildDiscarder(numToKeepStr: '30')`。

`parameters`：

| 参数 | 值 | 说明 |
|---|---|---|
| `TARGET` | `march7` \| `embed` | 决定管哪个服务 / 跑哪套判据 |
| `MODE` | `full` \| `restart-only` \| `dry` | ⚠️ 见下 |
| `SKIP_VERIFY` | bool | 跳过验证（不推荐） |
| `BENCH_MIN` | string | 留空 = 用 target 默认 |

> ⚠️ **`MODE` 曾经是摆设**：Jenkinsfile 只调 `precheck.sh`/`deploy.sh`，
> 而那两个脚本都不读 `MODE`。后果：UI 上选 `dry=只预检` **照样真 apply → 真重启 vLLM**。
> 现在按 `pipeline.sh` 的语义接上了（`when` 表达式里判 `params.MODE != 'dry'`）。

---

## ⑧ 手工跑 vs Jenkins 跑

| | 手工 | Jenkins |
|---|---|---|
| 触发 | 手动敲命令 | `git push` / 点按钮 |
| 环境 | 你的 WSL shell | Agent 容器（**同样的脚本**） |
| 日志 | 终端 | Jenkins UI 保留 **30** 次 |
| 确认 | `confirm` 交互 | `CI_YES=1` 跳过 |
| 回滚 | 手动跑 | `post.failure` 自动（且只在部署开始过时） |

**⇒ 脚本不变，只是换个地方调。** 这就是"先写脚本再上 Jenkins"的意义。
