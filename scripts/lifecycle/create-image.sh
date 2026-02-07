#!/bin/bash
# create-image.sh - 从实例制作自定义镜像

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

show_help() {
    print_help_header "create-image.sh" "从实例制作自定义镜像"
    cat <<EOF
  --instance-id <id>      实例 ID（必需）
  --image-name <name>     镜像名称（必需）
  --description <desc>    镜像描述
  --region <region>       地域
  --force-poweroff        强制关机后制作（默认不关机）
  --dry-run               仅验证参数，不实际创建
  -h, --help              显示帮助

注意:
  建议在实例停止状态下制作镜像，以确保数据一致性。
  若实例运行中，建议先停止实例或使用 --force-poweroff。

示例:
  $0 --instance-id ins-xxx --image-name "my-app-v1.0"
  $0 --instance-id ins-xxx --image-name "backup-20260206" --description "系统备份"
  $0 --instance-id ins-xxx --image-name "web-template" --force-poweroff

EOF
}

check_api_prerequisites
load_defaults

INSTANCE_ID="" IMAGE_NAME="" DESCRIPTION="" FORCE_POWEROFF="FALSE" DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --instance-id)    INSTANCE_ID="$2"; shift 2 ;;
        --image-name)     IMAGE_NAME="$2"; shift 2 ;;
        --description)    DESCRIPTION="$2"; shift 2 ;;
        --region)         REGION="$2"; shift 2 ;;
        --force-poweroff) FORCE_POWEROFF="TRUE"; shift ;;
        --dry-run)        DRY_RUN=true; shift ;;
        -h|--help)        show_help; exit 0 ;;
        *)                error "未知参数: $1"; exit 1 ;;
    esac
done

[[ -z "$INSTANCE_ID" ]] && { error "缺少: --instance-id"; exit 1; }
[[ -z "$IMAGE_NAME" ]] && { error "缺少: --image-name"; exit 1; }
validate_region "$REGION"

# 显示配置
print_section "镜像配置"
echo "实例 ID:    $INSTANCE_ID"
echo "镜像名称:   $IMAGE_NAME"
[[ -n "$DESCRIPTION" ]] && echo "描述:       $DESCRIPTION"
echo "地域:       $REGION"
echo "强制关机:   $FORCE_POWEROFF"
echo "=================================="
echo ""

# DryRun 模式
if [[ "$DRY_RUN" == "true" ]]; then
    info "DryRun 模式：验证参数..."
    
    ARGS="--region $REGION --InstanceId $INSTANCE_ID --ImageName \"$IMAGE_NAME\" --DryRun true"
    [[ -n "$DESCRIPTION" ]] && ARGS="$ARGS --ImageDescription \"$DESCRIPTION\""
    
    if eval "execute_tccli cvm CreateImage $ARGS" > /dev/null 2>&1; then
        success "参数验证通过"
    else
        error "参数验证失败"
        exit 1
    fi
    exit 0
fi

# 确认操作
confirm "确认制作镜像？" || { info "已取消"; exit 0; }

# 构建参数
ARGS="--region $REGION --InstanceId $INSTANCE_ID --ImageName \"$IMAGE_NAME\" --ForcePoweroff $FORCE_POWEROFF"
[[ -n "$DESCRIPTION" ]] && ARGS="$ARGS --ImageDescription \"$DESCRIPTION\""

info "制作镜像中..."
result=$(eval "execute_tccli cvm CreateImage $ARGS")

image_id=$(echo "$result" | jq -r '.ImageId')

if [[ -n "$image_id" && "$image_id" != "null" ]]; then
    success "镜像创建请求已提交"
    echo ""
    echo "镜像 ID:    $image_id"
    echo "镜像名称:   $IMAGE_NAME"
    echo ""
    info "镜像制作中，可通过以下命令查看状态："
    echo "  ./scripts/query/describe-images.sh --image-id $image_id"
else
    error "镜像创建失败"
    echo "$result"
    exit 1
fi
