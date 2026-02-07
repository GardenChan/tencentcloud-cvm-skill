#!/bin/bash
# tat-run-command.sh - 通过 TAT 在实例上执行命令（无需 SSH）

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

#=============================================================================
# 安全命令白名单（与 remote-exec.sh 保持一致）
#=============================================================================

SAFE_COMMAND_PREFIXES=(
    # 系统信息
    "uptime" "uname" "hostname" "cat /etc/os-release" "date" "timedatectl"
    # CPU
    "cat /proc/loadavg" "top -bn1" "mpstat" "nproc" "lscpu"
    # 内存
    "free" "cat /proc/meminfo" "vmstat"
    # 磁盘
    "df" "lsblk" "fdisk -l" "du -sh" "du -h"
    # 进程
    "ps aux" "ps -ef" "pgrep" "pidof"
    # 网络
    "ip addr" "ip route" "ifconfig" "netstat" "ss -" "ping -c" "curl -I" "curl -s" "dig" "nslookup" "traceroute" "tracepath"
    # 服务
    "systemctl status" "systemctl is-active" "systemctl is-enabled" "systemctl list-units" "service"
    # 日志
    "tail -n" "tail -f" "head -n" "journalctl" "dmesg" "cat /var/log"
    # 安全
    "who" "w" "last" "lastlog" "cat /etc/passwd" "cat /etc/group" "id" "groups"
    # 其他
    "env" "printenv" "crontab -l" "docker ps" "docker images" "docker stats --no-stream"
    "nginx -t" "nginx -T" "php -v" "node -v" "python --version" "python3 --version"
    "java -version" "mysql --version" "redis-cli info" "redis-cli ping"
)

DANGEROUS_PATTERNS=(
    "rm " "rm -" "rmdir" "dd " "mkfs" "fdisk -" "> " ">> " "wget " "curl -o" "curl -O"
    "chmod " "chown " "chgrp " "useradd" "userdel" "usermod" "passwd" "sudo " "su "
    "shutdown" "reboot" "halt" "poweroff" "init " "systemctl start" "systemctl stop"
    "systemctl restart" "systemctl enable" "systemctl disable" "kill " "killall" "pkill"
    "mv " "cp " "; " "&&" "||" "|" "\`" "\$(" "eval " "exec " "source " ". "
)

validate_command() {
    local cmd="$1"
    cmd=$(echo "$cmd" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    
    for pattern in "${DANGEROUS_PATTERNS[@]}"; do
        if [[ "$cmd" == *"$pattern"* ]]; then
            error "命令包含危险操作: $pattern"
            return 1
        fi
    done
    
    for safe_prefix in "${SAFE_COMMAND_PREFIXES[@]}"; do
        if [[ "$cmd" == "$safe_prefix" ]] || [[ "$cmd" == "$safe_prefix "* ]]; then
            return 0
        fi
    done
    
    error "不支持的命令: $cmd"
    echo "仅支持预定义的安全命令集，详见 SKILL.md" >&2
    return 1
}

#=============================================================================
# 主逻辑
#=============================================================================

show_help() {
    print_help_header "tat-run-command.sh" "通过 TAT 在实例上执行命令（无需 SSH 密码）"
    cat <<EOF
  --instance-id <id>      实例 ID（必需，可多个逗号分隔）
  --cmd <command>         要执行的命令（必需，仅支持安全命令集）
  --region <region>       地域，默认 $DEFAULT_REGION
  --timeout <seconds>     超时时间，默认 60 秒
  --wait                  等待执行完成并显示结果
  -h, --help              显示帮助

优势:
  - 无需 SSH 密码和公网 IP
  - 支持批量执行（多实例）
  - 执行记录可追溯

前提:
  实例需安装 TAT Agent，可通过 tat-agent-status.sh 检查

示例:
  $0 --instance-id ins-xxx --cmd "df -h"
  $0 --instance-id ins-xxx --cmd "uptime" --wait
  $0 --instance-id ins-xxx,ins-yyy --cmd "free -h"

EOF
}

check_api_prerequisites
load_defaults

INSTANCE_IDS="" CMD="" TIMEOUT=60 WAIT=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --instance-id) INSTANCE_IDS="$2"; shift 2 ;;
        --cmd)         CMD="$2"; shift 2 ;;
        --region)      REGION="$2"; shift 2 ;;
        --timeout)     TIMEOUT="$2"; shift 2 ;;
        --wait)        WAIT=true; shift ;;
        -h|--help)     show_help; exit 0 ;;
        *)             error "未知参数: $1"; exit 1 ;;
    esac
done

[[ -z "$INSTANCE_IDS" ]] && { error "缺少: --instance-id"; exit 1; }
[[ -z "$CMD" ]] && { error "缺少: --cmd"; exit 1; }
validate_region "$REGION"

# 安全校验
validate_command "$CMD" || exit 1

# 构建实例 ID 数组
IDS_JSON=$(echo "$INSTANCE_IDS" | tr ',' '\n' | jq -R . | jq -s .)

# Base64 编码命令内容
CMD_BASE64=$(echo -n "$CMD" | base64)

info "通过 TAT 执行命令..."
echo "实例:   $INSTANCE_IDS"
echo "命令:   $CMD"
echo ""

result=$(execute_tccli tat RunCommand \
    --region "$REGION" \
    --InstanceIds "$IDS_JSON" \
    --Content "$CMD_BASE64" \
    --CommandType "SHELL" \
    --Timeout "$TIMEOUT" \
    --CommandName "skill-exec-$(date +%s)")

invocation_id=$(echo "$result" | jq -r '.InvocationId')

if [[ -z "$invocation_id" || "$invocation_id" == "null" ]]; then
    error "命令执行失败"
    echo "$result"
    exit 1
fi

success "命令已提交"
echo "执行 ID: $invocation_id"

# 等待执行完成
if [[ "$WAIT" == "true" ]]; then
    echo ""
    info "等待执行完成..."
    
    for i in {1..30}; do
        sleep 2
        
        task_result=$(execute_tccli tat DescribeInvocationTasks \
            --region "$REGION" \
            --Filters "[{\"Name\":\"invocation-id\",\"Values\":[\"$invocation_id\"]}]" \
            --HideOutput false 2>/dev/null)
        
        status=$(echo "$task_result" | jq -r '.InvocationTaskSet[0].TaskStatus // "PENDING"')
        
        case "$status" in
            SUCCESS)
                echo ""
                print_section "执行结果"
                echo "$task_result" | jq -r '.InvocationTaskSet[] | "实例: \(.InstanceId)\n状态: \(.TaskStatus)\n输出:\n\(.TaskResult.Output // "无输出" | @base64d)\n"'
                success "执行完成"
                exit 0
                ;;
            FAILED|TIMEOUT)
                echo ""
                error "执行失败: $status"
                echo "$task_result" | jq -r '.InvocationTaskSet[] | "实例: \(.InstanceId)\n错误: \(.TaskResult.ErrorInfo // "未知错误")"'
                exit 1
                ;;
            *)
                printf "."
                ;;
        esac
    done
    
    echo ""
    warn "等待超时，可通过以下命令查询结果："
    echo "  ./scripts/tat/tat-describe-invocation.sh --invocation-id $invocation_id"
fi

echo ""
info "查询执行结果："
echo "  ./scripts/tat/tat-describe-invocation.sh --invocation-id $invocation_id"
