---
name: tencentcloud-cvm-skill
description: 腾讯云 CVM 云服务器运维工具集
version: 2.0.0
author: garden
tags: [tencent-cloud, cvm, devops, automation]
---

# 腾讯云 CVM 运维工具

基于 Bash + tccli 的腾讯云 CVM 云服务器运维工具集，支持**实例创建**、**资源查询**、**服务器运维**三大核心功能。

## 核心理念

**用户不需要学习任何云计算概念**。只需描述想做什么：

- 「我要搭一个电商网站，预计日活10万，大促期间可能翻5倍」
- 「我要跑一个AI推理服务，模型7B参数，要求P99延迟低于200ms」
- 「我要做一个视频转码平台，每天处理1万条短视频」

系统会自动完成：

1. **语义解析**：理解用户的业务场景、性能预期、成本敏感度
2. **需求建模**：将自然语言转化为结构化的资源需求模型
3. **方案生成**：在 CVM 各种资源配置中生成 3 级方案
4. **合规校验**：RunInstances DryRun 检查
5. **一键交付**：从下单到资源可用，全程无需人工干预

整个过程，用户只需要做两件事：**说清楚要什么**，然后**确认买单**。

### 输出模板

#### 方案推荐

```
根据你的需求「{用户需求描述}」，推荐以下方案：

| 方案 | 机型 | 配置 | 月费用 |
|------|------|------|--------|
| 极致性能 | {机型} | {CPU}核 {内存}G {磁盘}G | ¥{价格} |
| 均衡推荐 ✓ | {机型} | {CPU}核 {内存}G {磁盘}G | ¥{价格} |
| 经济节约 | {机型} | {CPU}核 {内存}G {磁盘}G | ¥{价格} |

请选择方案（1/2/3），或提出调整需求。
```

#### 实例创建成功

```
✅ 实例创建成功

| 项目 | 值 |
|------|-----|
| 实例ID | {instance_id} |
| 公网IP | {public_ip} |
| 内网IP | {private_ip} |
| 登录密码 | {password} |
| 地域 | {region} |
| 机型 | {instance_type} |

SSH 连接：ssh {user}@{public_ip}
```

#### 实例列表

```
共 {n} 台实例：

| 实例ID | 名称 | IP | 状态 | 机型 |
|--------|------|-----|------|------|
| {id} | {name} | {ip} | {status} | {type} |
```

#### 运维结果

```
📊 {操作名称} - {instance_id}

{结果内容，保持原始格式}
```

#### 操作确认

```
⚠️ 即将执行：{操作描述}

目标实例：{instance_id}（{name}）

确认执行？(y/n)
```

#### 错误提示

```
❌ {错误类型}：{错误信息}

建议：{解决方案}
```

## CVM 购买流程

### 按需求描述购买（推荐）

| 阶段 | 说明 |
|------|------|
| **阶段一：需求发起** | 用户输入云服务器购买需求（自然语言描述业务场景） |
| **阶段二：方案生成** | 输出 3 套推荐方案（极致性能 / 均衡推荐 / 经济节约） |
| **阶段三：方案调优** | 用户选定一套方案后，可进入方案调整（如更换操作系统等） |
| **阶段四：确认购买** | 确认方案后进行部署购买（RunInstances） |
| **阶段五：交付** | 部署完成后，展示资源概览 |

### 按配置过程购买

| 步骤 | 说明 |
|------|------|
| 1. 选计费模式 | 按量计费 / 包年包月 |
| 2. 选地域 | 选择实例所在地域 |
| 3. 选机型 | 选择实例规格 |
| 4. 选镜像 | 选择操作系统镜像 |
| 5. 其他参数 | 默认配置（可选调整） |
| 6. 确认配置购买 | 确认后执行 RunInstances |
| 7. 交付 | 部署完成，展示资源概览 |

## 快速开始

### 1. 安装依赖

```bash
# tccli（腾讯云命令行工具）
pip3 install tccli

# jq（JSON 解析）
brew install jq        # macOS
apt install jq         # Ubuntu

# sshpass（SSH 密码认证，运维操作需要）
brew install hudochenkov/sshpass/sshpass   # macOS
apt install sshpass                         # Ubuntu
```

### 2. 配置凭证

```bash
tccli configure set secretId YOUR_SECRET_ID
tccli configure set secretKey YOUR_SECRET_KEY
```

> 如果 tccli 未配置有效凭证，使用时会提示用户提供 SecretId 和 SecretKey。

### 3. 典型工作流

```bash
# 1. 查询资源准备创建实例
./scripts/query/describe-zones.sh                    # 查可用区
./scripts/query/describe-images.sh --platform Ubuntu # 查镜像
./scripts/query/describe-vpcs.sh                     # 查 VPC

# 2. 创建实例（密码自动保存）
./scripts/lifecycle/create-instance.sh \
  --zone ap-guangzhou-3 \
  --instance-type S5.MEDIUM2 \
  --image-id img-xxx \
  --vpc-id vpc-xxx \
  --subnet-id subnet-xxx \
  --sg-id sg-xxx

# 3. 更新实例 IP
./scripts/utils/update-instance-ip.sh --instance-id ins-xxx --auto

# 4. 运维操作（只需 instance-id）
./scripts/ops/ssh-connect.sh --instance-id ins-xxx
./scripts/ops/system-info.sh --instance-id ins-xxx
```

## 功能模块

```
scripts/
├── lifecycle/    # 实例生命周期：创建、启动、停止、重启、重装、销毁、镜像
├── query/        # 资源查询：实例、镜像、VPC、子网、安全组、可用区
├── ops/          # 服务器运维（SSH）：远程执行、系统信息、磁盘、进程、服务、日志、安全、传输、网络
├── tat/          # 自动化助手（TAT）：无需 SSH 的命令执行，支持批量和无公网实例
├── utils/        # 辅助工具：密码管理、IP 更新、配置查看
└── common.sh     # 公共函数库
```

### 实例生命周期

| 脚本 | 功能 | 示例 |
|------|------|------|
| `recommend-instance.sh` | 场景推荐创建 | `--scene blog-small` |
| `create-instance.sh` | 手动创建实例 | `--zone ap-guangzhou-3 --instance-type S5.MEDIUM2` |
| `start-instance.sh` | 启动实例 | `--instance-id ins-xxx` |
| `stop-instance.sh` | 停止实例 | `--instance-id ins-xxx [--force]` |
| `reboot-instance.sh` | 重启实例 | `--instance-id ins-xxx` |
| `reset-instance.sh` | 重装系统 | `--instance-id ins-xxx [--image-id img-xxx]` |
| `modify-instance-name.sh` | 修改实例名称 | `--instance-id ins-xxx --name "my-server"` |
| `create-image.sh` | 制作自定义镜像 | `--instance-id ins-xxx --image-name "backup"` |
| `terminate-instance.sh` | 销毁实例 | `--instance-id ins-xxx` |

#### 场景推荐

根据使用场景自动推荐配置，每个场景提供**三种方案对比**，并通过**询价接口获取实时价格**：

```bash
./scripts/lifecycle/recommend-instance.sh --scene ai-inference-medium  # AI 推理
./scripts/lifecycle/recommend-instance.sh --scene ecommerce-large      # 大型电商
./scripts/lifecycle/recommend-instance.sh --list-scenes                # 查看所有场景
```

**三级方案：**
- **极致性能方案**：不计成本，追求最优体验
- **均衡推荐方案**：性价比最优，适合大多数场景
- **经济节约方案**：在满足基本需求的前提下最大化成本节省

**推荐特性：**
- **AI 推荐理由**：基于场景特点给出专业的配置建议
- **实时询价**：调用腾讯云询价 API 获取准确价格
- **人工确认**：选择方案并确认后才创建实例

| 分类 | 场景 | 适用 |
|------|------|------|
| **基础建站** | `blog-small` | 个人博客 (日PV<5K) |
| | `blog-medium` | 中型博客 (日PV 5K-50K) |
| **Web 应用** | `web-small` | 小型 Web (日PV<10K) |
| | `web-medium` | 中型 Web (日PV 10K-100K) |
| | `web-large` | 大型 Web (日PV>100K) |
| **API 服务** | `api-small` | 小型 API (QPS<100) |
| | `api-medium` | 中型 API (QPS 100-1000) |
| | `api-large` | 大型 API (QPS>1000) |
| **AI 推理/训练** | `ai-inference-small` | 小型推理 (模型<3B) |
| | `ai-inference-medium` | 中型推理 (模型 3-13B) |
| | `ai-inference-large` | 大型推理集群 (模型>13B) |
| | `ai-training` | 模型训练/微调 |
| **电商平台** | `ecommerce-small` | 小型电商 (日订单<1K) |
| | `ecommerce-medium` | 中型电商 (日订单 1K-10K) |
| | `ecommerce-large` | 大型电商/大促 (日订单>10K) |
| **视频直播** | `video-transcode` | 视频转码服务 |
| | `live-streaming-small` | 小型直播 (<1K 并发) |
| | `live-streaming-medium` | 中型直播 (1K-10K 并发) |
| | `live-streaming-large` | 大型直播 (>10K 并发) |
| **游戏服务器** | `game-dev` | 游戏开发测试服 |
| | `game-small` | 小型游戏服 (<500 在线) |
| | `game-medium` | 中型游戏服 (500-5000 在线) |
| | `game-large` | 大型游戏服 (>5000 在线) |
| **物联网** | `iot-gateway` | IoT 网关/边缘计算 |
| | `iot-platform-small` | 小型 IoT (<10K 设备) |
| | `iot-platform-medium` | 中型 IoT (10K-100K 设备) |
| | `iot-platform-large` | 大型 IoT (>100K 设备) |
| **大数据** | `bigdata-node` | 计算节点 (Spark/Flink) |
| | `bigdata-storage` | 存储节点 (HDFS/HBase) |
| | `bigdata-master` | 集群主节点 |
| | `data-warehouse` | 数据仓库 (ClickHouse) |
| **金融交易** | `fintech-trading` | 交易系统 (低延迟) |
| | `fintech-risk` | 风控系统 |
| | `fintech-settlement` | 清算结算系统 |
| **数据库** | `database-small` | 小型数据库 (<10GB) |
| | `database-medium` | 中型数据库 (10-100GB) |
| | `database-large` | 大型数据库 (>100GB) |
| **通用** | `dev` | 开发测试环境 |

### 资源查询

| 脚本 | 功能 | 常用参数 |
|------|------|----------|
| `describe-regions.sh` | 查询地域 | `--available` |
| `describe-instances.sh` | 查询实例 | `--instance-id`, `--name` |
| `describe-instance-status.sh` | 查询实例状态 | `--instance-id` |
| `describe-zones.sh` | 查询可用区 | `--region` |
| `describe-instance-types.sh` | 查询机型 | `--zone`, `--family`, `--type` |
| `describe-images.sh` | 查询镜像 | `--instance-type`, `--platform` |
| `describe-vpcs.sh` | 查询 VPC | `--vpc-id` |
| `describe-subnets.sh` | 查询子网 | `--vpc-id`, `--zone` |
| `describe-security-groups.sh` | 查询安全组 | `--sg-id`, `--name` |

### 服务器运维

> **优先级策略**：运维操作优先使用 ops 脚本（SSH + 密码直连执行），仅在脚本无法满足需求时才使用 tccli 接口调用。
>
> **安全限制**：ops 目录仅使用已有的预定义脚本，不支持动态生成新脚本。
>
> **重要原则**：运维写操作（如停止、重启、销毁实例，服务管理，文件传输等）需要人工确认后执行。
>
> 所有运维脚本只需 `--instance-id` 即可自动获取密码和 IP

| 脚本 | 功能 | 特殊参数 |
|------|------|----------|
| `ssh-connect.sh` | SSH 连接 | `--port` |
| `remote-exec.sh` | 远程命令（仅支持预定义安全命令） | `--cmd <command>` |
| `system-info.sh` | 系统信息 | - |
| `disk-usage.sh` | 磁盘检查 | `--threshold <n>` |
| `process-monitor.sh` | 进程监控 | `--top <n>`, `--filter` |
| `service-manage.sh` | 服务管理 | `--service`, `--action` |
| `log-viewer.sh` | 日志查看 | `--file`, `--lines`, `--follow` |
| `security-check.sh` | 安全检查 | - |
| `file-transfer.sh` | 文件传输 | `--upload/--download`, `--local`, `--remote` |
| `network-check.sh` | 网络检查 | `--target` |

#### remote-exec 安全命令集

`remote-exec.sh` 仅支持以下预定义的只读命令或 ops 目录下的脚本：

| 分类 | 命令 | 用途 |
|------|------|------|
| **系统信息** | `uptime` | 系统运行时间和负载 |
| | `uname -a` | 内核和系统信息 |
| | `hostname` | 主机名 |
| | `cat /etc/os-release` | 操作系统版本 |
| | `date` | 系统时间 |
| | `timedatectl` | 时区和时间同步状态 |
| **CPU** | `cat /proc/loadavg` | 系统负载 |
| | `top -bn1 \| head -20` | CPU 和进程概览 |
| | `mpstat` | CPU 使用统计 |
| | `nproc` | CPU 核数 |
| | `lscpu` | CPU 详细信息 |
| **内存** | `free -h` | 内存使用情况 |
| | `cat /proc/meminfo` | 内存详细信息 |
| | `vmstat` | 虚拟内存统计 |
| **磁盘** | `df -h` | 磁盘使用情况 |
| | `df -i` | inode 使用情况 |
| | `lsblk` | 块设备列表 |
| | `fdisk -l` | 磁盘分区信息 |
| | `du -sh <path>` | 目录大小 |
| **进程** | `ps aux` | 进程列表 |
| | `ps aux \| head -20` | 前 20 个进程 |
| | `pgrep <name>` | 按名称查找进程 |
| | `pidof <name>` | 获取进程 PID |
| **网络** | `ip addr` | 网络接口信息 |
| | `ip route` | 路由表 |
| | `netstat -tlnp` | TCP 端口监听 |
| | `ss -tlnp` | 套接字统计 |
| | `ping -c 4 <host>` | 网络连通性测试 |
| | `curl -I <url>` | HTTP 头信息 |
| | `dig <domain>` | DNS 解析 |
| | `traceroute <host>` | 路由追踪 |
| **服务** | `systemctl status <service>` | 服务状态 |
| | `systemctl is-active <service>` | 服务是否运行 |
| | `systemctl list-units --type=service` | 服务列表 |
| **日志** | `tail -n 100 <logfile>` | 查看日志末尾 |
| | `head -n 100 <logfile>` | 查看日志开头 |
| | `journalctl -u <service> -n 100` | 服务日志 |
| | `dmesg \| tail -50` | 内核日志 |
| **安全** | `who` | 当前登录用户 |
| | `w` | 用户活动 |
| | `last -n 20` | 登录历史 |
| | `cat /etc/passwd` | 用户列表 |
| | `cat /etc/group` | 用户组列表 |
| **其他** | `env` | 环境变量 |
| | `crontab -l` | 定时任务列表 |
| | `docker ps` | Docker 容器列表 |
| | `docker images` | Docker 镜像列表 |
| | `scripts/ops/*.sh` | ops 目录下的预定义运维脚本 |

### 自动化助手（TAT）

> TAT（TencentCloud Automation Tools）是腾讯云自动化助手，可**无需 SSH 密码和公网 IP** 在实例上执行命令。
>
> 适用场景：批量执行、私有网络实例、更安全的运维方式

| 脚本 | 功能 | 特殊参数 |
|------|------|----------|
| `tat-agent-status.sh` | 检查 Agent 状态 | `--instance-id` |
| `tat-run-command.sh` | 执行命令 | `--instance-id`, `--cmd`, `--wait` |
| `tat-describe-invocation.sh` | 查询执行结果 | `--invocation-id`, `--show-output` |

#### TAT vs SSH 运维对比

| 维度 | ops（SSH） | tat（自动化助手） |
|------|-----------|------------------|
| 连接方式 | SSH + 密码 | 云 API（无需密码） |
| 公网 IP | 必需 | 不需要 |
| 批量执行 | 需循环 | 原生支持 |
| 执行记录 | 本地日志 | 云端可追溯 |

### 辅助工具

| 脚本 | 功能 |
|------|------|
| `show-defaults.sh` | 查看当前配置 |
| `get-password.sh` | 获取实例密码 |
| `update-instance-ip.sh` | 更新实例 IP |
| `manage-passwords.sh` | 管理密码存储 |

## 配置

### tccli 凭证

```bash
tccli configure set secretId YOUR_SECRET_ID
tccli configure set secretKey YOUR_SECRET_KEY
```

> 凭证存储在 `~/.tccli/credentials`，如未配置会提示用户提供。

### 环境变量（可选）

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `TENCENT_CVM_DEFAULT_REGION` | 默认地域 | `ap-guangzhou` |
| `TENCENT_CVM_DEFAULT_ZONE` | 默认可用区 | - |
| `TENCENT_CVM_DEFAULT_INSTANCE_TYPE` | 默认机型 | - |
| `TENCENT_CVM_DEFAULT_IMAGE_ID` | 默认镜像 | - |
| `TENCENT_CVM_DEFAULT_VPC_ID` | 默认 VPC | - |
| `TENCENT_CVM_DEFAULT_SUBNET_ID` | 默认子网 | - |
| `TENCENT_CVM_DEFAULT_SG_ID` | 默认安全组 | - |
| `TENCENT_CVM_DEFAULT_DISK_SIZE` | 系统盘大小 | `20` |
| `TENCENT_CVM_DEFAULT_CHARGE_TYPE` | 计费类型 | `POSTPAID_BY_HOUR` |

### 支持的地域

`ap-beijing` | `ap-shanghai` | `ap-guangzhou` | `ap-chengdu` | `ap-nanjing` | `ap-hongkong`

### 支持的镜像平台

`TencentOS` | `CentOS` | `Ubuntu` | `Debian`

### SSH 登录用户名

| 系统 | 默认用户名 | 示例 |
|------|------------|------|
| Ubuntu | `ubuntu` | `ssh ubuntu@<ip>` |
| 其他 Linux (TencentOS, CentOS, Debian) | `root` | `ssh root@<ip>` |

## 密码存储

创建实例时自动生成密码并保存到 `~/.tencent_cvm_passwords`（权限 600）：

```json
{
  "ins-xxx": {
    "password": "aB3#xK9$mN2@pQ",
    "host": "1.2.3.4",
    "region": "ap-guangzhou",
    "created_at": "2026-02-06 15:30:00"
  }
}
```

管理命令：
```bash
./scripts/utils/manage-passwords.sh --list              # 列出所有
./scripts/utils/manage-passwords.sh --show ins-xxx      # 查看详情
./scripts/utils/manage-passwords.sh --delete ins-xxx    # 删除记录
```

## 安全说明

本工具集设计用于可信环境下的服务器运维，遵循以下安全原则：

1. **预定义脚本**：仅执行 `scripts/` 目录下已审核的预定义脚本，禁止动态生成或执行任意代码
2. **人工确认**：所有写操作（停止、重启、销毁、文件传输等）必须经人工确认后执行
3. **凭证安全**：密码文件 `~/.tencent_cvm_passwords` 权限为 600，仅限本地用户访问
4. **操作审计**：所有操作均有日志输出，便于追溯
5. **使用场景**：适用于开发测试环境，生产环境建议配合堡垒机使用

## 扩展能力

本工具集封装了常用的 CVM 操作，更多 CVM 接口可通过 tccli 直接调用：

```bash
# 查看所有可用的 CVM 接口
tccli cvm help

# 查看具体接口的参数说明
tccli cvm <接口名> help

# 常用扩展接口示例
tccli cvm ResetInstancesPassword help     # 重置密码
tccli cvm ResizeInstanceDisks help        # 磁盘扩容
tccli cvm CreateKeyPair help              # 创建密钥对
tccli cvm DescribeKeyPairs help           # 查询密钥对
tccli cvm DescribeInstanceVncUrl help     # 获取 VNC 链接
tccli cvm InquiryPriceRenewInstances help # 续费询价
```

## 参考

- [腾讯云 CVM API 文档](https://cloud.tencent.com/document/product/213)
- [tccli 使用指南](https://cloud.tencent.com/document/product/440/34011)
