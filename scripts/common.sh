#!/bin/bash
# common.sh - 腾讯云 CVM 运维工具公共函数库
# 提供日志、检查、API 调用、SSH 连接等通用功能

set -o pipefail

#=============================================================================
# 常量定义
#=============================================================================

# 颜色
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# 默认配置
readonly DEFAULT_REGION="ap-guangzhou"
readonly DEFAULT_CHARGE_TYPE="POSTPAID_BY_HOUR"
readonly DEFAULT_DISK_SIZE=20
readonly DEFAULT_DATA_DISK_SIZE=50
readonly DEFAULT_SSH_PORT=22
readonly DEFAULT_SSH_USER="root"

# 公共脚本路径；本地连接记录按 profile 隔离。
CVM_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CVM_PASSWORD_FILE="${TENCENT_CVM_PASSWORD_FILE:-$HOME/.tencent_cvm_passwords}"

#=============================================================================
# 日志函数
#=============================================================================

info()    { printf '%b[INFO]%b %s\n' "$BLUE" "$NC" "$1" >&2; }
success() { printf '%b[OK]%b %s\n' "$GREEN" "$NC" "$1" >&2; }
warn()    { printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$1" >&2; }
error()   { printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$1" >&2; }

# 带分隔线的标题输出
print_section() {
    local title="$1"
    echo ""
    echo "========== $title =========="
}

#=============================================================================
# 依赖检查
#=============================================================================

# 检查生成随机密码所需的 Python 3
check_python_installed() {
    if ! command -v python3 &>/dev/null; then
        error "Python 3 未安装"
        echo "安装方式: brew install python3 (macOS) | apt install python3 (Linux)" >&2
        exit 1
    fi
}

# 检查 tccli
check_tccli_installed() {
    if ! command -v tccli &>/dev/null; then
        error "tccli 未安装"
        echo "安装方式: python3 -m pip install --upgrade tccli" >&2
        exit 1
    fi
}

# 检查 jq
check_jq_installed() {
    if ! command -v jq &>/dev/null; then
        error "jq 未安装"
        echo "安装方式: brew install jq (macOS) | apt install jq (Linux)"
        exit 1
    fi
}

# 检查 sshpass（SSH 密码认证需要）
check_sshpass_installed() {
    if ! command -v sshpass &>/dev/null; then
        error "sshpass 未安装（SSH 密码认证需要）"
        echo ""
        echo "安装方式:"
        echo "  macOS:   brew install hudochenkov/sshpass/sshpass"
        echo "  Ubuntu:  sudo apt install sshpass"
        echo "  CentOS:  sudo yum install sshpass"
        exit 1
    fi
}

# 只检查依赖。凭证解析/续期交给 tccli，兼容 OAuth、SSO、环境变量和角色。
# 不读取凭证文件，也不为每个 API 请求额外发起认证探测。
check_api_prerequisites() {
    check_tccli_installed
    check_jq_installed
}

#=============================================================================
# 验证函数
#=============================================================================

# 只验证格式，实际支持范围以 API 为准，避免过时的地域/镜像白名单。
validate_region() {
    [[ "$1" =~ ^[a-z]{2,}-[a-z0-9]+(-[a-z0-9]+)*$ ]] || { error "地域格式无效: $1"; return 2; }
}

validate_platform() {
    [[ -n "$1" && "$1" != -* && "$1" != *$'\n'* ]] || { error "镜像平台无效"; return 2; }
}

require_value() {
    [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || { error "$1 需要参数值"; return 2; }
}

#=============================================================================
# 配置管理
#=============================================================================

# 加载默认配置（从环境变量）
load_defaults() {
    REGION="${TENCENT_CVM_DEFAULT_REGION:-$DEFAULT_REGION}"
    ZONE="${TENCENT_CVM_DEFAULT_ZONE:-}"
    INSTANCE_TYPE="${TENCENT_CVM_DEFAULT_INSTANCE_TYPE:-}"
    IMAGE_ID="${TENCENT_CVM_DEFAULT_IMAGE_ID:-}"
    DISK_SIZE="${TENCENT_CVM_DEFAULT_DISK_SIZE:-$DEFAULT_DISK_SIZE}"
    DATA_DISK_SIZE="${TENCENT_CVM_DEFAULT_DATA_DISK_SIZE:-}"
    VPC_ID="${TENCENT_CVM_DEFAULT_VPC_ID:-}"
    SUBNET_ID="${TENCENT_CVM_DEFAULT_SUBNET_ID:-}"
    SG_ID="${TENCENT_CVM_DEFAULT_SG_ID:-}"
    CHARGE_TYPE="${TENCENT_CVM_DEFAULT_CHARGE_TYPE:-$DEFAULT_CHARGE_TYPE}"
}

# 旧接口保留：文件中缺失的字段才沿用当前默认配置，绝不覆盖已读值。
load_config_file() {
    local config_file="$1" key variable value
    [[ -f "$config_file" ]] || { error "配置文件不存在: $config_file"; return 1; }
    jq -e 'type == "object"' "$config_file" >/dev/null || return 1
    while read -r variable key; do
        value=$(jq -r "$key // empty" "$config_file") || return 1
        [[ -z "$value" ]] || printf -v "$variable" '%s' "$value"
    done <<'FIELDS'
REGION .Region
ZONE .Placement.Zone
INSTANCE_TYPE .InstanceType
IMAGE_ID .ImageId
DISK_SIZE .SystemDisk.DiskSize
DATA_DISK_SIZE .DataDisks[0].DiskSize
VPC_ID .VirtualPrivateCloud.VpcId
SUBNET_ID .VirtualPrivateCloud.SubnetId
SG_ID .SecurityGroupIds[0]
CHARGE_TYPE .InstanceChargeType
INSTANCE_NAME .InstanceName
FIELDS
}

# 显示当前配置
show_current_defaults() {
    print_section "当前配置"
    cat <<EOF
地域:       ${REGION:-未设置}
可用区:     ${ZONE:-未设置}
实例规格:   ${INSTANCE_TYPE:-未设置}
镜像 ID:    ${IMAGE_ID:-未设置}
系统盘:     ${DISK_SIZE}GB
数据盘:     ${DATA_DISK_SIZE:-不创建}
VPC:        ${VPC_ID:-未设置}
子网:       ${SUBNET_ID:-未设置}
安全组:     ${SG_ID:-未设置}
计费类型:   ${CHARGE_TYPE}
EOF
    echo "=================================="
}

#=============================================================================
# 密码生成与管理
#=============================================================================

# 生成符合腾讯云要求的随机密码（12-30位，包含大小写、数字、特殊字符）
generate_password() {
    check_python_installed
    python3 - "${1:-16}" <<'PY'
import secrets
import string
import sys

length = int(sys.argv[1])
if not 12 <= length <= 30:
    sys.exit("密码长度须为 12–30")
groups = (string.ascii_uppercase, string.ascii_lowercase, string.digits, "!@#$%^&*")
alphabet = "".join(groups)
while True:
    password = "".join(secrets.choice(alphabet) for _ in range(length))
    if all(any(char in group for char in password) for group in groups):
        print(password)
        break
PY
}

# 默认 profile 保留旧位置，其他 profile 不会误用默认账号的实例密码/IP。
password_file_path() {
    local profile
    profile=$(tccli_profile) || return $?
    if [[ -n "${TENCENT_CVM_PASSWORD_FILE:-}" ]]; then
        printf '%s\n' "$TENCENT_CVM_PASSWORD_FILE"
    elif [[ "$profile" == default ]]; then
        printf '%s\n' "$HOME/.tencent_cvm_passwords"
    else
        printf '%s\n' "$HOME/.tencent-cvm/$profile/passwords.json"
    fi
}

instance_store() {
    check_python_installed
    local store_file
    store_file=$(password_file_path) || return $?
    CVM_STORE_FILE="$store_file" python3 "$CVM_COMMON_DIR/instance_store.py" "$@"
}

init_password_file() { instance_store init; }

save_instance_password() {
    local instance_id="$1" password="$2" host="${3:-}" region="${4:-}" user="${5:-}"
    printf '%s' "$password" | instance_store save --id "$instance_id" --host "$host" --region "$region" --user "$user" || return $?
    success "实例 $instance_id 连接信息已保存在本地（密码不回显）"
}

save_instance_connection() {
    instance_store connect --id "$1" --host "${2:-}" --region "${3:-}" --user "${4:-}"
}

update_instance_host() {
    instance_store host --id "$1" --host "$2" || return $?
    success "实例 $1 IP 已更新"
}

get_instance_password() { instance_store get --id "$1" --field password; }
get_instance_host() { instance_store get --id "$1" --field host; }
get_instance_info() { instance_store get --id "$1"; }
list_saved_instances() { instance_store list; }
delete_instance_password() { instance_store delete --id "$1"; }
clear_instance_password() { instance_store clear-password --id "$1"; }

#=============================================================================
# 工具函数
#=============================================================================

# 用户确认
confirm() {
    local message="${1:-确认继续?}"
    local response=""
    printf '%s [y/N]: ' "$message" >&2
    IFS= read -r response || return 1
    [[ "$response" =~ ^[yY]([eE][sS])?$ ]]
}

# 帮助信息头部
print_help_header() {
    local script_name="$1" description="$2"
    cat <<EOF

用法: $script_name [选项]

$description

选项:
EOF
}

#=============================================================================
# API 调用
#=============================================================================

# 认证与 API 始终使用同一 profile；不自行改写 tccli 的凭证优先级。
tccli_profile() {
    local profile="${TENCENT_CVM_PROFILE:-${TCCLI_PROFILE:-default}}"
    [[ "$profile" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || { error "profile 只允许字母、数字、点、下划线、连字符，且以字母或数字开头"; return 2; }
    printf '%s\n' "$profile"
}

# 原始 API 调用入口。保留退出码和 stderr，供 DryRun 等特殊返回语义使用。
run_tccli() {
    local profile api_timeout="${TENCENT_CVM_API_TIMEOUT:-60}"
    profile=$(tccli_profile) || return $?
    [[ "$api_timeout" =~ ^[1-9][0-9]{0,3}$ ]] || { error "TENCENT_CVM_API_TIMEOUT 需要 1–9999 秒整数"; return 2; }
    local options=(--output json --timeout "$api_timeout")
    # tccli ignores environment credentials whenever --profile is explicit.
    # Preserve unattended environment auth when no profile was selected, while
    # keeping an explicitly selected account consistent for every operation.
    if [[ -n "${TENCENT_CVM_PROFILE:-}${TCCLI_PROFILE:-}" || -z "${TENCENTCLOUD_SECRET_ID:-}" || -z "${TENCENTCLOUD_SECRET_KEY:-}" ]]; then
        options+=(--profile "$profile")
    fi
    # Native tccli rewrites every profile's configuration on startup. Serialize
    # all profiles in this HOME; the launcher execs tccli while holding its lock.
    python3 "$CVM_COMMON_DIR/tccli_locked.py" "$@" "${options[@]}"
}

show_auth_guidance() {
    printf '认证需要恢复，当前配置: %s。由智能体在后台恢复原认证来源。\n' "$(tccli_profile)" >&2
    printf '%s\n' '需要网页登录时创建链接授权会话，并在对话中提供本次官方链接；无需用户执行命令或提供验证码。' >&2
    printf '%s\n' '已有环境凭证或 SSO 应按原方式恢复；不可达的远程回调需要宿主账号连接能力。' >&2
}

# 执行 tccli 命令（带错误处理）。调用者必须检查返回码，不自动登录或重试写操作。
execute_tccli() {
    local result exit_code=0 error_code error_message
    result=$(run_tccli "$@") || exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        error "tccli 命令执行失败（退出码 ${exit_code}）"
        info "按上方原始错误区分认证、权限、参数或网络问题；此退出码本身不表示需要重新登录。变更结果不明时先查询状态。"
        return "$exit_code"
    fi

    if ! printf '%s\n' "$result" | jq -e -s 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1; then
        error "tccli 未返回有效 JSON 对象，已停止；先检查原始响应和 CLI 兼容性，不自动重新登录或重放变更"
        return 1
    fi

    error_code=$(printf '%s\n' "$result" | jq -r '.Error.Code // .Response.Error.Code // empty')
    if [[ -n "$error_code" ]]; then
        error_message=$(printf '%s\n' "$result" | jq -r '.Error.Message // .Response.Error.Message // "未知错误"')
        error "API 错误: [$error_code] $error_message"
        case "$error_code" in
            AuthFailure*) show_auth_guidance ;;
            UnauthorizedOperation*) info "当前账号缺少本次操作的 CAM 权限；重复登录不会自动补充权限。" ;;
        esac
        return 1
    fi

    # SDK/CLI 版本可能保留 Response 包装，统一为业务 JSON。
    printf '%s\n' "$result" | jq -c 'if .Response | type == "object" then .Response else . end'
}

# 兼容旧函数名
check_prerequisites() { check_api_prerequisites; }
