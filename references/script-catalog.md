# 执行接口与行为

脚本供智能体在后台调用；用户不用执行命令，也不需要浏览器或终端界面控制能力。所有路径相对于 skill 根目录；示例中的 ID 来自实际查询。完整参数以脚本 `--help` 为准。

## 环境、账号与本地记录

| 脚本 | 用途/关键参数 |
|---|---|
| `utils/doctor.sh` | 默认离线检查依赖；`--json`，`--api` 另做只读认证验证 |
| `auth/login.sh` | 链接授权；`--start --profile --execution-context local --timeout` 返回 JSON；`--status <session_id>`、`--cancel <session_id>`；不打开浏览器、不读取用户输入，成功后自动验证 |
| `auth/check.sh` | `DescribeRegions` 验证；`--profile`、`--region` |
| `tccli_locked.py` | 同一 HOME 的全局 tccli 配置锁；`python3 scripts/tccli_locked.py <原生tccli参数>`，需显式保持原 profile；脚本内部已自动使用 |
| `utils/show-defaults.sh` | 展示非敏感默认配置和连接记录路径 |
| `utils/update-instance-ip.sh` | 保存连接地址，不要求已有密码；`--instance-id --auto --region`，`--address auto/public/private` 或 `--host`，可保存 `--user` |
| `utils/manage-passwords.sh` | `--list`/`--show` 默认脱敏；`--add` 通过隐藏输入、`--password-file` 或 `--password-stdin` 取密码；`--delete --yes` 仅删本地记录 |
| `utils/get-password.sh` | 默认脱敏；`--reveal` 会输出明文，不用于聊天回复；对话购买采用用户已有密钥或云平台提供的登录方式 |

统一环境变量 `TENCENT_CVM_PROFILE` > `TCCLI_PROFILE` > `default`。未选 profile 且已配置完整环境凭证时，不强加 `--profile`，保留 tccli 原生环境认证。创建默认配置来自 `TENCENT_CVM_DEFAULT_REGION/ZONE/INSTANCE_TYPE/IMAGE_ID/VPC_ID/SUBNET_ID/SG_ID/DISK_SIZE/DATA_DISK_SIZE/CHARGE_TYPE`，命令行优先于 JSON 配置，配置优先于默认值。

默认 profile 保留 `~/.tencent_cvm_passwords`；其他 profile 使用 `~/.tencent-cvm/<profile>/passwords.json`。文件权限为 600，读写加锁/原子替换；损坏文件不会被静默清空，符号链接会被拒绝。显式 `TENCENT_CVM_PASSWORD_FILE` 可选存储路径，不要跨账号共用同一路径。

本机原生 tccli 在每次命令初始化时会重写多个 profile 的配置文件；即使查询不同账号，并行调用也可能读到截断 JSON。所有脚本经全局锁串行执行，锁由原生进程持有至退出。锁不处理凭证内容，也不修改已安装的 tccli；其他直接运行的 tccli 不会自动遵守此锁，因此不要混用并发入口。JSON 解析失败本身不是重新登录的依据。

## 购买与实例生命周期

| 脚本 | 用途/关键参数 |
|---|---|
| `lifecycle/recommend-instance.sh` | 只读候选：`--scene --region --zone --json`，可选 `--image-id --gpu`；`--charge-type --period`；`--public-ip --bandwidth --internet-charge-type --traffic-gb`；`--budget --hours --currency --budget-currency`；`--candidate-limit 1..20` 默认每档 5 个 |
| `lifecycle/create-instance.sh` | `--config` 或具体资源参数；`--plan` 离线预览；`--dry-run` 询价+预检；`--prepare <文件>` 保存购买计划，缺网络时加 `--defer-network`；`--from-plan <文件> --yes --wait` 执行；`--resume <恢复文件>` 继承中断请求 |
| `lifecycle/wait-instance.sh` | 只读等待 `RUNNING/STOPPED/ABSENT`；`--request-id` 关联本次操作；新建实例可用 `--created-instance`（需本次创建的 RequestId），仅在三项操作字段全缺失时以该实例 `RUNNING` 判定就绪；`--timeout/--interval`；超时退出 124 |
| `lifecycle/start-instance.sh` | 启动；`--instance-id --region --yes --wait` |
| `lifecycle/stop-instance.sh` | 默认软停止；`--force` 明确强制；`--stopped-mode KEEP_CHARGING/STOP_CHARGING`，还支持 `--yes --wait` |
| `lifecycle/reboot-instance.sh` | 默认软重启；`--force`、`--yes`、`--wait` |
| `lifecycle/reset-instance.sh` | 清除系统盘重装；`--image-id`、`--key-id` 或 `--password-login/--password-file`，`--yes --wait` |
| `lifecycle/modify-instance-name.sh` | `--instance-id --name --region --yes` |
| `lifecycle/create-image.sh` | `--instance-id --image-name`，`--description`、`--force-poweroff`、`--dry-run`、`--yes` |
| `lifecycle/terminate-instance.sh` | 销毁；`--yes --wait`。提交后不立即删除连接记录 |

创建默认不申请公网；需要时显式 `--public-ip --bandwidth <Mbps> --internet-charge-type <模式>`。按量支持 `TRAFFIC_POSTPAID_BY_HOUR/BANDWIDTH_POSTPAID_BY_HOUR`，包月支持 `TRAFFIC_POSTPAID_BY_HOUR/BANDWIDTH_PREPAID`；不支持的组合在本地拒绝。优先复用查询到的 `--key-id`；无登录设置时由云平台生成密码。`--password-login` 仅用于明确选择本地密码管理的流程。包年包月必须 `--charge-type PREPAID --period <月数>`，默认不自动续费。

推荐默认按量、无公网；可显式比较包月和包含公网的配置，不声明全局最便宜。确定最终网络配置后仍用创建脚本复核报价。`create-instance.sh` 支持 `--budget --hours --currency --budget-currency --traffic-gb`：默认 720 小时为 30 天；按量预算对应时长，包年包月预算对应月均。币种须确认，流量是用量假设，估算不是封顶。

计划保存 `price/cost_estimate/estimate_options`。超预算会阻断；费用或币种不明可保存内部草稿，但不能拿它请求购买确认。明确预算的最终方案须先达到 `WithinEstimate`；实际购买还会再次检查。补全信息后生成新计划，不能用 `--from-plan` 覆盖估算选项。

`python3 scripts/lifecycle/price_estimate.py` 从 stdin 读取官方询价 JSON；`--charge-type` 必填，预付费还需 `--period`。`--internet-charge-type` 为 `NONE`、`TRAFFIC_POSTPAID_BY_HOUR`、`BANDWIDTH_POSTPAID_BY_HOUR` 或 `BANDWIDTH_PREPAID`。只解释可验证报价，不猜缺失费用。

一次创建封装只购买 1 台。高级参数不支持时明确报错，不静默丢弃配置；特殊批量/竞价/专用宿主机等场景需核实官方 API 后另行生成具体方案。

计划固定报价、预算、认证来源和配置。`--defer-network` 只询价，不做 DryRun；后续 `--from-plan` 仅能补入原先缺失的网络 ID，仍比较原报价。计划和恢复文件被修改时须重新准备，不手工改字段绕过校验。

计划与恢复文件含 token 和业务配置，不含云 API 密钥。`--prepare` 不允许明文实例密码；实际密码请求通过 600 权限临时文件传 tccli。私密恢复文件可能含实例密码；`--resume` 同时保留原参数、报价和预算，不能改用裸配置绕过费用约束。不要将恢复文件提交仓库或发送给他人。

## 网络前置

`network/ensure-network.sh` 可验证明确指定的 VPC/子网/安全组，或规划新建依赖；默认仅计划，`--create` 允许规划缺项新建，`--yes` 执行已经批准的具体方案。使用 `--state-file` 保留 checkpoint。

- 复用：明确提供资源 ID，验证地域、VPC/子网关系及可用区，读取已有安全组规则；不会改现有规则。
- 新建：创建独立 VPC/子网/安全组。仅 `--allow-web` 才开放 80/443，`--ssh-cidr` 才开放受限来源的 SSH；没有默认开放 22 到全网。
- 中断：保留已经创建的 ID；回包不明先核实资源，再恢复，避免重复创建。没有自动回滚删除。

## 查询

共同参数：`--region`、`--json`。有分页的接口支持 `--limit 1..100`、`--offset`、`--all`。`--all` 不可与非零 offset 同用；非分页接口不接受伪造分页参数。

| 脚本 | 筛选/用途 |
|---|---|
| `query/describe-regions.sh` | `--available`；非分页 |
| `query/describe-zones.sh` | 当前地域可用区；非分页 |
| `query/describe-instance-types.sh` | `--zone --family --type`；规格表不等于库存；非分页 |
| `query/describe-instances.sh` | `--instance-id <逗号分隔ID>` 或 `--name` |
| `query/describe-instance-status.sh` | `--instance-id` |
| `query/describe-images.sh` | `--image-id` 或 `--instance-type --platform --image-type --name` |
| `query/describe-vpcs.sh` | `--vpc-id` |
| `query/describe-subnets.sh` | `--subnet-id` 或 `--vpc-id --zone` |
| `query/describe-security-groups.sh` | `--sg-id` 或 `--name` |
| `query/describe-security-group-policies.sh` | `--sg-id`，完整入站/出站规则；非分页 |
| `query/describe-key-pairs.sh` | `--key-id` 或 `--name`；只查已有公钥信息，不读私钥 |

列表查询 JSON 的 `_Pagination` 包含 `Offset/ReturnedCount/TotalCount/Complete/RequestIds`，安全组规则查询返回原 API 对象。分页过程中重复资源、总数变化、提前空页会中止；不要把这种失败解释为无资源。IDs 与 Filters 互斥的接口会在本地拒绝无效组合。

## TAT

| 脚本 | 关键参数 |
|---|---|
| `tat/tat-agent-status.sh` | `--instance-id --all --json` |
| `tat/tat-run-command.sh` | `--instance-id <逗号分隔ID> --cmd <单条诊断命令>`，`--timeout` 云端命令超时、`--wait --wait-timeout --interval --json` |
| `tat/tat-describe-invocation.sh` | `--invocation-id --show-output --json`，查询所有任务分页 |

`tat-run-command.sh --wait` 成功要求所有目标到终态且退出码为 0；返回 1 表示失败，124 表示本地等待超时（云端可能仍在运行）。不加 `--wait` 时退出 0 只代表提交成功；`tat-describe-invocation.sh` 退出 0 只代表查询成功，需另读 `Summary`。保留 InvocationId 继续查询，不因本地超时重新执行。查询输出需 `--show-output`，`--json` 不自动开启输出；有 `Dropped/OutputUrl` 时告知截断，JSON 中输出保留 API Base64 格式。

## SSH 诊断与变更

所有 `ops/` 脚本支持 `--instance-id` 或 `--host`、`--region`、`--address auto/public/private`、`--user`、`--port`、`--identity`、`--auth auto/key/password`。

默认 agent/密钥，`--auth password` 可读取该 profile 已存密码，`--password-file` 要求私有权限。旧 `--password` 仅兼容，不用于智能体生成命令。主机密钥默认严格校验；显式 `--accept-new-host-key` 只接受首次密钥，不接受被替换的旧密钥。

| 脚本 | 作用 |
|---|---|
| `ssh-connect.sh` | 连接已授权目标 |
| `remote-exec.sh` | `--cmd` 单条诊断；`--list-commands` 查看有限语法 |
| `system-info.sh` | 系统、CPU、内存、磁盘、本机网络 |
| `disk-usage.sh` | `--threshold`；磁盘和大文件，受权限影响的部分明确标注 |
| `process-monitor.sh` | `--top`、`--filter` 字面文本筛选 |
| `log-viewer.sh` | `--file --lines --filter --follow` |
| `network-check.sh` | 本机网络；`--target` 才探测指定主机 |
| `security-check.sh` | 读取生效配置；无权限时不猜测安全状态 |
| `service-manage.sh` | `--service --action status/start/stop/restart/reload/enable/disable` |
| `file-transfer.sh` | `--upload/--download --local --remote`，可能覆盖目标 |

服务变更和文件传输需既有授权后的 `--yes` 或一次交互确认。远程失败原码返回，不自动换认证方式重放。远端诊断面向安装 Bash 的 Linux；SCP 远程路径目前限制 ASCII 字母、数字、`_./-`，不支持空格/通配符。

SSH/TAT 共用 `ops/validate-command.py`。只允许明确的诊断命令及参数，拒绝 `env` 执行子命令、Shell 运算符、多行、命令替换和写操作；不是任意 Shell 沙箱。命令输出仍可能包含敏感业务数据，只取任务所需内容。

## 打包与验证

`bash package.sh --info/--list` 查看版本和内容；`--output <路径>` 生成 zip，已有文件需明确 `--force` 才原子替换。版本来自 `SKILL.md`，不包含测试、缓存、仓库元数据或个人文章。

离线回归：`PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v`。所有云 API、SSH/SCP 均使用 mock；通过并不替代真实账号的兼容性验证。
