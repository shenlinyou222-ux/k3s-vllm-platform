# 03 · 可观测性 ⭐

> 这一节记录一个**20 倍偏差**的定位过程。它是整份文档里技术含量最高的一段。

---

## 一、栈的形状

```
                     scrape_interval: 5s / 保留 24h
  ┌──────────────┐   ────────────────────────────────►  ┌────────────┐
  │  Prometheus  │                                      │  Grafana   │
  │  :30090      │  ◄────────────────────────────────   │  :30030    │
  │ (ns monitoring)│       4 个 dashboard（file prov.）  │            │
  └──────┬───────┘                                      └────────────┘
         │ 抓 4 个 job
         ├─ job: vllm        vllm-march7:8000  (label service=march7)
         │                   vllm-embed:8000   (label service=embed)   ← 靠标签区分
         ├─ job: llamacpp    llama-qwen:8000   （目标服务已下线，长期 DOWN）
         ├─ job: nvidia_gpu  nvidia-smi exporter :9400  ← 指标名是 nvidia_smi_*
         └─ job: prometheus  localhost:9090
```

仪表盘：

| 路径 | 内容 |
|---|---|
| `/d/vllm-mon` | 生成式 LLM（vllm-march7） |
| `/d/vllm-embed-mon` | ⭐ 向量服务（vllm-embed / dmeta-small） |
| `/d/gpu-mon` | GPU 硬件（nvidia-smi exporter） |
| `/d/llamacpp-mon` | llama.cpp CPU 推理对照（目标服务已下线） |

> ⚠️ **两个 vLLM 服务不能共用一个仪表盘**：`vllm.json` 的查询没有 `service` 标签过滤，
> 而集群里有两个 vLLM 服务（march7 平均 **336 ms** / embed 平均 **26 ms**）——
> 混在一起算分位数**两边都不对**。所以 `embed.json` 里**所有**查询都带 `service="embed"`。

---

## 二、⭐⭐ 核心发现：vLLM 的 e2e 延迟直方图测不了这个服务

### 现象

向量服务单条请求实测 **7 ms** 量级。但 Grafana 上用
`histogram_quantile(0.5, ... vllm:e2e_request_latency_seconds_bucket ...)`
算出来的 **p50 = 150 ms**。

**差了 20 倍。** 而 QPS、`up`、平均延迟（`_sum/_count`）都是对的 ——
只有**分位数**错。

### 根因

vLLM 的 `vllm:e2e_request_latency_seconds` 桶边界是**硬编码**的
（`vllm/v1/metrics/buckets.py` 的 `REQUEST_LATENCY_BUCKETS`），**最小桶 0.3 秒**：

```
0.3, 0.5, 0.8, 1.0, 1.5, 2.0, 2.5, 5, 10, 15, 20, 30, 40, 50, 60, 120, 240, ..., 7680
```

而服务只要 **7 毫秒** → **全部 4110 条请求都落进 `le=0.3` 这一个桶**：

```
实测：0.3 到 +Inf 每个桶的计数完全相同，都是 4110
```

`histogram_quantile` 只能在 `[0, 0.3]` 之间线性插值 → 算出 **「p50 = 150 ms」** ——
**这是插值产物，不是实测值（真值 7.4 ms，差 20 倍）**。

`buckets.py` 里**没有任何环境变量**可以覆盖这个列表。

### 解法：改用 `time_to_first_token_seconds`

它的桶是 **1 ms 起**：

```
0.001, 0.005, 0.01, 0.02, 0.04, ...
```

而对 **pooling 模型**，**TTFT 就等于端到端延迟** —— 实测两者的 `_sum`/`_count`
**完全相同**：

```
time_to_first_token_seconds : _sum = 103.896 s, _count = 3961
```

所以 `embed.json` 的分位数面板用它，而不是 e2e 直方图。

```promql
histogram_quantile(0.50, sum(rate(vllm:time_to_first_token_seconds_bucket{service="embed"}[1m])) by (le)) * 1000
```

### 能可靠监控 / 不能

| ✅ 能可靠监控 | ❌ 不能 |
|---|---|
| 可用性 `up` | **e2e 直方图的分位数**（桶太粗，见上） |
| QPS `rate(request_success_total)` | |
| **分位数（用 TTFT 直方图）** | |
| 平均延迟 `_sum/_count`（精确） | |
| 排队/推理时间、并发、prompt token 速率 | |
| GPU（nvidia-smi exporter，指标名 `nvidia_smi_*`） | |

### 怎么读这些面板

- **p50 / p90 / p99**：真实分位数。空载单条 ≈ **5–8 ms**；批量 64 条摊薄后 ≈ **0.8–1.4 ms/条**
- **平均延迟拆解**：「排队」接近 0 说明没有积压；「推理」≈ 端到端的一半，
  差额是 tokenize + HTTP 开销
- **并发**：`排队等` 持续 > 0 才是真的过载信号（**现在一直是 0**）

### 出处（两份互证）

1. `k8s/live/README.md` 的「一个必须知道的坑」一节
2. `k8s/live/60-grafana-dashboards.yaml` 里 `embed.json` 面板的 `content` 注释
   （dashboard JSON 里的 Markdown 文本面板，随仪表盘一起分发 —— 看板的人
   不用翻仓库就知道为什么这么算）

---

## 三、另一个坑：修掉的失效指标名

vLLM 0.30 给 TPOT 指标**加了 `request_` 前缀**：

```
time_per_output_token_seconds  →  request_time_per_output_token_seconds
```

旧名字查不到数据 → **TPOT 面板一直是空的**（不是错，是空 —— 更难发现）。
2026-10-08 一并修掉。

> 教训：**升级 vLLM 后要重新核对指标名**。面板"空着"和"报错"是两种不同的
> 失败模式，前者不会有人报警。

---

## 四、两份 CM 曾经都不在仓库里 → 监控空转了两天

`prometheus-config` 这份 CM 是**12 天前用一次性脚本建到集群里**的，仓库里没有。
它里面的抓取目标是：

```
vllm-qwen.default.svc.cluster.local:8000     ← 服务早已不存在 → target DOWN
llama-qwen.default.svc.cluster.local:8000    ← 服务早已不存在 → target DOWN
```

结果：跑了两天的 `vllm-march7` 和刚上线的 `vllm-embed`
**一条指标都没被采集**，Grafana 上的 vLLM 曲线一直是空的。

这正是 `k8s/live/README.md` 开头记过的「CM 不在仓库 → 漂移无人知」那个坑，
**第二次踩**。现已把 `prometheus-config` 和 `grafana-dashboard-vllm`
两份 CM 都导出进 `k8s/live/` 纳管。

---

## 五、改完这两份 CM 之后要做什么（不一样！）

| CM | 生效方式 |
|---|---|
| **Prometheus** | ⚠️ **必须手动 reload**（apply 不会重启 pod）：<br>`curl -X POST http://<WSL-IP>:30090/-/reload`<br>然后到 `http://<WSL-IP>:30090/targets` 确认 target 都是 UP<br>（Prometheus 启动参数里有 `--web.enable-lifecycle`，所以 reload 可用） |
| **Grafana** | 不用管 —— file provider 的 `updateIntervalSeconds: 10` 会自己重载<br>（但要等 kubelet 把新 CM 同步到挂载卷，默认 ~60s） |

⚠️ `deploy.sh` 的「CM 变了自动重启」逻辑**只认目标 Deployment 引用的 CM**。
这两份 CM 不属于 `vllm-march7` / `vllm-embed` 任何一方，**所以不会被自动处理**。

---

## 六、现存缺口（诚实写出来）

| 缺口 | 后果 | 想补的话 |
|---|---|---|
| **Prometheus 用 emptyDir，无持久化** | **重启丢 24h 数据** | 建 PVC + `--storage.tsdb.path` 指向它 |
| **无告警规则** | 只有面板，没有 `alertmanager` —— 出问题要人去看 | 加 `alert.rules` + Alertmanager |
| **无日志采集栈** | 没有 Loki/ELK，历史日志只在容器 ring buffer 里，pod 一删就没了 | Loki + promtail |
| **GPU 指标走 nvidia-smi exporter，不是 DCGM** | **DCGM 官方不支持 WSL2**；进程级显存拿不到 | 只能在原生 Linux 上换 DCGM |
| **无 tracing** | 只有指标和日志，没有 span | OTel + Tempo/Jaeger |

> ⚠️ 特别说明 **WSL2 上拿不到逐进程显存**：`nvidia-smi` 能列进程但显存列永远是
> `N/A`；`/proc/<pid>/fdinfo` 没有 dxg 账；cgroup 里没有 GPU 计量。
> **唯一可靠办法是差分测量**（停一个测一个）：
>
> ```
> 两个服务总计   7236 MiB 已用 /  915 MiB 空闲
>   vllm-march7  6543 MiB      ← 停掉 embed 后测
>   vllm-embed    693 MiB      ← 基线 − march7
> ```
