# legacy-scripts/ · 早期部署脚本（**已被 CI 取代，作历史**）

> 这 7 个 `wsl-*.sh` 是**流水线上线之前**的手工部署/诊断脚本。
> 它们**不再被使用**，保留下来是为了说明「这套系统的前身长什么样」，
> 以及为什么值得把它重写成 `ci/scripts/` 那一套判据工程。

---

## 一、它们是干什么的

| 脚本 | 作用 | 现在的对应物 |
|---|---|---|
| `wsl-deploy-vllm.sh` | 手工 apply 单个清单文件 + 等 pod + 冒烟测试 | `ci/scripts/deploy.sh`（apply **整个目录**） |
| `wsl-redeploy-vllm.sh` | 重建 Deployment | `ci/scripts/deploy.sh` |
| `wsl-stop-vllm.sh` | 停掉 vLLM | 改 `replicas: 0` → commit → push（CI 自动发布） |
| `wsl-verify-k8s-vllm.sh` | 手工查 pod/svc/endpoints + 发几个请求看回复 | `ci/scripts/verify.sh`（**三层判据**） |
| `wsl-audit-k3s.sh` | 审计集群所有工作负载 / GPU / 磁盘 | 已整合进 `docs/01` 的组件地图 |
| `wsl-check-k3s.sh` | 查 k3s 进程 / kubectl / kubeconfig / 端口监听 | 无直接对应（按需手工） |
| `wsl-deploy-mongo-audit.sh` | 部署 vLLM + MongoDB 审计链路 | **已废弃** —— 审计代理 2026-10-06「拆胶水」时下线 |

---

## 二、为什么它们**不够**（这才是有价值的部分）

对照现在 `ci/scripts/` 做的每一件事，看早期脚本缺了什么：

| 缺的东西 | 后果 |
|---|---|
| **没有 `set -euo pipefail`** | 中间一步失败会继续往下跑，"看起来成功了" |
| **没有预检** | 没有 diff、没有 dry-run、没有备份 → 改错了**直接上线** |
| **没有可验证备份** | 出问题只能手工回忆改了什么 |
| **没有判据** | `wsl-verify-k8s-vllm.sh` 只是"打印输出给人看"，**人要看、要判断** |
| **不解析 endpoint** | 写死 `127.0.0.1:30800` → 在 Jenkins agent 里必失败 |
| **手工 `git`** | 无法回答"这次部署的是哪个 commit" |
| **没有状态落盘** | 上一版镜像是什么？不知道 → 无法精确回滚 |
| **没有触发机制** | 每次都要人记得跑 |

### 一个具体的对比

**早期**（`wsl-verify-k8s-vllm.sh` 第 4 步）：

```bash
for u in ["你好", "早上好", "今天好累啊"]:
    ...
    print(f"  {u:<12} → {reply}  ({ms}ms)")
# ⇒ 输出是给人看的，通过与否由人判断
```

**现在**（`ci/scripts/verify-march7.py`）：

```python
okk = n_cjk >= 5 and not bad          # ≥5 个汉字、无 \ufffd 乱码
if not okk:
    fails.append(...)                 # ← 累积到 fails
...
if fails:
    return 1                          # ← 非 0 退出码 = 判据，不是给人看的文字
```

**⇒ 从「打印给人看」变成「返回退出码」。**
这就是 `pipeline.sh` / Jenkinsfile 能**自动回滚**的前提 ——
它们判的是退出码，不是人的眼睛。

---

## 三、⚠️ 这些脚本是**原样**保留的

**没有做路径/配置的适配**（除了必要的脱敏）。具体：

- 里面的 `kubectl apply -f /srv/k3s-vllm-platform/k8s/vllm-deployment.yaml`
  指向的文件**已经归档**到 `k8s/legacy/`，**现在跑会失败**
- `wsl-deploy-mongo-audit.sh` 依赖的 `build_manifest_mongo.py`
  和 MongoDB 审计链路**都不在这个仓库里**（审计通道已死）
- 它们引用的 `log-proxy` 容器、`vllm-plugins` ConfigMap **都已经不存在**

**⇒ 它们的用途是「阅读」，不是「执行」。** 想跑就会失败，这是设计如此 ——
一个能跑的历史脚本会让人以为这条路还有效。

---

## 四、从这些脚本里仍能读到的有价值信息

### 1. 部署顺序的雏形

看一下 `wsl-deploy-vllm.sh` 的结构：**生成清单 → 清理旧的 → apply → 等 PVC →
等 pod → 冒烟测试**。这基本上就是后来 `precheck.sh` + `deploy.sh` + `verify.sh`
的**手动版**。

> **「把手工步骤脚本化，再把脚本拆成有判据的阶段」** 就是这个项目演化的路径。

### 2. 一次真实的内网连通性排查

`wsl-verify-k8s-vllm.sh` 第 1 步同时查了三层地址：

```
NodePort (127.0.0.1:30800):
Service  (ClusterIP 10.43.x.x:8000):
Pod IP   (10.42.x.x:8000):
```

**这三层是必须分开查的** —— 它们会各自失败：

| 层 | 失败原因 |
|---|---|
| NodePort | 走 iptables DNAT 不产生 listen socket → **Windows 的 `127.0.0.1` 访问不到**（在 WSL 里却是通的） |
| Service ClusterIP | 只在集群内可达（或 WSL 宿主上也能通，因为 k3s 就装在 WSL 里） |
| Pod IP | pod 重建后 IP 会变 |

这个"三层都查"的习惯后来变成了 `endpoint.py` 的**候选列表探测**：
`$VLLM_URL` → 集群内 Service → 本机 IP 的 NodePort，取第一个 `/health` 通 200 的。

### 3. 中文掩码的早期做法

`wsl-deploy-mongo-audit.sh` 里的内联 Python 直接在**客户端**过滤外来字符：

```python
foreign = re.compile(r'[\u0600-\u06FF\u0400-\u04FF\uAC00-\uD7AF\u3040-\u30FF...]')
```

**这是在服务端做掩码之前的临时办法** —— 它靠客户端自觉，
换个客户端就失效。

**现在**：服务端 `logit_bias` 屏蔽 472 个非中文 token（`20-vllm-gencfg-2b.yaml`），
并且有 `verify-march7.py` 的**英文诱导判据**来证明掩码真的生效。

> **⇒ 从「客户端过滤」到「服务端约束 + 服务端判据」，这是同一件事的成熟形态。**

---

## 五、相关归档

这些脚本依赖的历史 manifest 都在 [`k8s/legacy/`](../k8s/legacy/)，
包括 `vllm-deployment.yaml`、`vllm-final.yaml`、`proxy_mongo.py`、
`chinese_only.py` 等，以及那份说明「谁取代了谁」的
[`k8s/legacy/README.md`](../k8s/legacy/README.md)。
