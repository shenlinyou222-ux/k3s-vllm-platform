# ══════════════════════════════════════════════════════════════════════
#  iac/outputs.tf
# ══════════════════════════════════════════════════════════════════════

output "release_name" {
  description = "Helm release 名"
  value       = helm_release.vllm_stack.name
}

output "release_version" {
  description = "当前 revision（helm rollback 用这个回退）"
  value       = helm_release.vllm_stack.version
}

output "namespace" {
  description = "部署的 namespace"
  value       = helm_release.vllm_stack.namespace
}

output "gpu_budget" {
  description = "显存预算核算"
  # round 到 2 位，避免浮点噪声（0.55+0.15 会算出 0.7000000000000001）
  value = {
    gen      = var.gen_gpu_memory_utilization
    embed    = var.enable_embed ? var.embed_gpu_memory_utilization : 0
    total    = round(var.gen_gpu_memory_utilization + (var.enable_embed ? var.embed_gpu_memory_utilization : 0), 2)
    headroom = round(1.0 - (var.gen_gpu_memory_utilization + (var.enable_embed ? var.embed_gpu_memory_utilization : 0)), 2)
  }
}

# ⚠️ 这条是有意为之的提醒：Windows 访问 k3s 的 NodePort 必须用 WSL IP，
#    用 127.0.0.1 会超时（NodePort 走 iptables DNAT，不产生 listen socket，
#    WSL2 的 localhostForwarding 看不到）。
output "access_hint" {
  description = "怎么访问服务"
  value       = <<-EOT
    1. 取 WSL IP：   wsl -d Ubuntu-24.04 -- hostname -I
    2. 生成式 LLM：  http://<WSL-IP>:30800/v1/chat/completions
    3. 向量服务：    http://<WSL-IP>:30802/v1/embeddings
    4. ASR：         http://<WSL-IP>:30803
    ⚠️ 不要用 127.0.0.1 —— NodePort 走 iptables DNAT，不产生 listen socket。
  EOT
}

output "next_steps" {
  description = "部署后的常用命令"
  value       = <<-EOT
    # 看状态
    kubectl -n ${var.namespace} get deploy,svc,pvc
    # 看显存
    nvidia-smi
    # 回滚
    helm rollback ${var.release_name} -n ${var.namespace}
    # 销毁（PV 是 Retain，模型权重不会删）
    tofu destroy    # 或 terraform destroy
  EOT
}
