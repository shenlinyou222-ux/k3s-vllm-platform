# ══════════════════════════════════════════════════════════════════════
#  iac/versions.tf —— provider 与版本约束
#
#  ⚠️ Terraform 与 OpenTofu 都能跑这份配置：
#     terraform init   （HashiCorp，MPL→BUSL 后仍有 CLI）
#     tofu init        （OpenTofu，Linux 基金会 fork，MPL 保持）
#  两者共用同一套 provider 协议，所以 required_providers 写法一致。
# ══════════════════════════════════════════════════════════════════════

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }

  # ── state 后端 ────────────────────────────────────────────────────
  # 默认用本地 state（单机自建场景足够）。
  # 生产/多人协作应换成远端后端，例如：
  #
  # backend "s3" {
  #   bucket = "tfstate-vllm-stack"
  #   key    = "k3s/vllm-stack.tfstate"
  #   region = "us-east-1"
  #   # 本地可用 MinIO：endpoints = { s3 = "http://127.0.0.1:9000" }
  #   #              skip_credentials_validation = true
  #   #              skip_metadata_api_check     = true
  #   #              force_path_style            = true
  # }
  #
  # ⚠️ state 里有敏感值（模型路径、密钥），后端要加密 + 加锁。
  #    S3 后端用 DynamoDB 表做锁；MinIO 用 --lock-table 或 etcd。
}
