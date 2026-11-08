#!/bin/bash
# 更新当前 profile 的连接记录，支持只有 SSH key、没有本地密码的实例。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"
INSTANCE_ID="" HOST="" REGION="" LOGIN_USER="" AUTO=false ADDRESS=auto
while [[ $# -gt 0 ]]; do
    case "$1" in
        --instance-id|--host|--region|--user|--address|--profile)
            require_value "$@"
            case "$1" in
                --instance-id) INSTANCE_ID="$2";; --host) HOST="$2";; --region) REGION="$2";;
                --user) LOGIN_USER="$2";; --address) ADDRESS="$2";; --profile) export TENCENT_CVM_PROFILE="$2";;
            esac
            shift 2 ;;
        --auto) AUTO=true; shift ;;
        -h|--help)
            cat <<'HELP'
用法: update-instance-ip.sh --instance-id <id> (--host <ip> | --auto)
  --region <region>      显式地域，优先于本地记录及环境默认值
  --address auto|public|private  API 地址选择，auto 优先公网再内网
  --user <user>          保存 SSH 用户名
  --profile <name>       账号配置
无需已有密码记录；只保存连接信息，不修改云实例。
HELP
            exit 0 ;;
        *) error "未知参数: $1"; exit 2 ;;
    esac
done
[[ -n "$INSTANCE_ID" ]] || { error "缺少 --instance-id"; exit 2; }
[[ "$ADDRESS" == auto || "$ADDRESS" == public || "$ADDRESS" == private ]] || { error "无效 --address"; exit 2; }
[[ "$AUTO" != true || -z "$HOST" ]] || { error "--auto 与 --host 互斥"; exit 2; }
check_jq_installed
if [[ -z "$REGION" ]]; then
    RECORD=$(get_instance_info "$INSTANCE_ID" 2>/dev/null || printf '{}')
    REGION=$(printf '%s\n' "$RECORD" | jq -r '.region // empty')
    REGION="${REGION:-${TENCENT_CVM_DEFAULT_REGION:-$DEFAULT_REGION}}"
fi
validate_region "$REGION"
if [[ "$AUTO" == true ]]; then
    check_api_prerequisites
    IDS=$(jq -cn --arg id "$INSTANCE_ID" '[$id]')
    result=$(execute_tccli cvm DescribeInstances --region "$REGION" --InstanceIds "$IDS")
    if ! printf '%s\n' "$result" | jq -e --arg id "$INSTANCE_ID" '.InstanceSet | length == 1 and .[0].InstanceId == $id' >/dev/null; then
        error "当前 profile/地域未找到目标实例"; exit 1
    fi
    case "$ADDRESS" in
        public) FILTER='.InstanceSet[0].PublicIpAddresses[0] // empty';;
        private) FILTER='.InstanceSet[0].PrivateIpAddresses[0] // empty';;
        auto) FILTER='.InstanceSet[0].PublicIpAddresses[0] // .InstanceSet[0].PrivateIpAddresses[0] // empty';;
    esac
    HOST=$(printf '%s\n' "$result" | jq -r "$FILTER")
fi
[[ -n "$HOST" ]] || { error "没有可用地址；请指定 --host 或检查实例地址"; exit 1; }
save_instance_connection "$INSTANCE_ID" "$HOST" "$REGION" "$LOGIN_USER"
success "已更新当前 profile 的连接记录: $INSTANCE_ID ($REGION)"
