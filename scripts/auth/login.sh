#!/bin/bash
# 链接授权：后台运行原生tccli，只向调用方返回官方链接，不打开浏览器或读取验证码。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"
show_help() {
    cat <<'EOF'
用法: login.sh [--start] --execution-context local [--profile <name>] [--timeout <秒>]
      login.sh --status <session_id>
      login.sh --cancel <session_id>

后台链接授权；只返回 JSON，不打开浏览器、不要求终端输入、不接收验证码。
用户点击 start 返回的 auth_url，在腾讯云页面完成授权后自动回调。
  --start                 开始授权；同 profile 待授权会话复用同一链接
  --status <session_id>    查询 starting/awaiting_authorization/verifying/ready 等状态
  --cancel <session_id>    取消本次后台会话，不退出已成功保存的账号
  --execution-context     local/remote/unknown；仅已知浏览器与执行器同机时选 local
  --profile <name>        本地账号配置名
  --timeout <秒>          会话有效期，默认 300，范围 1–3600

remote/unknown 不启动 localhost 回调，返回 needs_host_auth；使用宿主已有认证或可信连接器。
授权完成后自动用 DescribeRegions 验证连接；ready 不等于所有云产品权限均可用。
EOF
}
ACTION=start SESSION_ID="" LOGIN_TIMEOUT=300 EXECUTION_CONTEXT=unknown ACTION_SET=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --start|--status|--cancel)
            [[ "$ACTION_SET" == false ]] || { error "只能指定一种会话操作"; exit 2; }
            ACTION_SET=true; ACTION="${1#--}"
            if [[ "$ACTION" == start ]]; then shift; else
                require_value "$@"; SESSION_ID="$2"; shift 2
            fi ;;
        --profile|--timeout|--execution-context)
            require_value "$@"
            case "$1" in
                --profile) export TENCENT_CVM_PROFILE="$2" ;;
                --timeout) LOGIN_TIMEOUT="$2" ;;
                --execution-context) EXECUTION_CONTEXT="$2" ;;
            esac
            shift 2 ;;
        --no-browser)
            error "链接授权不接收验证码；请使用 --execution-context local 获取本次可点击链接。远程环境使用宿主已有认证或可信连接器。"; exit 2 ;;
        -h|--help) show_help; exit 0 ;;
        *) error "未知参数: $1"; show_help; exit 2 ;;
    esac
done
check_python_installed
ARGS=("$ACTION" --profile "$(tccli_profile)" --timeout "$LOGIN_TIMEOUT" --execution-context "$EXECUTION_CONTEXT")
[[ -z "$SESSION_ID" ]] || ARGS+=(--session-id "$SESSION_ID")
exec python3 "$SCRIPT_DIR/login_flow.py" "${ARGS[@]}"
