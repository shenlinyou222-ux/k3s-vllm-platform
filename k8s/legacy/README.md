# `k8s/legacy/` —— 归档区（**不参与部署**）

这里的东西**一个都不会被 apply**。流水线只认 `k8s/live/`；`k8s/*.yaml`（Jenkins 自身）
是手工 apply 的 CI 基础设施。除此之外的历史文件全部收在这里，避免和新结构混淆。

> ⚠️ **归档文件 ≠ 删除资源。** 把 yaml 挪进来不会动集群里的对象；
> 集群里那些"没人管"的孤儿资源，见下面的清单，需要你手工删。

---

## 一、归档了什么，被谁取代

| 归档文件 | 是什么 | 被谁取代 |
|---|---|---|
| `vllm-deployment.yaml` | 最早的 vLLM 清单（含 log-proxy 审计代理） | `k8s/live/10-vllm-mongo.yaml` |
| `vllm-final.yaml` | 加 hostPort / mask 的一版 | 同上 |
| `vllm-deployment-pvc.yaml` | 引入 PV/PVC 的一版 | 同上 |
| `npc-qwen.yaml` | 早期另一套模型的试验清单 | 同上（现在是 `Qwen3.5-2B-March7-cn`） |
| `gpu-test.yaml` | k8s GPU 调度的测试 Pod | 一次性验证用，无替代 |
| `proxy_mongo.py` | 审计代理（把请求写进 MongoDB） | 2026-10-06「拆胶水」时下线，改用 vLLM 原生 `--enable-log-requests/--enable-log-outputs` |
| `chinese_only.py` | 自定义 logits processor 做中文掩码 | 改用 `logit_bias` 服务端默认值（见 `k8s/live/20-vllm-gencfg-2b.yaml`），为的是保住 V2 model runner |
| `cn_mask.py` | 生成掩码 token id 的工具 | 同上 |
| `uvicorn-logcfg.json` | 日志 dictConfig 的原始 JSON | 已纳管为 `k8s/live/30-vllm-uvicorn-logcfg.yaml` |
| `make-before.py` | 一次性「反向补丁」救急工具 | 不再需要（`precheck.sh` 现在每次自动备份整目录） |
| `mongodb.yaml` | MongoDB（审计库） | 审计代理下线后不再需要 |
| `jenkins-agent-deployment.yaml` | 常驻 agent 的静态 Deployment | 改用 Kubernetes 插件动态建 agent（见 `k8s/jenkins-casc.yaml`） |

## 二、⚠️ 集群里的孤儿资源（待你手工删除）

以下是**在集群里存在、但没有任何 manifest 管理**的对象。它们不会被 `kubectl diff`
看到，也不会被流水线碰 —— 只会白占空间。确认无用后按下面的命令删。

### 孤儿 ConfigMap

```bash
# vllm-cn-mask  —— 早期中文掩码用的 ConfigMap，已无引用
# vllm-gencfg    —— 旧版采样参数，已被 vllm-gencfg-2b 取代
kubectl -n default delete cm vllm-cn-mask vllm-gencfg
```

### 孤儿 PVC / PV

| 对象 | 大小 | 说明 |
|---|---|---|
| `pvc/mongodb-data-pvc` | 20Gi | MongoDB 审计库的数据盘，随 `legacy/mongodb.yaml` 一起废弃 |
| `pv/pvc-d8197e3e-…` | 20Gi | ↑ 的底层 PV（`reclaimPolicy: Retain` → 删 PVC 后 PV 会留下来） |
| `pv/pvc-dd87a0e4-…` | 10Gi | 状态 `Released`，claimRef 指向**已不存在**的 `audit-data-pvc` |

```bash
kubectl -n default delete pvc mongodb-data-pvc
# Retain 策略下 PV 不会自动消失，得显式删：
kubectl delete pv pvc-d8197e3e-b8e6-493b-a7d8-6c386e2840b9
kubectl delete pv pvc-dd87a0e4-7405-4701-b20d-73673c11747c
```

> ⚠️ 删之前先确认里面没有要留的数据（`local-path` 的 PV 数据在
> `/var/lib/rancher/k3s/storage/` 或宿主对应路径下）。

### 被 manifest 管、但 Deployment 没挂载的 PVC

`pvc/audit-fallback-pvc`（5Gi）定义在 `k8s/live/10-vllm-mongo.yaml` 里 ——
它对流水线是"受管"的（`kubectl diff` 看得见），但**没有任何容器挂载它**，
是审计代理时代留下的。要么在 live 清单里删掉、要么保留占位，你自己定。

### 僵尸 ReplicaSet（0 副本的历史版本）

```
default:  10 个（vllm-march7-* 的历史版本，可清）
cicd:      6 个（jenkins-* 的历史版本，可清）
```

不影响运行，只是 `kubectl get all` 噪音。要清：

```bash
# k8s 只保留最后一个 revision 用于回滚；>10 的会自动清。
# 想立刻清掉 default 里 0 副本的：
kubectl -n default get rs -o json \
  | python3 -c "
import json,sys,subprocess
d=json.load(sys.stdin)
z=[r['metadata']['name'] for r in d['items'] if (r['spec'].get('replicas') or 0)==0]
for n in z: subprocess.run(['kubectl','-n','default','delete','rs',n])"
```

---

## 三、为什么这么分

```
k8s/live/     ← 流水线 apply 的东西（唯一事实来源，改这里就会部署）
k8s/*.yaml    ← Jenkins 自己（手工 apply，见 k8s/README-jenkins.md）
k8s/legacy/   ← 归档，只供查阅；里面的东西都不会被 apply
```

分界线是「**谁 apply 它**」：只有 `k8s/live/` 由流水线管理。
