#!/bin/bash
# reset-instance.sh - 重装腾讯云 CVM 实例系统

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

show_help() {
    print_help_header "reset-instance.sh" "重装腾讯云 CVM 实例系统（危险操作，数据会丢失）"
    cat <<EOF
  --instance-id <id>      实例 ID（必需）
  --image-id <id>         新镜像 ID（可选，默认使用当前镜像）
  --region <region>       地域
  --password <pwd>        新密码（可选，自动生成）
  --keep-data             保留数据盘（默认保留）
  -h, --help              显示帮助

注意:
  重装系统会清除系统盘数据，请确保已备份重要数据！

示例:
  $0 --instance-id ins-xxx
  $0 --instance-id ins-xxx --image-id img-xxx
  $0 --instance-id ins-xxx --password "NewP@ssw0rd"

EOF
}

check_api_prerequisites
load_defaults

INSTANCE_ID="" IMAGE_ID="" PASSWORD=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --instance-id) INSTANCE_ID="$2"; shift 2 ;;
        --image-id)    IMAGE_ID="$2"; shift 2 ;;
        --region)      REGION="$2"; shift 2 ;;
        --password)    PASSWORD="$2"; shift 2 ;;
        -h|--help)     show_help; exit 0 ;;
        *)             error "未知参数: $1"; exit 1 ;;
    esac
done

[[ -z "$INSTANCE_ID" ]] && { error "缺少: --instance-id"; exit 1; }
validate_region "$REGION"

# 生成密码
if [[ -z "$PASSWORD" ]]; then
    PASSWORD=$(generate_password 16)
    info "已生成随机密码"
fi

# 确认操作
warn "警告: 重装系统将清除系统盘所有数据！"
echo ""
echo "实例 ID:    $INSTANCE_ID"
echo "地域:       $REGION"
[[ -n "$IMAGE_ID" ]] && echo "新镜像:     $IMAGE_ID"
echo ""

confirm "确认重装系统？" || { info "已取消"; exit 0; }

# 构建参数
ARGS="--region $REGION --InstanceId $INSTANCE_ID"
[[ -n "$IMAGE_ID" ]] && ARGS="$ARGS --ImageId $IMAGE_ID"
ARGS="$ARGS --LoginSettings '{\"Password\":\"$PASSWORD\"}'"

info "重装实例 $INSTANCE_ID ..."
eval "execute_tccli cvm ResetInstance $ARGS" > /dev/null

# 更新密码存储
save_instance_password "$INSTANCE_ID" "$PASSWORD" "" "$REGION"

success "重装请求已发送，请等待实例重启完成"
info "新密码: $PASSWORD"
