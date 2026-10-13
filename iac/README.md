# `iac/` —— 用 Terraform / OpenTofu 定义整个推理栈

> 把「手敲 `kubectl apply -f k8s/live/`」升级成「`terraform plan` 先看会发生什么，再 `apply`」。

---

## 三层职责划分（面试会问「为什么这么切」）

| 层 | 工具 | 管什么 | 为什么不能换 |
|---|---|---|---|
| **主机层** | [Ansible](../ansible/) | 装包、写文件、装 k3s、校验 WSL2 GPU 直通 | 这些**不在 k8s API 里** —— Helm 看不到也管不了 `/dev/dxg` 是否存在 |
| **编排层** | Terraform / OpenTofu | release 生命周期、依赖顺序、`plan` 预演、销毁边界 | Helm 自己**没有 dry-run 对比**（`--dry-run` 只渲染，不比对集群现状）；TF 会告诉你「相对当前集群要改什么」 |
| **资源层** | [Helm chart](../charts/vllm-stack/) | Deployment / Service / PV / PVC / ConfigMap 的实际内容 | 这些资源强内聚（改显存占比要同时动 Deployment 和探针），拆两层会让 diff 变碎 |

**一句话**：Ansible 管机器，Terraform 管生命周期，Helm 管资源内容。

---

## 为什么 Terraform 和 OpenTofu 都能跑

两者共用同一套 provider 协议与 HCL 语法，`required_providers` 写法完全一致：

```bash
terraform init && terraform validate   # HashiCorp（releases.hashicorp.com）
tofu init      && tofu validate        # OpenTofu（registry.opentofu.org → 转发 GitHub）
```

> ⚠️ **实测差异（2026-10-12）**：本机网络下 OpenTofu 拉 `hashicorp/kubernetes` provider 会超时 ——
> 它的 registry 把 provider 二进制转发到 **GitHub releases**，而 GitHub 在当前网络下不稳定；
> Terraform 直接从 `releases.hashicorp.com` 拉，可达。
> 功能上两者等价，选哪个看网络。

---

## 快速开始

```bash
cd iac
terraform init

# ① 先看要改什么（最重要的一步）
terraform plan

# ② 确认无误再应用
terraform apply

# ③ 看输出（含显存预算核算与访问方式）
terraform output
```

### 常用变量

```bash
# 换生成模型
terraform apply -var 'gen_model=/models/Qwen3.5-2B-March8-cn'

# 用 values 文件叠加配置
terraform apply -var 'values_files=["../charts/vllm-stack/values-prod.yaml"]'

# 只部署向量服务
terraform apply -var 'enable_gen=false'

# 关闭 GPU 预算守卫（不推荐，仅调试用）
terraform apply -var 'assert_gpu_budget=false'
```

---

## ⭐ plan 阶段的运维纪律校验（这个项目的重点）

### 问题

生成服务与向量服务**共享同一块 GPU**，靠 `--gpu-memory-utilization` 各占一份：

```
gen   = 0.55
embed = 0.15
合计   = 0.70，留 30% 余量
```

**但 k8s 不会拦你。** 它只按 `nvidia.com/gpu` 计数调度（本栈用 timeSlicing 把单卡 advertise 成 4 份），
**完全不看显存实际占用**。两个 Pod 都拿到 1 个 GPU 计数 → 双双被调度 → 显存超了 → **运行期 OOMKilled**。

这类故障排查成本很高：Pod 反复重启、日志里只有 `CUDA out of memory`、看不出是谁挤了谁。

### 解法

用 Terraform 的 `precondition` 把纪律表达成**代码**，在 `plan` 阶段就拦下来：

```hcl
resource "null_resource" "gpu_budget_guard" {
  lifecycle {
    precondition {
      condition = (var.gen_gpu_memory_utilization + var.embed_gpu_memory_utilization) < 1.0
      error_message = format(
        "GPU 显存预算超了：gen(%.2f) + embed(%.2f) = %.2f，必须 < 1.0。请下调其中一个。",
        ...)
    }
  }
}
```

### 实测（三个场景都验过）

| 场景 | gen + embed | 结果 |
|---|---|---|
| 正常 | 0.55 + 0.15 = **0.70** | `Plan: 2 to add, 0 to change, 0 to destroy.` |
| 超额 | 0.90 + 0.15 = **1.05** | `Error: Resource precondition failed`<br>`GPU 显存预算超了：gen(0.90) + embed(0.15) = 1.05，必须 < 1.0。请下调其中一个。` |
| 边界 | 0.84 + 0.15 = **0.99** | `Plan: 2 to add, 0 to change, 0 to destroy.` |

**为什么放在 plan 而不是写个文档规定**：文档会被忽略，`plan` 不会。
把「不能这么配」变成「配了就跑不起来」，是 IaC 相对 YAML 清单最实在的增量。

---

## 与 CI 流水线的关系

本仓库原有的 CI（`ci/scripts/pipeline.sh`）做的是**部署后**的验证：
三层发布判据（日志 / 功能 / 性能）+ 权重指纹 + 失败自动回滚。

IaC 这一层做的是**部署前**的预防：

```
terraform plan  →  拦截配置错误（显存超预算、端口冲突）
      ↓
helm upgrade    →  atomic=true，失败自动回滚到上一个 revision
      ↓
CI 流水线       →  部署后三层判据 + 权重指纹校验
```

三层互补，不是替代关系。**部署前的拦截成本 < 部署后的回滚成本 < 上线后的故障成本。**

---

## state 管理

默认用本地 state（单机自建场景足够）。生产/多人协作要换远端后端：

```hcl
backend "s3" {
  bucket = "tfstate-vllm-stack"
  key    = "k3s/vllm-stack.tfstate"
  region = "us-east-1"
  # 本地 MinIO 也可：endpoints = { s3 = "http://127.0.0.1:9000" }
  #                skip_credentials_validation = true
  #                skip_metadata_api_check     = true
  #                force_path_style            = true
}
```

> ⚠️ state 里可能有敏感值，后端要**加密 + 加锁**（S3 用 DynamoDB 表做锁）。

---

## 目录

```
iac/
├── versions.tf               provider 与版本约束、backend 说明
├── providers.tf              kubernetes / helm provider + 集群可达性预检
├── variables.tf              全部可调参数（含 GPU 占比的范围校验）
├── main.tf                   GPU 预算守卫 + helm_release
├── outputs.tf                显存核算、访问方式、常用命令
└── .terraform.lock.hcl       provider 版本锁定（应进版本控制）
```

---

## 已验证状态（2026-10-12）

```
$ terraform init
Installing hashicorp/null v3.3.2 ...        Installed (signed by HashiCorp)
Installing hashicorp/kubernetes v2.38.0 ... Installed (signed by HashiCorp)
Installing hashicorp/helm v2.17.0 ...       Installed (signed by HashiCorp)
Terraform has been successfully initialized!

$ terraform validate
Success! The configuration is valid.

$ tofu fmt -check
（无输出 = 格式规范）

$ terraform plan
Plan: 2 to add, 0 to change, 0 to destroy.   ← 连的是真实 k3s 集群
```
