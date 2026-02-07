#!/bin/bash
# modify-instance-name.sh - 修改腾讯云 CVM 实例名称

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

show_help() {
    print_help_header "modify-instance-name.sh" "修改腾讯云 CVM 实例名称"
    cat <<EOF
  --instance-id <id>      实例 ID（必需）
  --name <name>           新名称（必需）
  --region <region>       地域
  -h, --help              显示帮助

示例:
  $0 --instance-id ins-xxx --name "my-web-server"
  $0 --instance-id ins-xxx --name "prod-api-01"

EOF
}

check_api_prerequisites
load_defaults

INSTANCE_ID="" NAME=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --instance-id) INSTANCE_ID="$2"; shift 2 ;;
        --name)        NAME="$2"; shift 2 ;;
        --region)      REGION="$2"; shift 2 ;;
        -h|--help)     show_help; exit 0 ;;
        *)             error "未知参数: $1"; exit 1 ;;
    esac
done

[[ -z "$INSTANCE_ID" ]] && { error "缺少: --instance-id"; exit 1; }
[[ -z "$NAME" ]] && { error "缺少: --name"; exit 1; }
validate_region "$REGION"

info "修改实例名称: $INSTANCE_ID -> $NAME"
execute_tccli cvm ModifyInstancesAttribute \
    --region "$REGION" \
    --InstanceIds "[\"$INSTANCE_ID\"]" \
    --InstanceName "$NAME" > /dev/null

success "实例名称已修改为: $NAME"
