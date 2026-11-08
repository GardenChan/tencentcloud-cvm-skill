#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"
source "$SCRIPT_DIR/lifecycle-common.sh"
load_defaults
INSTANCE_ID="" ASSUME_YES=false WAIT=false TIMEOUT=300 FORCE=false STOPPED_MODE=KEEP_CHARGING
while [[ $# -gt 0 ]]; do
    case "$1" in
        --instance-id) lc_value "$@"; INSTANCE_ID="$2"; shift 2 ;;
        --region) lc_value "$@"; REGION="$2"; shift 2 ;;
        --yes) ASSUME_YES=true; shift ;;
        --wait) WAIT=true; shift ;;
        --timeout) lc_value "$@"; TIMEOUT="$2"; shift 2 ;;
        --force) FORCE=true; shift ;;
        --stopped-mode) lc_value "$@"; STOPPED_MODE="$2"; shift 2 ;;
        -h|--help)
            cat <<'HELP'
用法: stop-instance.sh --instance-id <id> [--region <region>] [--yes] [--wait] [--timeout 300]
停止实例（中断业务）。--yes 表示已经批准本次操作；否则先展示目标并确认一次。
  --force 直接强制断电/重启，可能损坏数据；默认仅软操作
  --stopped-mode KEEP_CHARGING|STOP_CHARGING，默认 KEEP_CHARGING
HELP
            exit 0 ;;
        *) error "未知参数: $1"; exit 2 ;;
    esac
done
lc_instance "$INSTANCE_ID"
[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] || { error "--timeout 需要正整数"; exit 2; }
check_api_prerequisites
validate_region "$REGION"
ids=$(jq -cn --arg id "$INSTANCE_ID" '[$id]')
ARGS=(--region "$REGION" --InstanceIds "$ids")

STOP_TYPE=SOFT
[[ "$FORCE" == true ]] && STOP_TYPE=HARD
ARGS+=(--StopType "$STOP_TYPE")
case "$STOPPED_MODE" in KEEP_CHARGING|STOP_CHARGING) ;; *) error "无效关机计费模式"; exit 2 ;; esac
ARGS+=(--StoppedMode "$STOPPED_MODE")

lc_confirm "确认停止实例（中断业务）？"
result=$(execute_tccli cvm StopInstances "${ARGS[@]}")
success "停止实例（中断业务）请求已提交，尚未确认完成"
printf '%s\n' "$result"
lc_wait "$result" STOPPED
