#!/bin/bash
# describe-instance-status.sh - 查询腾讯云 CVM 实例状态

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

show_help() {
    print_help_header "describe-instance-status.sh" "查询腾讯云 CVM 实例状态"
    cat <<EOF
  --region <region>       地域，默认 $DEFAULT_REGION
  --instance-id <id>      按实例 ID 过滤（可多个，逗号分隔）
  --limit <n>             返回数量，默认 20
  -h, --help              显示帮助

状态说明:
  PENDING      - 创建中
  RUNNING      - 运行中
  STOPPED      - 已停止
  REBOOTING    - 重启中
  STARTING     - 启动中
  STOPPING     - 停止中
  TERMINATING  - 销毁中
  SHUTDOWN     - 已销毁

示例:
  $0
  $0 --instance-id ins-xxx
  $0 --instance-id ins-xxx,ins-yyy,ins-zzz
  $0 --region ap-beijing

EOF
}

check_api_prerequisites
load_defaults

INSTANCE_IDS="" LIMIT=20

while [[ $# -gt 0 ]]; do
    case $1 in
        --region)      REGION="$2"; shift 2 ;;
        --instance-id) INSTANCE_IDS="$2"; shift 2 ;;
        --limit)       LIMIT="$2"; shift 2 ;;
        -h|--help)     show_help; exit 0 ;;
        *)             error "未知参数: $1"; exit 1 ;;
    esac
done

validate_region "$REGION"

info "查询实例状态 (地域: $REGION)..."

# 构建参数
ARGS="--region $REGION --Limit $LIMIT"
if [[ -n "$INSTANCE_IDS" ]]; then
    # 支持逗号分隔的多个 ID
    IDS_JSON=$(echo "$INSTANCE_IDS" | tr ',' '\n' | jq -R . | jq -s .)
    ARGS="$ARGS --InstanceIds '$IDS_JSON'"
fi

result=$(eval "execute_tccli cvm DescribeInstancesStatus $ARGS")

total=$(echo "$result" | jq -r '.TotalCount')
print_section "实例状态 (共 $total 个)"
echo ""

# 状态颜色映射
echo "$result" | jq -r '.InstanceStatusSet[] | "\(.InstanceId)\t\(.InstanceState)"' | while read -r line; do
    id=$(echo "$line" | cut -f1)
    state=$(echo "$line" | cut -f2)
    
    case "$state" in
        RUNNING)     state_color="${GREEN}${state}${NC}" ;;
        STOPPED)     state_color="${YELLOW}${state}${NC}" ;;
        PENDING|REBOOTING|STARTING|STOPPING) state_color="${BLUE}${state}${NC}" ;;
        TERMINATING|SHUTDOWN) state_color="${RED}${state}${NC}" ;;
        *)           state_color="$state" ;;
    esac
    
    echo -e "$id\t$state_color"
done

echo ""
success "查询完成"
