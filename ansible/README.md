# `ansible/` —— 主机层配置管理

> Helm 和 Terraform 都够不到的那一层：装包、写文件、装 k3s、确认 WSL2 的 GPU 直通真的存在。

---

## 为什么需要这一层

k8s 的声明式模型有个边界：**它只管 API 对象，不管宿主机**。

| 这些东西 | Helm 能管吗 | 为什么 |
|---|---|---|
| `/dev/dxg` 是否存在 | ❌ | 它是 WSL2 的设备节点，不在 k8s API 里 |
| `/usr/lib/wsl/lib` 里的 CUDA 驱动库 | ❌ | 同上 |
| k3s 有没有装 | ❌ | 它是 k8s 本身的运行时 |
| `~/.kube/config` 权限对不对 | ❌ | 宿主机文件 |
| 模型权重目录属主 | ⚠️ 部分 | PV 的 `hostPath` 指向它，但目录本身要预先存在 |

**Ansible 负责把「k3s 之前」的一切准备好**，让 Terraform 和 Helm 有个可落地的地基。

---

## 四个角色

| 角色 | 管什么 | 关键点 |
|---|---|---|
| `common` | 基础包、`~/.local/bin` 进 PATH | 全部用幂等模块（`apt` / `file` / `lineinfile`） |
| `nvidia_wsl` | **WSL2 GPU 直通检查** | 检查 `/dev/dxg`、`libcuda.so.1`、`libnvidia-ml.so.1` 三个路径 |
| `k3s` | 安装 k3s、准备 kubeconfig、报告 NodePort 占用 | `--disable=traefik,servicelb`（单节点上会和 NodePort 抢端口） |
| `vllm_host` | 模型目录、属主、权重指纹、**NodePort 冲突预检**、装 helm | 属主必须对（Pod 里 `fsGroup: 1000`） |

---

## ⭐ 两个「用代码表达运维知识」的地方

### 1. WSL2 GPU 直通的三个前提（`nvidia_wsl`）

原生 Linux 上 GPU 是 `/dev/nvidia0`，**WSL2 完全不是**：

```
/dev/dxg                             ← WSL 的 GPU 直通设备
/usr/lib/wsl/lib/libcuda.so.1        ← Windows 驱动提供的 CUDA 运行时
/usr/lib/wsl/lib/libnvidia-ml.so.1   ← NVML（nvidia-smi 与 device plugin 都依赖它）
```

这三个缺任何一个，`nvidia.com/gpu` 在 k8s 里就一直是 0 —— **而且没有任何报错**。
（chart 的 `device-plugin.yaml` 里那三个 `volumeMounts` 就是为此而挂的。）

角色会：
- 逐个 `stat` 检查存在性
- 不完整时**打印排查顺序**而不是直接失败（因为可能只是没重装 WSL）
- 在完整时确保 `/usr/lib/wsl/lib` 权限可读

### 2. NodePort 冲突预检（`vllm_host`）

三个服务要占 `30800/30801/30802/30803`。如果被占，`helm install` 会失败在
`nodePort already allocated` —— 这个报错信息不告诉你**是谁占的**。

角色在装 helm 之前先用 `ss -ltn` 扫一遍，把占用情况提前报出来。

> 这条来自真实踩坑：本栈历史上 `30030 30080 30090 30097 30500 30800 30801 30871` 都被占过。

---

## 用法

```bash
cd ansible

# 语法检查
ansible-playbook site.yml --syntax-check

# 看会执行哪些 task
ansible-playbook site.yml --list-tasks

# dry-run（改了什么会显示 diff）
ansible-playbook site.yml --check --diff

# 真正执行
ansible-playbook site.yml

# 只跑某一类
ansible-playbook site.yml --tags gpu        # 只检查 GPU 直通
ansible-playbook site.yml --tags models     # 只处理模型目录
```

> ⚠️ **已知限制**：本目录在 `/mnt/e/`（NTFS 挂载，world-writable），
> Ansible 会拒绝把这里的 `ansible.cfg` 当配置源（安全策略）。
> 所以要么显式传 `-i inventory.ini`，要么把仓库放到 Linux 原生路径下。
> 这是 WSL + NTFS 组合的固有问题，不是配置错误。

---

## 目录

```
ansible/
├── ansible.cfg
├── inventory.ini              单机（localhost，local connection）
├── site.yml                   入口 playbook
├── group_vars/all.yml         全部变量
└── roles/
    ├── common/tasks/main.yml
    ├── nvidia_wsl/tasks/main.yml
    ├── k3s/tasks/main.yml
    ├── k3s/handlers/main.yml
    └── vllm_host/tasks/main.yml
```

---

## 已验证状态（2026-10-12）

```
$ ansible --version
ansible [core 2.21.5]

$ ansible-playbook site.yml -i inventory.ini --syntax-check
playbook: site.yml
（exit 0）

$ ansible-playbook site.yml -i inventory.ini --list-tasks
play #1 (vllm_hosts): 准备 k3s GPU 推理主机
  33 个 task，分属 common / nvidia_wsl / k3s / vllm_host 四个角色
```

> 过程中 `syntax-check` 抓到过一个真 bug：
> `INSTALL_K3S_EXEC` 里用了 `'--disable=\1'` —— `\1` 在 YAML 双引号串中是**非法转义**。
> 改成 `map('regex_replace', '^', '--disable=')`（零宽匹配加前缀，不需要反引用）。
> **这就是 `--syntax-check` 的价值**：它在真跑之前就拦下了。
