#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"
source "$SCRIPT_DIR/lifecycle-common.sh"
load_defaults
INSTANCE_ID="" IMAGE_NAME="" DESCRIPTION="" FORCE_POWEROFF=false DRY_RUN=false ASSUME_YES=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --instance-id) lc_value "$@"; INSTANCE_ID="$2"; shift 2 ;;
        --image-name) lc_value "$@"; IMAGE_NAME="$2"; shift 2 ;;
        --description) lc_value "$@"; DESCRIPTION="$2"; shift 2 ;;
        --region) lc_value "$@"; REGION="$2"; shift 2 ;;
        --force-poweroff) FORCE_POWEROFF=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --yes) ASSUME_YES=true; shift ;;
        -h|--help)
            printf '%s\n' '用法: create-image.sh --instance-id <id> --image-name <name> [--description <text>] [--region <region>] [--force-poweroff] [--dry-run] [--yes]' '开机制作可能无法保证数据一致性；--force-poweroff 会关机。--dry-run 仅做预检查。'
            exit 0 ;;
        *) error "未知参数: $1"; exit 2 ;;
    esac
done
lc_instance "$INSTANCE_ID"
[[ -n "$IMAGE_NAME" ]] || { error "缺少 --image-name"; exit 2; }
check_api_prerequisites
validate_region "$REGION"
ARGS=(--region "$REGION" --InstanceId "$INSTANCE_ID" --ImageName "$IMAGE_NAME" --ForcePoweroff "$FORCE_POWEROFF")
[[ -n "$DESCRIPTION" ]] && ARGS+=(--ImageDescription "$DESCRIPTION")
if [[ "$DRY_RUN" == true ]]; then
    result=$(execute_tccli cvm CreateImage "${ARGS[@]}" --DryRun true)
    printf '%s\n' "$result" | jq -e '(.Response // .).RequestId | type == "string" and length > 0' >/dev/null || { error "预检查响应无有效 RequestId"; exit 1; }
    success "镜像预检查通过，未创建"
else
    info "镜像名称: ${IMAGE_NAME}；强制关机: $FORCE_POWEROFF"
    lc_confirm "确认制作镜像（可能产生镜像/快照费用）？"
    result=$(execute_tccli cvm CreateImage "${ARGS[@]}")
    image_id=$(printf '%s\n' "$result" | jq -r '(.Response // .).ImageId // empty')
    [[ "$image_id" =~ ^img-[A-Za-z0-9-]+$ ]] || { error "响应无有效镜像 ID，请先查询实际结果"; exit 1; }
    success "镜像请求已提交: ${image_id}；需查询镜像状态确认可用"
fi
printf '%s\n' "$result"
