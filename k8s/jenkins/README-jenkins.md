# Jenkins CI/CD —— 部署与使用

> 目标：**改代码 → 自动构建 → 自动部署 → 自动验证 → 失败自动回滚**
> 账号**脚本化创建**，不用人工注册。

---

## 一、部署顺序（6 步，全是 kubectl apply）

```bash
cd /srv/k3s-vllm-platform

# ① Namespace（拆出来是为了让 dry-run 能通过）
kubectl apply -f k8s/jenkins-namespace.yaml

# ② 管理员密码（改这里就改密码）
kubectl apply -f k8s/jenkins-secret.yaml

# ③ JCasC 配置（账号 + k8s cloud + agent pod 模板）
kubectl apply -f k8s/jenkins-casc.yaml

# ④ Agent Pod 用的 SA + RBAC
kubectl apply -f k8s/jenkins-agent-rbac.yaml

# ⑤ Controller（派生镜像，插件已预装）
kubectl apply -f k8s/jenkins.yaml

# ⑥ 两个镜像（如果还没构建）
bash _build-jenkins-images.sh
```

**等就绪：**
```bash
kubectl -n cicd rollout status deploy/jenkins --timeout=600s
```

---

## 二、登录

```
URL:   http://<WSL-IP>:30080
       （WSL-IP 用 hostname -I 取；Windows 侧不能用 localhost）
用户:  ops
密码:  kubectl -n cicd get secret jenkins-auth -o jsonpath='{.data.admin-password}' | base64 -d
```

**密码**：仓库里只有 `REPLACE_ME_JENKINS_ADMIN_PASSWORD` 占位符 —— 真值在
`k8s/jenkins/jenkins-secret.yaml` 里改。

> ⚠️ **公开版脱敏**：原工作仓库里这个位置写过明文默认密码，本仓库已替换为占位符。
> 真值请自己填，并且**不要 commit** —— 见 `jenkins-secret.yaml` 顶部给出的三种做法
> （gitignore / SealedSecret / 外部 KMS）。

**验证登录（不开浏览器）：**
```bash
PW=$(kubectl -n cicd get secret jenkins-auth -o jsonpath='{.data.admin-password}' | base64 -d)
curl -s -u "ops:$PW" "http://$(hostname -I | awk '{print $1}'):30080/whoAmI/api/json"
# 应输出 {"name":"ops","authenticated":true,...}
```

---

## 三、⭐ 账号怎么建的（不用人工注册）

`k8s/jenkins-casc.yaml` 里声明：

```yaml
jenkins:
  securityRealm:
    local:
      allowsSignup: false          # 禁止自助注册
      users:
      - id: "ops"
        password: "${JENKINS_ADMIN_PASSWORD}"   # 从 Secret 注入
  authorizationStrategy:
    loggedInUsersCanDoAnything:
      allowAnonymousRead: false
```

**⇒ Jenkins 启动时 JCasC 自动 reconcile → 账号就建好了。**

**⭐ 每次启动都会对齐** —— 在 UI 里改乱了，重启就恢复成配置里的样子。

---

## 四、⭐ Agent 怎么来的（不用人工拿 secret）

**传统做法**：手动建一个常驻 Agent 节点 → 去 UI 里拿 `JENKINS_SECRET` → 填进 manifest。
**我们的做法**：用 **Kubernetes 插件动态创建 agent pod** —— 每个 build 一个，用完就删。

`casc.yaml` 里声明：

```yaml
jenkins:
  clouds:
  - kubernetes:
      name: "k8s"
      serverUrl: "https://kubernetes.default.svc"
      namespace: "cicd"
      templates:
      - name: "wsl-docker"
        label: "wsl-docker"              # Jenkinsfile 里 agent { label 'wsl-docker' }
        serviceAccount: "jenkins-agent"  # 用 SA → kubectl 在 pod 里能访问集群
        podRetention: "never"            # build 完立刻删
        volumes:
        - hostPathVolume:                # ① 宿主 docker（构建用）
            hostPath: "/var/run/docker.sock"
            mountPath: "/var/run/docker.sock"
        - hostPathVolume:                # ② 宿主工作区（临时排查用，流水线不读它）
            hostPath: "/srv/k3s-vllm-platform"
            mountPath: "/srv/k3s-vllm-platform"
        - hostPathVolume:                # ③ ⭐ 裸仓库 = SCM 源（checkout scm 在 agent 里跑！）
            hostPath: "/srv/k3s-vllm-platform.git"
            mountPath: "/srv/k3s-vllm-platform.git"
        containers:
        - name: "jnlp"
          image: "dsh/jenkins-agent:1.1"   # 1.1 = 1.0 + safe.directory（见下）
```

**⇒ 不用预先跑常驻 agent，也不用人工拿 secret。**

---

## 五、流水线怎么跑

### 手工跑（现在就能用）

```bash
cd /srv/k3s-vllm-platform
git add -A && git commit -m "改了什么"

./ci/scripts/precheck.sh        # 看 diff，人工确认
./ci/scripts/deploy.sh
./ci/scripts/verify.sh

# 或一键
./ci/scripts/pipeline.sh

# 改了 ConfigMap
./ci/scripts/pipeline.sh --restart-only

# 出问题
./ci/scripts/rollback.sh
```

### 通过 Jenkins 跑（已上线，见 `scripts/ci/README.md`）

**日常用法：改 `k8s/live/` 里的文件 → `git commit` → `git push` → 自动部署。**
Jenkins 每 2 分钟轮询 origin（裸仓库 `/srv/k3s-vllm-platform.git`），
有新提交就自动构建。

Job 的关键配置（`vllm-platform-deploy`）：

| 项 | 值 |
|---|---|
| SCM url | `file:///srv/k3s-vllm-platform.git`（裸仓库 = git origin） |
| 分支 | `*/main` |
| Script Path | `ci/Jenkinsfile`（⚠️ 本抽取仓库把它放在 `ci/` 下；原工作仓库在根目录） |
| 触发器 | `pollSCM`（Jenkinsfile 里声明，每 2 分钟） |
| 挂载 | 裸仓库必须同时挂给 **Controller 和 agent** —— `checkout scm` 是在 agent pod 里执行的 |

**参数**（手动构建时才用；自动触发走 full 的语义）：

| 参数 | 说明 |
|---|---|
| `MODE` | `full` 完整发布 / `restart-only` 只重启 / `dry` 只预检 |
| `SKIP_VERIFY` | 跳过验证（不推荐） |
| `BENCH_MIN` | 性能门槛 tok/s |

**⭐ 部署源是 SCM 检出，不是宿主工作区** —— 脚本靠 `BASH_SOURCE` 自己定位代码根，
产物（state / 备份）则固定写到 `CI_ARTIFACT_DIR`（宿主，因为 agent 的 workspace
用完会被 `cleanWs()` 清掉）。

---

## 六、⚠️ 今天踩的 3 个坑（都会让你卡住）

### 坑 1：官方镜像不会自动装插件

```
现象：pod Running，但插件 0 个 → JCasC 完全没生效 → ops 用户建不出来
根因：/usr/share/jenkins/ref/plugins.txt 是给【派生镜像构建期】用的机制，
      官方 jenkins/jenkins 镜像启动时【不会】读它
修复：派生镜像 + jenkins-plugin-cli（见 _build-jenkins-images.sh）
```

### 坑 2：JCasC 属性名写错 → Jenkins 完全起不来

```
现象：CrashLoopBackOff，日志里是 Jetty 优雅关闭的堆栈（看不出原因）
根因：casc.yaml 里写 mailer.address，正确的是 mailer.emailAddress
      → UnknownAttributesException → ConfigurationAsCodeBootFailure
      → Jenkins 启动失败 → 容器退出
修复：address → emailAddress
排查手法：kubectl logs deploy/jenkins | head -50   ← 看【开头】，不是尾部
```

### 坑 3：Alpine vs Debian 的构建速度差 100 倍

```
Debian (jenkins/inbound-agent) + apt-get 装 git/python3/docker-cli
  → 下载 100+ MB，卡了 10 分钟没动
Alpine (jenkins/inbound-agent:alpine) + apk 装同样的工具
  → 4.5 秒完成
```

---

## 七、故障速查

| 症状 | 原因 | 处理 |
|---|---|---|
| CrashLoopBackOff | JCasC 报错（看日志**开头**） | `kubectl logs deploy/jenkins \| head -50` |
| 插件 0 个 | 用了官方镜像 | 换成 `dsh/jenkins:1.0` |
| 登不进去 | 密码不对 / JCasC 没生效 | 从 Secret 重新取密码；确认 `users/` 目录存在 |
| Agent 起不来 | 镜像没构建 / hostPath 不对 | `docker images \| grep jenkins-agent` |
| 构建慢（几小时） | 没用宿主 docker.sock | 检查 agent pod 的 volume 挂载 |
| UI 打不开（Windows） | 用了 localhost | 用 WSL IP（`hostname -I`） |

---

## 八、对象清单

| 对象 | 作用 |
|---|---|
| `ns/cicd` | 命名空间 |
| `secret/jenkins-auth` | 管理员密码 |
| `cm/jenkins-casc` | JCasC 配置（账号 + k8s cloud + pod 模板） |
| `cm/jenkins-plugins` | **插件清单的文档**（不再挂载，插件已烘进镜像） |
| `sa/jenkins-controller` + Role/RoleBinding | Controller 创建 agent pod 的权限 |
| `sa/jenkins-agent` + ClusterRoleBinding | agent pod 操作集群的权限 |
| `pvc/jenkins-home` | JENKINS_HOME（10Gi，`local-path-retain`） |
| `deploy/jenkins` | Controller |
| `svc/jenkins` | NodePort 30080（UI）/ 30500（agent 隧道） |
| 镜像 `dsh/jenkins:1.0` | Controller（86 个插件预装） |
| 镜像 `dsh/jenkins-agent:1.1` | Agent（docker/kubectl/git/python3/jq/envsubst）+ `safe.directory=*` |
