#!/bin/bash
# Shared SSH transport and diagnostics. The public entrypoints are the *.sh wrappers.
OPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$OPS_DIR/../common.sh"

ops_help() {
    cat <<EOF
用法: ${OPS_MODE}.sh [选项]

连接选项:
  --instance-id <id>       从本地记录或 CVM 查询目标地址
  --host <host>            明确指定 IP/DNS，覆盖实例地址
  --region <region>        查询实例时使用的地域
  --address <type>         auto(优先公网)/public/private，默认 auto
  --user <user>            SSH 用户，默认 root；Ubuntu 通常使用 ubuntu
  --port <port>            SSH 端口，默认 22
  --identity <file>        SSH 私钥文件；默认可使用 ssh-agent/默认密钥
  --auth <type>            auto/key/password；auto 默认使用密钥/agent
  --password-file <file>   从本地文件读取密码（需私有权限）
  --password <value>       兼容旧接口；可能进入进程列表，推荐 password-file
  --accept-new-host-key   显式接受首次主机密钥，仍拒绝已变更的密钥
  --yes                   已确认本次具体写操作，跳过脚本交互确认
  -h, --help              离线查看帮助

默认校验 known_hosts；首次连接请先核对服务器主机密钥。
本地保存密码可用 --auth password 选择，不因远程失败自动重放命令。
EOF
    case "$OPS_MODE" in
        remote-exec) printf '%s\n' '  --cmd <command>         单条诊断命令' '  --list-commands         查看支持的命令' ;;
        disk-usage) printf '%s\n' '  --threshold <1-100>     磁盘使用率告警阈值，默认 80' ;;
        process-monitor) printf '%s\n' '  --top <n>               TOP N，默认 10' '  --filter <text>         按字面文本过滤进程' ;;
        log-viewer) printf '%s\n' '  --file <path>           日志文件，默认 /var/log/syslog' '  --lines <n>             默认 100' '  --filter <text>         按字面文本过滤' '  --follow                持续跟踪，Ctrl+C 结束' ;;
        network-check) printf '%s\n' '  --target <host>         可选连通性目标，不默认探测外部网站' ;;
        service-manage) printf '%s\n' '  --service <name>        systemd 服务名' '  --action <operation>    status/start/stop/restart/reload/enable/disable，默认 status' ;;
        file-transfer) printf '%s\n' '  --upload/--download     选择传输方向' '  --local <path>          本地路径' '  --remote <path>         远程绝对路径（禁止通配符，目录递归）' ;;
    esac
}

ops_value() {
    [[ $# -ge 2 && -n "$2" ]] || { error "$1 需要参数值"; return 2; }
}

ops_positive_integer() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= $2))
}

# Quote a single argument for the remote login shell; never evaluate caller text.
ops_quote() {
    local value="$1"
    value=${value//\'/\'\\\'\'}
    printf "'%s'" "$value"
}

ops_remote_command() {
    local arg
    for arg in "$@"; do
        ops_quote "$arg"
        printf ' '
    done
}

ops_prepare() {
    command -v ssh >/dev/null || { error "ssh 未安装"; return 1; }
    ops_positive_integer "$OPS_PORT" 65535 || { error "SSH 端口须为 1–65535"; return 2; }
    case "$OPS_AUTH" in auto|key|password) ;; *) error "--auth 仅支持 auto/key/password"; return 2 ;; esac
    case "$OPS_ADDRESS" in auto|public|private) ;; *) error "--address 仅支持 auto/public/private"; return 2 ;; esac
    if [[ -n "$OPS_INSTANCE_ID" ]]; then
        [[ "$OPS_INSTANCE_ID" =~ ^ins-[a-zA-Z0-9]+$ ]] || { error "实例 ID 格式无效"; return 2; }
        if [[ -f "$(password_file_path)" ]]; then
            check_jq_installed
            local record stored_user stored_region
            record=$(get_instance_info "$OPS_INSTANCE_ID" 2>/dev/null) || record='{}'
            stored_user=$(printf '%s\n' "$record" | jq -r '.user // empty') || return 1
            stored_region=$(printf '%s\n' "$record" | jq -r '.region // empty') || return 1
            [[ "$OPS_USER_SET" == true || -z "$stored_user" ]] || OPS_USER="$stored_user"
            [[ "$OPS_REGION_SET" == true || -z "$stored_region" ]] || OPS_REGION="$stored_region"
        fi
    fi
    [[ "$OPS_USER" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*$ ]] || { error "SSH 用户名格式无效"; return 2; }
    validate_region "$OPS_REGION" || return $?
    if [[ -z "$OPS_HOST" && -n "$OPS_INSTANCE_ID" ]]; then
        if [[ "$OPS_ADDRESS" == auto && -f "$(password_file_path)" ]]; then
            check_jq_installed
            # A password-only record need not contain an address; resolve it via API.
            OPS_HOST=$(get_instance_host "$OPS_INSTANCE_ID" 2>/dev/null) || OPS_HOST=""
        fi
        if [[ -z "$OPS_HOST" ]]; then
            check_api_prerequisites
            local result
            result=$(execute_tccli cvm DescribeInstances --region "$OPS_REGION" --InstanceIds "[\"$OPS_INSTANCE_ID\"]") || return $?
            case "$OPS_ADDRESS" in
                public) OPS_HOST=$(printf '%s\n' "$result" | jq -r '.InstanceSet[0].PublicIpAddresses[0] // empty') ;;
                private) OPS_HOST=$(printf '%s\n' "$result" | jq -r '.InstanceSet[0].PrivateIpAddresses[0] // empty') ;;
                auto) OPS_HOST=$(printf '%s\n' "$result" | jq -r '.InstanceSet[0].PublicIpAddresses[0] // .InstanceSet[0].PrivateIpAddresses[0] // empty') ;;
            esac
        fi
    fi
    [[ -n "$OPS_HOST" ]] || { error "缺少可连接地址，请指定 --host 或有效 --instance-id"; return 2; }
    [[ "$OPS_HOST" =~ ^[a-zA-Z0-9][a-zA-Z0-9._:-]*$ ]] || { error "目标地址格式无效"; return 2; }
    [[ -z "$OPS_IDENTITY" || -f "$OPS_IDENTITY" ]] || { error "SSH 私钥文件不存在"; return 2; }
    if [[ -n "$OPS_PASSWORD_FILE" ]]; then
        [[ -z "$OPS_PASSWORD" ]] || { error "不能同时提供 --password 和 --password-file"; return 2; }
        check_python_installed
        OPS_PASSWORD=$(python3 - "$OPS_PASSWORD_FILE" <<'PY'
import os
import stat
import sys
try:
    info = os.stat(sys.argv[1])
    if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077:
        sys.exit("密码文件必须是普通文件且权限仅对当前用户开放（如 600）")
    with open(sys.argv[1], encoding="utf-8") as stream:
        value = stream.read().rstrip("\r\n")
    if not value or "\n" in value or "\r" in value:
        sys.exit("密码文件须包含单行非空密码")
    print(value)
except OSError as exc:
    sys.exit(f"无法读取密码文件: {exc}")
PY
        ) || return $?
    fi
    if [[ "$OPS_AUTH" == key && -n "$OPS_PASSWORD" ]]; then
        error "--auth key 不能与密码选项组合"; return 2
    fi
    if [[ "$OPS_AUTH" == password && -z "$OPS_PASSWORD" ]]; then
        [[ -n "$OPS_INSTANCE_ID" ]] || { error "密码认证需要 --password-file 或已保存密码的 --instance-id"; return 2; }
        check_jq_installed
        OPS_PASSWORD=$(get_instance_password "$OPS_INSTANCE_ID") || return 1
    fi
    if [[ -n "$OPS_PASSWORD" ]]; then
        check_sshpass_installed
        OPS_AUTH=password
    else
        OPS_AUTH=key
    fi
    OPS_SSH_ARGS=(-o "StrictHostKeyChecking=$OPS_HOSTKEY" -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2)
    if [[ "$OPS_AUTH" == key ]]; then
        OPS_SSH_ARGS+=(-o BatchMode=yes)
    else
        OPS_SSH_ARGS+=(-o BatchMode=no -o NumberOfPasswordPrompts=1)
    fi
    if [[ -n "$OPS_IDENTITY" ]]; then
        OPS_SSH_ARGS+=(-i "$OPS_IDENTITY" -o IdentitiesOnly=yes)
    fi
}

ops_auth_run() {
    if [[ "$OPS_AUTH" == password ]]; then
        # Feed the password on a private descriptor, never in the process arguments.
        sshpass -d 3 "$@" 3<<<"$OPS_PASSWORD"
    else
        "$@"
    fi
}

ops_ssh() {
    ops_auth_run ssh "${OPS_SSH_ARGS[@]}" -p "$OPS_PORT" "$OPS_USER@$OPS_HOST" "$@"
}

ops_script() {
    ops_ssh "$(ops_remote_command bash -s -- "$@")"
}

ops_confirm() {
    [[ "$OPS_YES" == true ]] && return 0
    [[ -t 0 ]] || { error "写操作需先在对话中确认；已有本次具体授权时，由智能体在后台传 --yes"; return 2; }
    confirm "$1" || { info "已取消"; return 2; }
}

ops_main() {
    OPS_MODE="$1"; shift
    OPS_INSTANCE_ID="" OPS_HOST="" OPS_USER="${TENCENT_CVM_SSH_USER:-root}" OPS_PORT=22
    OPS_USER_SET=false OPS_REGION_SET=false
    OPS_REGION="${TENCENT_CVM_DEFAULT_REGION:-$DEFAULT_REGION}" OPS_ADDRESS=auto
    OPS_PASSWORD="" OPS_PASSWORD_FILE="" OPS_IDENTITY="" OPS_AUTH=auto OPS_HOSTKEY=yes OPS_YES=false
    OPS_CMD="" OPS_THRESHOLD=80 OPS_TOP=10 OPS_FILTER="" OPS_LOG_FILE=/var/log/syslog OPS_LINES=100 OPS_FOLLOW=false
    OPS_TARGET="" OPS_SERVICE="" OPS_ACTION=status OPS_TRANSFER="" OPS_LOCAL="" OPS_REMOTE=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) ops_help; return 0 ;;
            --yes) OPS_YES=true; shift; continue ;;
            --accept-new-host-key) OPS_HOSTKEY=accept-new; shift; continue ;;
            --list-commands)
                [[ "$OPS_MODE" == remote-exec ]] || { error "当前脚本不支持 $1"; return 2; }
                python3 "$OPS_DIR/validate-command.py" --list; return $? ;;
            --follow)
                [[ "$OPS_MODE" == log-viewer ]] || { error "当前脚本不支持 $1"; return 2; }
                OPS_FOLLOW=true; shift; continue ;;
            --upload|--download)
                [[ "$OPS_MODE" == file-transfer && -z "$OPS_TRANSFER" ]] || { error "请选择唯一的文件传输方向"; return 2; }
                OPS_TRANSFER="${1#--}"; shift; continue ;;
        esac
        ops_value "$@" || return $?
        case "$1" in
            --instance-id) OPS_INSTANCE_ID="$2" ;;
            --host) OPS_HOST="$2" ;;
            --user) OPS_USER="$2"; OPS_USER_SET=true ;;
            --port) OPS_PORT="$2" ;;
            --region) OPS_REGION="$2"; OPS_REGION_SET=true ;;
            --address) OPS_ADDRESS="$2" ;;
            --identity) OPS_IDENTITY="$2" ;;
            --auth) OPS_AUTH="$2" ;;
            --password) OPS_PASSWORD="$2" ;;
            --password-file) OPS_PASSWORD_FILE="$2" ;;
            *)
                case "$OPS_MODE:$1" in
                    remote-exec:--cmd) OPS_CMD="$2" ;;
                    disk-usage:--threshold) OPS_THRESHOLD="$2" ;;
                    process-monitor:--top) OPS_TOP="$2" ;;
                    process-monitor:--filter|log-viewer:--filter) OPS_FILTER="$2" ;;
                    log-viewer:--file) OPS_LOG_FILE="$2" ;;
                    log-viewer:--lines) OPS_LINES="$2" ;;
                    network-check:--target) OPS_TARGET="$2" ;;
                    service-manage:--service) OPS_SERVICE="$2" ;;
                    service-manage:--action) OPS_ACTION="$2" ;;
                    file-transfer:--local) OPS_LOCAL="$2" ;;
                    file-transfer:--remote) OPS_REMOTE="$2" ;;
                    *) error "未知参数: $1"; return 2 ;;
                esac ;;
        esac
        shift 2
    done
    # Validate caller-controlled values before any connection or cloud lookup.
    case "$OPS_MODE" in
        remote-exec)
            check_python_installed
            OPS_CMD=$(python3 "$OPS_DIR/validate-command.py" --command "$OPS_CMD") || return $? ;;
        disk-usage) ops_positive_integer "$OPS_THRESHOLD" 100 || { error "--threshold 须为 1–100"; return 2; } ;;
        process-monitor) ops_positive_integer "$OPS_TOP" 10000 || { error "--top 须为 1–10000"; return 2; } ;;
        log-viewer)
            ops_positive_integer "$OPS_LINES" 10000 || { error "--lines 须为 1–10000"; return 2; }
            [[ "$OPS_LOG_FILE" == /* ]] || { error "日志文件需为绝对路径"; return 2; } ;;
        network-check)
            [[ -z "$OPS_TARGET" || "$OPS_TARGET" =~ ^[a-zA-Z0-9][a-zA-Z0-9.:-]*$ ]] || { error "测试目标格式无效"; return 2; } ;;
        service-manage)
            [[ "$OPS_SERVICE" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.@:-]*$ ]] || { error "服务名格式无效"; return 2; }
            case "$OPS_ACTION" in status|start|stop|restart|reload|enable|disable) ;; *) error "服务操作无效"; return 2 ;; esac ;;
        file-transfer)
            [[ -n "$OPS_TRANSFER" && -n "$OPS_LOCAL" && "$OPS_REMOTE" == /* ]] || { error "传输需要方向、--local 和远程绝对路径 --remote"; return 2; }
            # SCP implementations may use a remote shell. Restrict remote path syntax,
            # avoiding expansion/injection regardless of SFTP or legacy protocol.
            [[ "$OPS_REMOTE" =~ ^/[a-zA-Z0-9_./-]*$ ]] || { error "远程路径仅支持字母、数字、下划线、点、斜杠和短横线"; return 2; }
            [[ "$OPS_LOCAL" == /* ]] || OPS_LOCAL="$PWD/$OPS_LOCAL"
            if [[ "$OPS_TRANSFER" == upload && ! -e "$OPS_LOCAL" ]]; then error "本地路径不存在"; return 2; fi ;;
    esac
    ops_prepare || return $?
    info "目标: $OPS_USER@$OPS_HOST:$OPS_PORT (认证: $OPS_AUTH)"
    case "$OPS_MODE" in
        ssh-connect) ops_ssh; return $? ;;
        remote-exec) ops_ssh "$OPS_CMD"; return $? ;;
        service-manage)
            if [[ "$OPS_ACTION" != status ]]; then
                ops_confirm "在 $OPS_USER@$OPS_HOST 对 $OPS_SERVICE 执行 ${OPS_ACTION}？" || return $?
            fi
            ops_ssh "$(ops_remote_command systemctl --no-pager "$OPS_ACTION" -- "$OPS_SERVICE")" || return $?
            success "服务操作完成" ;;
        file-transfer)
            command -v scp >/dev/null || { error "scp 未安装"; return 1; }
            ops_confirm "$OPS_TRANSFER: $OPS_LOCAL <-> $OPS_USER@$OPS_HOST:${OPS_REMOTE}（可能覆盖目标）？" || return $?
            local remote_host="$OPS_HOST"
            [[ "$remote_host" != *:* ]] || remote_host="[$remote_host]"
            if [[ "$OPS_TRANSFER" == upload ]]; then
                ops_auth_run scp "${OPS_SSH_ARGS[@]}" -P "$OPS_PORT" -r "$OPS_LOCAL" "$OPS_USER@$remote_host:$OPS_REMOTE" || return $?
            else
                ops_auth_run scp "${OPS_SSH_ARGS[@]}" -P "$OPS_PORT" -r "$OPS_USER@$remote_host:$OPS_REMOTE" "$OPS_LOCAL" || return $?
            fi
            success "文件传输完成" ;;
        *) ops_diagnostic || return $? ;;
    esac
}

ops_diagnostic() {
    case "$OPS_MODE" in
        system-info)
            ops_script <<'REMOTE'
set -e -o pipefail
printf '\n========== 系统 ==========%s\n' ""
hostname
uname -a
cat /etc/os-release
uptime
printf '\n========== CPU / 内存 ==========%s\n' ""
lscpu
free -h
printf '\n========== 磁盘 ==========%s\n' ""
df -h
printf '\n========== 本机地址 ==========%s\n' ""
ip addr show
REMOTE
            ;;
        disk-usage)
            ops_script "$OPS_THRESHOLD" <<'REMOTE'
set -e -o pipefail
threshold=$1
printf '\n========== 磁盘使用情况 ==========%s\n' ""
df -hP | awk -v threshold="$threshold" 'NR==1 {print; next} {usage=$5; sub(/%$/, "", usage); print $0 (usage >= threshold ? " [警告]" : "")}'
printf '\n========== 大文件（最多 10 个，本地文件系统） ==========%s\n' ""
find / -xdev -type f -size +100M -print 2>/dev/null | head -10 || true
printf '\n========== 根目录空间（可能因权限显示不完整） ==========%s\n' ""
du -xsh /* 2>/dev/null | sort -rh | head -10 || true
REMOTE
            ;;
        process-monitor)
            ops_script "$OPS_TOP" "$OPS_FILTER" <<'REMOTE'
set -e -o pipefail
top_count=$1
filter=$2
printf '\n========== CPU TOP %s ==========%s\n' "$top_count" ""
ps aux --sort=-%cpu | awk -v count="$((10#$top_count + 1))" 'NR <= count'
printf '\n========== 内存 TOP %s ==========%s\n' "$top_count" ""
ps aux --sort=-%mem | awk -v count="$((10#$top_count + 1))" 'NR <= count'
if [ -n "$filter" ]; then
    printf '\n========== 匹配进程 ==========%s\n' ""
    ps aux | grep -Fi -- "$filter" || true
fi
printf '\n========== 系统负载 ==========%s\n' ""
cat /proc/loadavg
REMOTE
            ;;
        log-viewer)
            ops_script "$OPS_LOG_FILE" "$OPS_LINES" "$OPS_FILTER" "$OPS_FOLLOW" <<'REMOTE'
set -e -o pipefail
log_file=$1
lines=$2
filter=$3
follow=$4
[ -r "$log_file" ] || { printf '日志不可读: %s\n' "$log_file" >&2; exit 1; }
tail_args=(-n "$lines")
[ "$follow" != true ] || tail_args+=(-f)
if [ -n "$filter" ]; then
    # grep=1 means no matches, but a failed tail must still fail the operation.
    set +e
    tail "${tail_args[@]}" -- "$log_file" | grep --line-buffered -Fi -- "$filter"
    codes=("${PIPESTATUS[@]}")
    [ "${codes[0]}" -eq 0 ] || exit "${codes[0]}"
    [ "${codes[1]}" -le 1 ] || exit "${codes[1]}"
else
    tail "${tail_args[@]}" -- "$log_file"
fi
REMOTE
            ;;
        network-check)
            ops_script "$OPS_TARGET" <<'REMOTE'
set -e -o pipefail
printf '\n========== 接口 ==========%s\n' ""
ip addr show
printf '\n========== 路由 ==========%s\n' ""
ip route show
printf '\n========== DNS ==========%s\n' ""
cat /etc/resolv.conf
printf '\n========== 监听端口 ==========%s\n' ""
ss -tlnp
if [ -n "$1" ]; then
    printf '\n========== 指定目标: %s ==========%s\n' "$1" ""
    ping -c 3 -W 2 -- "$1"
fi
REMOTE
            ;;
        security-check)
            ops_script <<'REMOTE'
set -e -o pipefail
printf '\n========== SSH 生效配置 ==========%s\n' ""
if command -v sshd >/dev/null && sshd -T >/dev/null 2>&1; then
    sshd -T | grep -E '^(permitrootlogin|passwordauthentication|port) '
else
    printf '无法读取生效配置（可能需要权限），不能据此推断默认值。\n'
fi
printf '\n========== 防火墙 ==========%s\n' ""
if command -v ufw >/dev/null; then
    ufw status || printf '防火墙状态不可用\n'
elif command -v firewall-cmd >/dev/null; then
    firewall-cmd --state || printf '防火墙状态不可用\n'
else
    printf '未检测到 ufw/firewalld；这不代表没有防火墙规则。\n'
fi
printf '\n========== 监听端口 ==========%s\n' ""
ss -tlnp
printf '\n========== 最近登录 ==========%s\n' ""
last -n 10 || printf '登录记录不可用\n'
printf '\n========== 可疑进程（仅启发式检查） ==========%s\n' ""
ps aux | grep -E 'nc -l|ncat|cryptominer|xmrig' | grep -v grep || printf '未匹配预设模式，不能据此判断主机安全。\n'
printf '\n========== 最近失败登录 ==========%s\n' ""
if [ -r /var/log/auth.log ]; then
    grep -Ei 'failed|invalid' /var/log/auth.log | tail -n 5 || printf '无匹配记录或读取失败。\n'
elif [ -r /var/log/secure ]; then
    grep -Ei 'failed|invalid' /var/log/secure | tail -n 5 || printf '无匹配记录或读取失败。\n'
else
    printf '未发现可读的认证日志；不能据此判断没有失败登录。\n'
fi
printf '\n========== 当前用户定时任务 ==========%s\n' ""
if jobs=$(crontab -l 2>/dev/null); then
    printf '%s\n' "$jobs" | awk 'NF && $0 !~ /^[[:space:]]*#/ {count++} END {print "有效行数:", count+0}'
    printf '默认不输出任务内容，避免泄露命令中的凭证。\n'
else
    printf '未配置或当前权限无法读取。\n'
fi
printf '\n========== 可登录用户 ==========%s\n'
awk -F: '$7 ~ /\/(bash|sh)$/ {print $1, $3}' /etc/passwd
REMOTE
            ;;
        *) error "未知诊断模式: $OPS_MODE"; return 2 ;;
    esac
}
