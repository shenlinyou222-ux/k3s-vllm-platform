# ══════════════════════════════════════════════════════════════════════
#  iac/main.tf —— 用 Terraform 定义整个推理栈
#
#  设计取舍（面试会问「为什么这么切」）：
#    ① 基础设施（PV/PVC/StorageClass/device plugin）与工作负载（vLLM）
#       都交给 Helm chart 管，Terraform 只负责「装 chart + 传参」。
#       理由：这些资源有强内聚（改显存占比要同时改 Deployment 和探针），
#       拆到两层反而让 diff 变碎。
#    ② Terraform 管的是「生命周期与状态」：谁创建、依赖顺序、销毁边界。
#       它的独特价值在于 **plan** —— 能在 apply 前看到将要发生什么。
#    ③ 显存预算校验放在 plan 阶段（见 precondition），运行期 OOM 太贵。
# ══════════════════════════════════════════════════════════════════════

locals {
  # 把变量收成一个 map 传给 chart，避免在 helm_release 里写十几段 set {}
  chart_values = {
    "global.namespace" = var.namespace

    "storage.hostPath" = var.models_host_path
    "storage.size"     = var.models_storage_size

    "gen.enabled"              = var.enable_gen
    "gen.model"                = var.gen_model
    "gen.gpuMemoryUtilization" = var.gen_gpu_memory_utilization

    "embed.enabled"              = var.enable_embed
    "embed.model"                = var.embed_model
    "embed.gpuMemoryUtilization" = var.embed_gpu_memory_utilization

    "asr.enabled" = var.enable_asr

    "devicePlugin.enabled"             = var.enable_device_plugin
    "devicePlugin.nodeName"            = var.device_plugin_node
    "devicePlugin.timeSlicingReplicas" = var.time_slicing_replicas
  }
}

# ── ⭐ plan 阶段的运维纪律校验 ────────────────────────────────────────
# 两个推理服务共享一块 GPU，显存占比之和必须 < 1.0。
# k8s 不会拦你 —— 它只按 nvidia.com/gpu 计数调度，不管显存实际占用。
# 超了就是运行期 OOMKilled，排查成本远高于在 plan 阶段拦下。
resource "null_resource" "gpu_budget_guard" {
  count = var.assert_gpu_budget && var.enable_gen && var.enable_embed ? 1 : 0

  lifecycle {
    precondition {
      condition = (var.gen_gpu_memory_utilization + var.embed_gpu_memory_utilization) < 1.0
      error_message = format(
        "GPU 显存预算超了：gen(%.2f) + embed(%.2f) = %.2f，必须 < 1.0。请下调其中一个。",
        var.gen_gpu_memory_utilization,
        var.embed_gpu_memory_utilization,
        var.gen_gpu_memory_utilization + var.embed_gpu_memory_utilization
      )
    }
  }
}

# ── Helm release ──────────────────────────────────────────────────────
resource "helm_release" "vllm_stack" {
  name      = var.release_name
  chart     = var.chart_path
  namespace = var.namespace

  # 等所有资源就绪再算成功 —— vLLM 首次加载模型慢，超时给足
  wait          = true
  wait_for_jobs = true
  timeout       = var.helm_timeout_seconds

  # atomic：失败自动回滚到上一个成功的 revision。
  # 与 k3s-vllm-platform 里 CI 流水线的「失败自动回滚」是同一套思路，
  # 区别是这里由 Helm 保证，不需要自己写 rollout undo。
  atomic          = true
  cleanup_on_fail = true

  # values 叠加顺序：先默认值，再逐个文件覆盖，最后 set 覆盖
  values = var.values_files

  dynamic "set" {
    for_each = local.chart_values
    content {
      name  = set.key
      value = tostring(set.value)
    }
  }

  depends_on = [null_resource.gpu_budget_guard]
}
