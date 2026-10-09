# 05 · 故障速查 Runbook

> 按**症状**查。每条都给「根因 → 处理 → 出处」。
> 全部来自实测，不是推测。

---

## 快速索引

| 症状 | 根因 | 跳到 |
|---|---|---|
| 「没找到 'Using V2 Model Runner'」但 grep 明明有 | **SIGPIPE 假阴性** | [①](#一-sigpipe-假阴性最危险) |
| 构建全绿，但改动没生效 | **「假成功」：CM 变了 pod 没重启** | [②](#二假成功cm-变了但-pod-没重启) |
| 发布阶段 FAILURE + 触发了一次莫名其妙的回滚 | **jsonpath 在 replicas=0 时数组越界** | [③](#三jsonpath-越界导致误回滚) |
| Windows 上 `127.0.0.1:<NodePort>` 必失败 | **NodePort 走 iptables DNAT，不产生 listen socket** | [④](#四nodeport-在-windows-上访问不到) |
| 掩码没生效（英文没被挡住） | `_from_model_config` 丢了 `logit_bias` | [⑤](#五掩码没生效) |
| `rollout 超时` | 2B 启动要 3-5 分钟；或权重路径错 | [⑥](#六rollout-超时) |
| 性能不达标 | GPU 被占 / 模型不对 | [⑦](#七性能不达标) |
| 自动回滚"执行了"但线上没变化 | **脚本文件已被 `cleanWs()` 删掉** | [⑧](#八自动回滚实际没生效) |
| UI 上选 `MODE=dry` 却真重启了服务 | `MODE` 参数是摆设 | [⑨](#九mode-参数是摆设) |
| 指标算出来差 20 倍 | **vLLM e2e 直方图桶太粗** | [docs/03](03-observability.md) |
| `kubectl` 里压根看不到 GPU | 缺 device plugin | [docs/04](04-gpu-on-wsl2.md) |
| embed: `pooling_type 不是 CLS` | 换了非 BERT 系模型（E5 是 MEAN） | [⑩](#十embed-的三个旋钮) |
| `没有差异 —— 无需发布`（退出码 2） | Deployment 没变 | [⑪](#十一无需发布与-r2-约定) |
| `请先提交` | 工作区脏 | `git add -A && git commit` |

---

## 一、SIGPIPE 假阴性（最危险）

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
**Jenkins 里每次验证的都是刚重启的新 pod（日志短）→ 从不触发。**
2026-10-08 拿一个跑了 **13h、日志 5495 行**的 pod 测才暴露出来。

**最危险的是「无错误」那条判据**：日志里**真有 error** 时会被管道误判成失败 →
走 else → 报「✅ 日志无 error」—— **假阴性，方向最危险。**

**正确写法**：

```bash
grep -q PATTERN <<< "$LOGS"        # ✅ here-string 没有上游进程，不存在 SIGPIPE
echo "$LOGS" | grep -q PATTERN     # ❌
```

**排查手法**：看到「明明有却报没找到」，先怀疑管道。

---

## 二、「假成功」：CM 变了但 pod 没重启

**症状**：构建全绿、验证全绿，但改动**根本没生效**；pod 里还是旧配置。

**根因**：k8s **不会**因为 ConfigMap 变了就重建 pod，而 vLLM **只在启动时读一次配置**。

```
改 CM → apply 更新了 CM → Deployment 没变 → 不重启 → vLLM 还读着旧配置
      → 验证跑在【旧配置的 pod】上 → 全绿 ⇒ "假成功"
```

**处理**：`deploy.sh` 现在会在 apply 前后比对 Deployment 引用到的每个 ConfigMap 的
`resourceVersion`，变了且 generation 没变就**自动补 `rollout restart`**，日志里明说：

```
⚠️ Deployment 的 spec 没变（generation 仍为 20），但它引用的 ConfigMap 变了: vllm-observability-env
   vLLM 只在启动时读一次配置 → 自动补一次 rollout restart
   （少了这一步就是【假成功】：CM 更新了、pod 却还跑着旧配置，而验证照样全绿）
```

**⇒ 改任何东西都只需要 `MODE=full` 一次。**

**⚠️ 三类 CM 不在自动处理范围内**，各自的生效方式不同：

| CM | 生效方式 |
|---|---|
| `prometheus-config` | **手动** `curl -X POST http://<WSL-IP>:30090/-/reload` |
| `grafana-dashboard-vllm` | 自己重载（file provider `updateIntervalSeconds: 10`，等 kubelet 同步 ~60s） |
| `nvidia-device-plugin-config` | **必须把 pod 模板的 `config-version` 注解 +1**，否则「假成功」 |

**同一个坑的第三种形态**：CM **不在仓库里** → 漂移无人知。
`prometheus-config` 就是这样烂掉的（抓取目标指向两个已不存在的服务 →
两个 vLLM 服务**一条指标都没被采集**，Grafana 曲线空了两天）。

---

## 三、jsonpath 越界导致误回滚

**症状**：发布阶段 FAILURE，然后触发一次**完全没必要**的自动回滚，日志里：

```
error executing jsonpath "{.items[0].metadata.name}":
array index out of bounds: index 0, length 0
```

**根因**：`replicas=0` 时 `items` 是**空数组**，`jsonpath` 报错 → 非 0 退出 →
`lib.sh` 的 `set -e` 让整个脚本当场挂掉。

实测：**2026-10-08 构建 #33**，`deploy.sh` 的「记录发布后状态」死在这一行。

**错误写法**：

```bash
kubectl get pods -l "$POD_SELECTOR" -o jsonpath='{.items[0].metadata.name}'   # ❌
```

**修法**（`target_pod()`，[`lib.sh:145-165`](../ci/scripts/lib.sh#L145-L165)）：

```bash
target_pod() {
  local p
  p=$(kubectl get pods -l "$POD_SELECTOR" -n "$NS" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -n "$p" ]; then printf '%s' "$p"
  elif target_scaled_to_zero; then printf '%s' "（已缩容到 0 副本）"
  else printf '%s' "（暂无 pod）"
  fi
}
```

**推广**：任何 `-o jsonpath='{.items[0]...}'` 都是隐患，`set -e` 下会变成"看不出来源"的崩溃。

---

## 四、NodePort 在 Windows 上访问不到

**症状**：WSL 里 `curl http://127.0.0.1:30800` 通；**Windows 里 `127.0.0.1:30800` 必失败**。

**根因**：

```
k3s NodePort 走 iptables DNAT，【不产生 listen socket】
WSL2 的 localhostForwarding 只转发【有 listen socket】的端口
⇒ Windows 的 127.0.0.1 访问不到 NodePort
```

**处理**：用 **WSL IP**（`hostname -I` 或 `tools/sync_k3s_endpoint.py`）。

```bash
python3 tools/sync_k3s_endpoint.py        # 打印端点清单 + 可选同步下游配置
```

**想用固定的 127.0.0.1**（需管理员）：

```
netsh interface portproxy add v4tov4 listenaddress=127.0.0.1 ^
  listenport=30800 connectaddress=<WSL-IP> connectport=30800
```

> WSL IP 在 WSL 重启后会变 → 重跑同步脚本即可。

**一个衍生坑**：不要在脚本里用 `hostname -I`——

| 环境 | `hostname -I` 行为 |
|---|---|
| WSL 宿主（GNU coreutils） | 正常 |
| **Jenkins agent 镜像（Alpine / busybox）** | `hostname: unrecognized option: I` → **打到 stderr、stdout 为空、rc 仍是 0** |

→ `subprocess.run(...).stdout.split()[0]` 直接 `IndexError`。
**2026-10-07 构建 #9 就死在这一行。**

**修法**：`endpoint.py` 用**按候选列表依次探测 `/health`** 替代：
① `$VLLM_URL` ② 集群内 Service ③ 本机 IP 的 NodePort。
本机 IP 用 socket 探测（connect 一个不可达地址，拿内核按路由选出的源地址），
**完全不依赖 hostname 的任何选项**。

---

## 五、掩码没生效

**症状**：英文诱导请求返回了 ASCII 字母。

**根因**：`/gencfg/generation_config.json` 里**不能有 `_from_model_config`**
—— 它会让 HF 从模型 config 重建，**静默丢掉 `logit_bias`**。

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

**背景**：屏蔽 472 个非中文 token 原本用**自定义 logits processor**，
但那会触发 **V1 model runner 回退**（日志会打 `does not yet support`）。
改用 `logit_bias` 服务端默认值就走 `--generation-config`，
**不会**触发回退 —— 这条正是 `verify.sh` 日志层 ①-1 和 ①-2 两条判据的由来。

---

## 六、`rollout 超时`

**处理顺序**：

```bash
kubectl get pods -l app=vllm-march7                  # 看状态
kubectl describe pod -l app=vllm-march7 | tail -30   # 看 Events
kubectl logs deploy/vllm-march7 -c vllm --tail=50    # 看日志【开头】也是关键
```

**常见根因**：

| 根因 | 特征 |
|---|---|
| 2B 模型启动确实要 **3-5 分钟** | 只是慢，`startupProbe` 的 `failureThreshold: 90` 给足了时间 |
| `--model=` 路径不存在 | 加载失败。**预检的 `check-models.py` 会在秒级拦住这个** |
| 显存不够（OOM） | 看 `nvidia-smi`；march7 实测要 6543 MiB |
| 挂载的 CM 不存在 | Deployment 挂的 CM 没 apply |

> ⚠️ 这期间（`strategy: Recreate`）**服务是完全 DOWN 的**，
> 最坏约 **18 分钟**中断（900s 超时 + 回滚）。这就是为什么模型路径校验
> 值得单独做一步 —— 它把这个数字变成"秒级"。

---

## 七、性能不达标

```bash
BENCH_MIN=120 ./ci/scripts/verify.sh      # 提高门槛重测
nvidia-smi                                 # 看显存有没有被别人占
```

参考区间（同 session A/B，见 [benchmarks/README](../benchmarks/README.md)）：

| 服务 | 实测 | 门槛 |
|---|---|---|
| march7 | **141.8 – 160.3 tok/s** | ≥ 100 |
| embed | **113.6 req/s**，中位 **7.60 ms/条** | ≥ 20 |

> ⚠️ `bench-20261008-121118.txt` 里有一行 `预热3: 64 tok / -0.66s = -96.7 tok/s`
> —— **负耗时**。这是 `time.time()` 在跨核/虚拟机时钟下的非单调导致的一次测量异常。
> 它落在**预热**阶段（不计入结果），所以那次平均 141.8 tok/s 仍然有效。
> 但如果出现在正式轮次里，就该怀疑测量而不是服务。

---

## 八、自动回滚"实际没生效"

**症状**：日志里出现回滚命令和「回滚也失败 —— 需要人工介入！」，
但回滚脚本其实根本没跑。

```
+ bash .../ci/scripts/rollback.sh
bash: .../rollback.sh: No such file or directory
+ echo '回滚也失败 —— 需要人工介入！'
```

**根因**：declarative pipeline 的 post 条件执行顺序是
`always → changed/fixed/regression/aborted/failure/success/... → cleanup`，
**`always` 比 `failure` 先跑**。把 `cleanWs()` 放在 `always` 里，
失败时工作区已经被删掉。

**⇒ 也就是说「失败自动回滚」这个功能在此之前从来没有真正生效过**
（一直没失败过所以没暴露）。实测 **构建 #24**。

**修法**：`cleanWs()` 只能放在 `cleanup`。

---

## 九、`MODE` 参数是摆设

**症状**：Jenkins UI 上选 `MODE=dry`（只预检），**照样真 apply → 真重启 vLLM**。

**根因**：Jenkinsfile 只调 `precheck.sh` / `deploy.sh`，而**那两个脚本都不读 `MODE`**。

**修法**：在 stage 的 `when` 表达式里接上 `pipeline.sh` 的语义：

```groovy
stage('③ 发布') {
    when { expression { return env.NO_DEPLOY != 'true' && params.MODE != 'dry' } }
    steps { script {
        env.DEPLOY_STARTED = 'true'          // ⭐ post.failure 靠它决定要不要回滚
        if (params.MODE == 'restart-only') { sh 'bash "$WORKSPACE/ci/scripts/restart.sh"' }
        else                               { sh 'bash "$WORKSPACE/ci/scripts/deploy.sh"' }
    } }
}
```

> **教训**：参数存在于 UI ≠ 参数被代码读取。装参数的时候要顺手写一条
> 「这个参数没接上会怎样」的自检。

---

## 十、embed 的三个旋钮

**症状**：`pooling_type 不是 CLS` / `use_activation 不是 False`。

**为什么严重**：**三个旋钮配错任何一个，服务照样返回形状正确的 768 维向量，
但语义是错的 → 下游读出头全崩。**

| 旋钮 | 正确值 | 处理 |
|---|---|---|
| `pooling_type` | `CLS` | 换了非 BERT 系模型（E5 是 MEAN）→ 显式传 `--pooler-config={"pooling_type":"CLS"}` |
| `use_activation` | `False` | `--pooler-config` 没写或写错 → 补上 `use_activation:false` |
| `dtype` | `float32` | bf16 会数值漂移 |

**换 embedding 模型时必须同时确认三件事**：

1. `--runner=pooling` 要留着（去掉就会被当生成模型加载，起不来）
2. 池化方式 —— 换模型后**必须重新生成 `embed_reference.json` 并重跑 `verify-embed.py`**
3. `--pooler-config={"use_activation":false}` 要留着（除非读出头是重新训的）

---

## 十一、「无需发布」与 `R2` 约定

**症状**：`没有差异 —— 无需发布（退出码 2）`。

这**不是错误**，是约定：用 `2` 区分「无需发布」和「预检通过（0）」。

| 退出码 | 含义 |
|---|---|
| `0` | 预检通过 |
| `2` | 无需发布 |
| 其他 | 预检失败 |

**⚠️ 这个约定在 Jenkins 里被吃掉过一次**：Jenkins 的 `sh` 步骤默认以 `sh -xe` 跑，
`-e` 让 `exit 2` **当场判失败**，后面的 `echo "RC=$?"` 根本执行不到 →
明明该走「无需发布」的正常路径，UI 上却是**红叉**（**构建 #7**）。

**修法**：

```groovy
def rc = sh(script: 'set +e; bash "$WORKSPACE/ci/scripts/precheck.sh"; echo "RC=$?"',
            returnStdout: true).trim()
echo "───────── precheck.sh 输出 ─────────"
echo rc                                  // ⭐ 必须显式打印
echo "───────────────────────────────────"
```

第二个 `echo rc` 也**不是多余的**：`returnStdout: true` 会把 precheck 的 stdout
**全部捕获走** → 不打印的话构建日志里只剩「预检退出码 = N」，
**diff 内容、模型权重校验、备份路径一个都看不见**。

---

## 十二、Agent / Controller 相关

| 症状 | 根因 | 处理 |
|---|---|---|
| `docker version` 失败 / permission denied | `/var/run/docker.sock` 是 `root:docker`，jenkins 用户在不了组里 | pod 模板设 `runAsUser: 0`（在 `jenkins-casc.yaml`） |
| `fatal: detected dubious ownership` | agent 以 root(uid 0) 跑，仓库属主是 uid 1000（WSL drvfs） | 镜像里 `git config --system --add safe.directory '*'`（agent 1.1 的唯一改动） |
| `fatal: '/srv/k3s-vllm-platform.git' does not appear to be a git repository` | **裸仓库只挂给了 Controller**，而 `checkout scm` 是跑在 **agent pod** 里的 | 裸仓库**同时**挂给两者（实测构建 #13） |
| CrashLoopBackOff | JCasC 报错（**看日志开头，不是尾部**） | `kubectl -n cicd logs deploy/jenkins \| head -50` |
| 插件 0 个 | 用了官方 `jenkins/jenkins` 镜像 | 官方镜像**不会**在启动时装 `plugins.txt` 里的插件（那个机制是给派生镜像构建期用的）→ 必须派生镜像 + `jenkins-plugin-cli` |
| UI 打不开（Windows） | 用了 `localhost` | 用 WSL IP，见 [④](#四nodeport-在-windows-上访问不到) |
| JCasC 把 Jenkins 搞崩 | 属性名写错 —— `mailer.address` 应为 `mailer.emailAddress` | `UnknownAttributesException` → `ConfigurationAsCodeBootFailure` → 容器退出。日志里只看到 Jetty 优雅关闭的堆栈，**看不出原因** |
| 构建慢（几小时） | 没用宿主 docker.sock | 检查 agent pod 的 volume 挂载 |
| Alpine vs Debian | Debian + apt-get 装 git/python3/docker-cli 下载 100+ MB，**卡了 10 分钟没动**；Alpine + apk **4.5 秒完成** | 用 `jenkins/inbound-agent:alpine` |

---

## 十三、删除资源要手工（apply 型流水线的固有边界）

```bash
# 把文件从 k8s/live/ 删掉、commit、跑流水线 —— 集群里那个对象【仍然在】
kubectl -n default delete <kind> <name>
```

**已确认的孤儿**（在集群里存在、无 manifest 管理，只占空间）：

| 对象 | 大小 | 说明 |
|---|---|---|
| `cm/vllm-cn-mask`、`cm/vllm-gencfg` | — | 早期中文掩码 / 旧版采样参数，已无引用 |
| `pvc/mongodb-data-pvc` + 底层 PV | 20Gi | MongoDB 审计库，随审计代理下线废弃 |
| 一个 `Released` 的 PV | 10Gi | claimRef 指向**已不存在**的 `audit-data-pvc` |
| 僵尸 ReplicaSet | — | `default` 里 10 个 / `cicd` 里 6 个（0 副本的历史版本） |

> ⚠️ `Retain` 策略下删 PVC **PV 不会自动消失**，得显式删。
> 删之前先确认里面没有要留的数据。
