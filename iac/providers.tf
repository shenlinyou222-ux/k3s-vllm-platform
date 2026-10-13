# ══════════════════════════════════════════════════════════════════════
#  iac/providers.tf —— kubernetes / helm provider 配置
# ══════════════════════════════════════════════════════════════════════

provider "kubernetes" {
  config_path    = pathexpand(var.kubeconfig_path)
  config_context = var.kube_context
}

provider "helm" {
  kubernetes {
    config_path    = pathexpand(var.kubeconfig_path)
    config_context = var.kube_context
  }
}

# ── 部署前置检查 ──────────────────────────────────────────────────────
# 在真正 apply 之前先确认集群可达 —— 否则 helm_release 会等到超时才报错，
# 错误信息还很难看懂（"context deadline exceeded"）。
data "kubernetes_namespace" "target" {
  metadata {
    name = var.namespace
  }
}
