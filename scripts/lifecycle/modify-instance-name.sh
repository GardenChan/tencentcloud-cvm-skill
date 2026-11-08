#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"
source "$SCRIPT_DIR/lifecycle-common.sh"
load_defaults
INSTANCE_ID="" NAME="" ASSUME_YES=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --instance-id) lc_value "$@"; INSTANCE_ID="$2"; shift 2 ;;
        --name) lc_value "$@"; NAME="$2"; shift 2 ;;
        --region) lc_value "$@"; REGION="$2"; shift 2 ;;
        --yes) ASSUME_YES=true; shift ;;
        -h|--help) printf '%s\n' '用法: modify-instance-name.sh --instance-id <id> --name <name> [--region <region>] [--yes]'; exit 0 ;;
        *) error "未知参数: $1"; exit 2 ;;
    esac
done
lc_instance "$INSTANCE_ID"
[[ -n "$NAME" && ${#NAME} -le 128 ]] || { error "名称长度须为 1–128"; exit 2; }
check_api_prerequisites
validate_region "$REGION"
info "新名称: $NAME"
lc_confirm "确认修改实例名称？"
ids=$(jq -cn --arg id "$INSTANCE_ID" '[$id]')
result=$(execute_tccli cvm ModifyInstancesAttribute --region "$REGION" --InstanceIds "$ids" --InstanceName "$NAME")
success "修改实例名称请求已提交"
printf '%s\n' "$result"
