#!/bin/bash
# 默认显示脱敏连接信息，明文密码仅在显式 --reveal 时输出。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"
INSTANCE_ID="" REVEAL=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --instance-id|--profile)
            require_value "$@"
            if [[ "$1" == --profile ]]; then export TENCENT_CVM_PROFILE="$2"; else INSTANCE_ID="$2"; fi
            shift 2 ;;
        --reveal) REVEAL=true; shift ;;
        --show-all) shift ;;
        -h|--help)
            printf '%s\n' '用法: get-password.sh --instance-id <id> [--profile <name>] [--reveal]' '默认只显示连接信息（JSON）；--reveal 输出密码，仅在自己的终端使用。'; exit 0 ;;
        *) error "未知参数: $1"; exit 2 ;;
    esac
done
[[ -n "$INSTANCE_ID" ]] || { error "缺少 --instance-id"; exit 2; }
if [[ "$REVEAL" == true ]]; then get_instance_password "$INSTANCE_ID"; else get_instance_info "$INSTANCE_ID"; fi
