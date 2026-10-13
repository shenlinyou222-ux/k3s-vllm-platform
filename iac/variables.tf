# ══════════════════════════════════════════════════════════════════════
#  iac/variables.tf —— 所有可调参数
# ══════════════════════════════════════════════════════════════════════

# ── 连接 ──────────────────────────────────────────────────────────────
variable "kubeconfig_path" {
  description = "kubeconfig 路径。k3s 默认在 /etc/rancher/k3s/k3s.yaml（root 所有），建议先复制到 ~/.kube/config"
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "kubeconfig 里的 context 名。k3s 默认是 default"
  type        = string
  default     = "default"
}

# ── 部署目标 ──────────────────────────────────────────────────────────
variable "namespace" {
  description = "部署到哪个 namespace"
  type        = string
  default     = "default"
}

variable "release_name" {
  description = "Helm release 名"
  type        = string
  default     = "vllm-stack"
}

variable "chart_path" {
  description = "Helm chart 路径（相对 iac/ 目录）"
  type        = string
  default     = "../charts/vllm-stack"
}

variable "values_files" {
  description = "要叠加的 values 文件（按顺序覆盖）。留空则只用 chart 默认值"
  type        = list(string)
  default     = []
}

# ── 模型与显存 ────────────────────────────────────────────────────────
variable "gen_model" {
  description = "生成式模型在容器内的路径（/models/<目录名>）"
  type        = string
  default     = "/models/Qwen3.5-2B-March7-cn"
}

variable "embed_model" {
  description = "向量模型路径"
  type        = string
  default     = "/models/dmeta-embedding-zh-small"
}

variable "gen_gpu_memory_utilization" {
  description = "生成服务的显存占比"
  type        = number
  default     = 0.55

  validation {
    condition     = var.gen_gpu_memory_utilization > 0 && var.gen_gpu_memory_utilization < 1
    error_message = "显存占比必须在 (0, 1) 之间。"
  }
}

variable "embed_gpu_memory_utilization" {
  description = "向量服务的显存占比"
  type        = number
  default     = 0.15
}

# ⭐ 这条校验是「用代码表达运维纪律」的例子：
#    两个服务的显存之和超 1.0 会在运行期 OOM，但 k8s 不会拦你。
#    放在 plan 阶段拦下来，比上线后排查便宜得多。
variable "assert_gpu_budget" {
  description = "是否在 plan 阶段校验 gen+embed 显存之和 < 1.0"
  type        = bool
  default     = true
}

# ── 存储 ──────────────────────────────────────────────────────────────
variable "models_host_path" {
  description = "宿主机上模型权重的目录"
  type        = string
  default     = "/home/user/npc-models"
}

variable "models_storage_size" {
  description = "PVC 声明容量"
  type        = string
  default     = "50Gi"
}

# ── 开关 ──────────────────────────────────────────────────────────────
variable "enable_gen" {
  description = "是否部署生成式 LLM 服务"
  type        = bool
  default     = true
}

variable "enable_embed" {
  description = "是否部署向量服务"
  type        = bool
  default     = true
}

variable "enable_asr" {
  description = "是否部署 ASR 服务"
  type        = bool
  default     = true
}

variable "enable_device_plugin" {
  description = "是否部署 NVIDIA device plugin"
  type        = bool
  default     = true
}

variable "device_plugin_node" {
  description = "device plugin 绑定的节点名（留空则用 DaemonSet 默认全节点）"
  type        = string
  default     = ""
}

variable "time_slicing_replicas" {
  description = "单卡 timeSlicing 成几份"
  type        = number
  default     = 4
}

variable "helm_timeout_seconds" {
  description = "Helm 部署超时（vLLM 首次加载模型可能很久）"
  type        = number
  default     = 900
}
