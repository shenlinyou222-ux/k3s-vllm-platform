# 04 · WSL2 上的 GPU 调度 ⭐

> 「GPU 能跑」和「k8s 知道有 GPU」是两件事。这一节记录从**前者**修到**后者**的过程，
> 以及修完之后**仍然存在**的三条边界。

---

## 一、修之前是什么状态

```
$ kubectl describe node <node>
Capacity:     nvidia.com/gpu: 0        ← 节点完全不认 GPU
```

但**服务一直正常跑** —— 因为 GPU 是靠 **dockerd 的 `default-runtime: nvidia`**
隐式注入 `/dev/dxg` 给**所有**容器的。

> 关键事实：这台机器的 k3s 走 **`cri-dockerd` → `dockerd`**，不是内置 containerd。

后果：**能跑，但 k8s 层完全不知情** —— 不能调度、不能计量、不能做准入控制。
清单里写 `nvidia.com/gpu: 1` 会让 Pod **永远 Pending**（`Insufficient nvidia.com/gpu`），
所以以前只能不写。

## 修之后

```
$ kubectl describe node <node>
Capacity:     nvidia.com/gpu: 4
Allocatable:  nvidia.com/gpu: 4
Allocated:    nvidia.com/gpu  1 / 4
```

两个 Deployment 现在都**显式声明**：

```yaml
resources:
  requests: {cpu: "1", memory: "4Gi", nvidia.com/gpu: "1"}
  limits:   {cpu: "3", memory: "6Gi", nvidia.com/gpu: "1"}
```

> ⚠️ **扩展资源的 `requests` 与 `limits` 必须相等**（k8s 的硬规定）。

---

## 二、为什么"装不上"——两个原因，都不是"装不了"

| # | 原因 | 修法 |
|---|---|---|
| 1 | **镜像拉不到**：dockerd 的 `HTTPS_PROXY=<proxy-host>:7897`，而 `NO_PROXY` 里**没有** `nvcr.io` → 代理对 HEAD 请求返回 `unexpected EOF`（**而 curl 直连是 200**） | 把 `nvcr.io` 加进 `/etc/systemd/system/docker.service.d/http-proxy.conf` 的 `NO_PROXY` |
| 2 | **没人注意到缺它** —— 因为 GPU 隐式可用，服务一直正常跑 | 装上后才有 `nvidia.com/gpu` |

> ⚠️ 改 `NO_PROXY` 要 `systemctl restart docker`，而 **k3s 走 cri-dockerd
> → 所有 pod 会被杀掉**。测试环境可接受（k3s 会自动重建，实测 12 个 pod 全部恢复）。
> **生产环境要挑窗口。**

> 同一个代理问题的另一面（2026-10-08 遇到的第三个症状）：
> `ghcr.io` 在 `NO_PROXY` 里，但 **blob 的 CDN
> （`pkg-containers.githubusercontent.com`）不在** → 拉 ghcr.io 时
> **manifest 能拿到、blob 下载报 `unexpected EOF`**。
> 绕法：走镜像源（实测 `ghcr.nju.edu.cn` 可用，`ghcr.dockerproxy.net` 也行）。
> 这直接影响 `80-llama-asr.yaml` 的镜像地址。

---

## 三、为什么能装——前置条件（实测都满足）

- k3s 用 `cri-dockerd` → `dockerd`，而 dockerd 的 `default-runtime` **已经是 `nvidia`**
- `nvidia-container-toolkit` 已装，且**对 WSL 有原生支持**：
  `nvidia-container-cli list` 返回的就是 `/dev/dxg` + `/usr/lib/wsl/lib/*`
  （**不是**标准 Linux 的 `/dev/nvidia*`）
- **NVML 在 WSL 上可用**：`/usr/lib/wsl/lib/libnvidia-ml.so.1` 能枚举到 RTX 5060
- 官方 device plugin 镜像**不带 NVML**（依赖宿主）→ 所以挂上 WSL 的 libs
  就能让它用**对的那一份**

---

## 四、⭐ 三个 WSL 适配点

| 配置 | 为什么 |
|---|---|
| 挂 **`/dev/dxg`** + **`/usr/lib/wsl/lib`**，并设 **`LD_LIBRARY_PATH=/usr/lib/wsl/lib`** | 镜像不带 NVML；不加这个它会走标准 ld 路径找到 `/usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1`（**CUDA toolkit 带的那份，需要 `/dev/nvidia*`，在 WSL 上不工作**） |
| **`--fail-on-init-error=false`** | 默认 `true` 会**直接退出** → CrashLoopBackOff；WSL 上给它重试的机会 |
| **`migStrategy: none`** | WSL 没有 MIG，别让插件去探测 |

另外两条配套的：

```yaml
env:
- name: DP_DISABLE_HEALTHCHECKS
  value: xids          # WSL 上没有 /proc/driver/nvidia，XID 健康检查没有意义
```

```yaml
# ⭐ 改 ConfigMap（config.yaml）时必须把这个注解 +1
annotations:
  nvidia-device-plugin/config-version: "2"   # 历史：1 = replicas 2；2 = replicas 4
```

> ⚠️ **最后这条是个独立的「假成功」**：ConfigMap 是**文件挂载**，改了不重建 pod，
> 而 device plugin **只在启动时读一次** `config.yaml` → 改 `replicas` 不重启
> **= 配置不生效**。（和 vLLM ConfigMap 那个坑**一模一样**，见 [docs/02](02-deployment-pipeline.md)。）
>
> 这个注解在 **pod 模板**里，改它会触发滚动更新。
> 而 `deploy.sh` 的「CM 变了自动重启」逻辑**只认目标 Deployment 引用的 CM** ——
> 这个 CM 不属于 `vllm-march7`/`vllm-embed`，**所以不会被自动处理，必须手工 +1**。

---

## 五、⚠️⚠️ 三条必须记住的边界（别指望它做不到的事）

### ① k8s 的 GPU 资源是【整数计数】，不是显存

```yaml
nvidia.com/gpu: "1"     # ✅ "我要一整块 GPU"
nvidia.com/gpu: "2Gi"   # ❌ 不存在这种写法
```

**显存切分在 k8s 层做不到** —— 那是 MIG 的活（A100/H100 才有），
**RTX 5060 不支持 MIG**。显存仍然只能靠 vLLM 自己的
`--gpu-memory-utilization` / `--kv-cache-memory` 来分。

> 顺带一个 vLLM 侧的观察：`--gpu-memory-utilization` 是**黑箱系数** ——
> 它只用来【算】KV cache 该多大，算出来多少完全看不出来。实测 march7：
>
> ```
> Available KV cache memory: 0.7 GiB  （22,937 tokens，2048-token 请求并发 11.2×）
> Actual usage is 1.83 GiB consumed + 1.84 GiB peak activation + 0.07 CUDAGraph
> ```
>
> 而进程**实际占 6543 MiB** —— 比 0.55 折算出的预算（4483 MiB）**还多 46%**，
> 因为 CUDA context 和 torch 分配器不在这个预算的管辖范围内。
> vLLM 自己也建议了显式值：
>
> ```
> "Replace gpu_memory_utilization config with --kv-cache-memory=522079744 (0.49 GiB)
>  to fit into requested memory, or --kv-cache-memory=3197111808 (2.98 GiB) ..."
> ```
>
> 所以本仓库里改用了**显式 `--kv-cache-memory=1073741824`（1 GiB）** ——
> 设置它之后 vLLM **跳过内存探测、直接分配这么多 KV cache**，
> 于是显存占用变得**可预测**，方便和别的模型共用这张卡。

### ② 在 WSL 上它只是【声明式】的，不是强制隔离

dockerd 的 `default-runtime=nvidia` 会给**每个**容器注入 `/dev/dxg` ——
**不申请 `nvidia.com/gpu` 的 Pod 照样能用 GPU。**

所以买到的是：

- ✅ **调度准入**：k8s 不让超过 N 个 GPU Pod 落地（实测申请 3 个 → Pending）
- ✅ **可见性**：`kubectl describe node` 能看到 GPU、谁占了 GPU 一目了然
- ❌ **不是**"没申请就用不了"

### ③ `timeSlicing.replicas` 是**管理约定**，不是技术限制

```yaml
sharing:
  timeSlicing:
    resources:
      - name: nvidia.com/gpu
        replicas: 4        # 从 2 提到 4
```

它是「把 1 块物理 GPU 虚拟成 N 个**可调度单元**」，**不是显存切分**。
选 4 是因为 march7 已缩到 0 副本、显存腾出来给新模型，留 4 个槽位方便扩展。

**⚠️ 槽位变多不会变出显存。** 加服务前仍然要看 `nvidia-smi` 余量 ——
**这张卡只有 8151 MiB。**

---

## 六、实际部署状态（2026-10-08 晚）

| 服务 | replicas | GPU 计数 | 实测显存 | 说明 |
|---|---|---|---|---|
| `vllm-embed` | **1** | 1 | **693 MiB** | 向量服务，在跑 |
| `vllm-march7` | **0** | 0 | 0 | ⭐ 已缩容，把 GPU 让给别的模型 |

缩容 march7 后 GPU 从 7236 MiB 降到 **4183 MiB 已用 / 3713 MiB 空闲**。
恢复它：把 `10-vllm-mongo.yaml` 的 `replicas` 改回 `1` → commit → push
（**权重和 PVC 都还在，不用重新准备**）。

### 一个有意思的对照：故意不申请 GPU 的服务

`80-llama-asr.yaml`（Qwen3-ASR 语音转写，llama.cpp，GGUF）是
**「零显存」设计** —— 原来跑在 Windows 侧的 `llama-server.exe`（CPU），
搬进 k8s 保持这个策略：**不申请 `nvidia.com/gpu`、不占显存**，
把卡留给真正需要它的模型。

> 注意：因为 ② 的边界存在，这个"不申请"是**自我约束**，不是 k8s 强制的。
> 而它带来的真实收益是**调度准入**：它不会占掉那 4 个 GPU 槽位。
>
> 它也是唯一一个模型需要用**另一种 `--model` 写法**的服务（llama.cpp 不支持
> `--model=PATH`，值是下一行的独立列表项）—— `check-models.py` 两种都解析。

CPU/内存按实测收紧（cgroup `cpu.stat` + `memory.current`，**不是 `kubectl top`**）：

| 服务 | 空闲 | 并发 8 | 并发 16 | 并发 32 | 结论 |
|---|---|---|---|---|---|
| march7 | 0.009 核 / 3981 Mi | 1.122 核 | 1.062 核 | 0.944 核 | **CPU 峰值 1.12 核**（并发升高反而不涨，**瓶颈在 GPU 不在 CPU**）；内存**完全平坦**（vLLM 启动即预分配完毕） |
| embed | 0.013 核 / 2202 Mi | 2.182 核 | 1.929 核 | 2.108 核 | **CPU 峰值 2.18 核 —— 比 march7 还高**，因为每个请求要 tokenize 32 条文本并把 32×768 个浮点数序列化成 JSON，**全是纯 CPU 活** |

`limits` 取峰值的 1.4×–2.7×。

---

## 七、回滚

```bash
kubectl delete -f k8s/live/70-nvidia-device-plugin.yaml
# ⚠️ 然后必须从两个 Deployment 里去掉 nvidia.com/gpu（否则 Pod 会 Pending！）
```
