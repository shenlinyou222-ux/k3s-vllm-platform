# dashboards/ · Grafana 仪表盘

> 4 个 dashboard JSON，从 `k8s/live/60-grafana-dashboards.yaml` 这份 ConfigMap
> 里**原样抽出**（`yaml` 的块标量 → 独立文件，内容一字未改）。

---

## 一、四个盘

| 文件 | uid | 路径 | 内容 |
|---|---|---|---|
| `vllm.json` | `vllm-mon` | `/d/vllm-mon` | ⭐ 生成式 LLM（vllm-march7） |
| `embed.json` | `vllm-embed-mon` | `/d/vllm-embed-mon` | ⭐ 向量服务（vllm-embed / dmeta-small） |
| `gpu.json` | `gpu-mon` | `/d/gpu-mon` | GPU 硬件（nvidia-smi exporter，指标名 `nvidia_smi_*`） |
| `llamacpp.json` | `llamacpp-mon` | `/d/llamacpp-mon` | llama.cpp CPU 推理对照（**目标服务已下线**，保留作历史） |

### 在 Grafana 里 Import

UI → Dashboards → New → Import → 上传 JSON → 选 Prometheus 数据源。

### 或者继续用 file provider（和集群里的做法一致）

```bash
# 把 JSON 塞回 ConfigMap（每个 key 当一个 dashboard 文件）
kubectl -n monitoring create configmap grafana-dashboard-vllm \
  --from-file=vllm.json --from-file=embed.json \
  --from-file=gpu.json --from-file=llamacpp.json \
  --dry-run=client -o yaml | kubectl apply -f -

# Grafana 会自己重载（file provider updateIntervalSeconds: 10），
# 但要等 kubelet 把新 CM 同步到挂载卷（默认 ~60s）。不用重启 Grafana。
```

---

## 二、⭐⭐ 看 `embed.json` 之前请先知道的事

**这个盘的 p50/p90/p99 面板用的是 `time_to_first_token_seconds`，不是
`e2e_request_latency_seconds`。**

原因：vLLM 的 e2e 延迟直方图**桶边界是硬编码的**（最小桶 **0.3 秒**），
而这个服务单条只要 **7 毫秒** → 全部请求落进 `le=0.3` 一个桶 →
`histogram_quantile` 只能线性插值 → 算出「p50 = 150 ms」**是插值产物，
真值 7.4 ms，差 20 倍**。

`time_to_first_token_seconds` 的桶是 **1 ms 起**，而对 **pooling 模型
TTFT 就等于端到端延迟**（实测两者的 `_sum`/`_count` 完全相同）。

**完整分析见 [docs/03-observability.md](../docs/03-observability.md)。**

> 这段解释**也写在 `embed.json` 自己的一个 Markdown 文本面板里**
> （见 `panels` 里那段 `"content"`）—— 所以看板的人不用翻仓库就知道
> 为什么这么算。这是刻意的：**把判据的理由放在会被看见的地方。**

---

## 三、两个 vLLM 服务**不能**共用一个盘

`vllm.json` 的查询**没有 `service` 标签过滤**，而集群里有两个 vLLM 服务
（march7 平均 **336 ms** / embed 平均 **26 ms**）—— 混在一起算分位数**两边都不对**。

所以 `embed.json` 里**所有**查询都带 `service="embed"`。

> Prometheus 那边靠 `static_configs` 的 label 区分：
> ```yaml
> - targets: ['vllm-march7.default.svc.cluster.local:8000']
>   labels: {engine: vllm, device: gpu, service: march7}
> - targets: ['vllm-embed.default.svc.cluster.local:8000']
>   labels: {engine: vllm, device: gpu, service: embed}
> ```

---

## 四、修过的一个失效指标名

vLLM 0.30 给 TPOT 指标**加了 `request_` 前缀**：

```
time_per_output_token_seconds  →  request_time_per_output_token_seconds
```

旧名字查不到数据 → **TPOT 面板一直是空的**（不是报错，是空 —— **更难发现**）。

**⇒ 升级 vLLM 后要重新核对指标名。**「面板空着」和「面板报错」是两种不同的
失败模式，前者不会有人报警。

---

## 五、能可靠监控 / 不能

| ✅ | ❌ |
|---|---|
| 可用性 `up` | **e2e 直方图的分位数**（桶太粗，见上） |
| QPS `rate(request_success_total)` | |
| **分位数（用 TTFT 直方图）** | |
| 平均延迟 `_sum/_count`（精确） | |
| 排队/推理时间、并发、prompt token 速率 | |
| GPU（nvidia-smi exporter） | **逐进程显存**（WSL2 上 `nvidia-smi` 显存列永远是 `N/A`；只能差分测量） |

---

## 六、改这份盘的两种方式

| 方式 | 生效 |
|---|---|
| 改 `k8s/live/60-grafana-dashboards.yaml`（仓库） | commit + push → CI apply → Grafana 自动重载（等 ~60s） |
| 在 Grafana UI 里改 | **只在内存里** —— 下次 CM 同步/reload 会被覆盖回去 |

> ⚠️ 改这份 CM 时注意：`deploy.sh` 的「CM 变了自动补 rollout restart」逻辑
> **只认目标 Deployment 引用的 CM**。`grafana-dashboard-vllm` 不属于
> `vllm-march7`/`vllm-embed`，所以**不会被自动处理** —— 但它也不需要重启，
> file provider 自己会重载。
