#!/bin/bash
# tat-agent-status.sh - 查询实例 TAT Agent 状态

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

show_help() {
    print_help_header "tat-agent-status.sh" "查询实例 TAT（自动化助手）Agent 状态"
    cat <<EOF
  --instance-id <id>      实例 ID（可多个，逗号分隔）
  --region <region>       地域，默认 $DEFAULT_REGION
  --limit <n>             返回数量，默认 20
  -h, --help              显示帮助

说明:
  TAT Agent 是腾讯云自动化助手的客户端，安装后可通过云 API 执行命令，
  无需 SSH 密码和公网 IP。

状态说明:
  Online   - Agent 在线，可执行命令
  Offline  - Agent 离线，需检查实例或重装 Agent

示例:
  $0
  $0 --instance-id ins-xxx
  $0 --instance-id ins-xxx,ins-yyy

EOF
}

check_api_prerequisites
load_defaults

INSTANCE_IDS="" LIMIT=20

while [[ $# -gt 0 ]]; do
    case $1 in
        --instance-id) INSTANCE_IDS="$2"; shift 2 ;;
        --region)      REGION="$2"; shift 2 ;;
        --limit)       LIMIT="$2"; shift 2 ;;
        -h|--help)     show_help; exit 0 ;;
        *)             error "未知参数: $1"; exit 1 ;;
    esac
done

validate_region "$REGION"

info "查询 TAT Agent 状态 (地域: $REGION)..."

# 构建参数
ARGS="--region $REGION --Limit $LIMIT"
if [[ -n "$INSTANCE_IDS" ]]; then
    IDS_JSON=$(echo "$INSTANCE_IDS" | tr ',' '\n' | jq -R . | jq -s .)
    ARGS="$ARGS --InstanceIds '$IDS_JSON'"
fi

result=$(eval "execute_tccli tat DescribeAutomationAgentStatus $ARGS")

total=$(echo "$result" | jq -r '.TotalCount')
print_section "TAT Agent 状态 (共 $total 个)"
echo ""

printf "%-20s %-10s %-20s %s\n" "实例 ID" "状态" "Agent 版本" "最后心跳"
printf "%-20s %-10s %-20s %s\n" "--------" "------" "----------" "--------"

echo "$result" | jq -r '.AutomationAgentSet[] | "\(.InstanceId)\t\(.AgentStatus)\t\(.Version // "-")\t\(.LastHeartbeatTime // "-")"' | while read -r line; do
    id=$(echo "$line" | cut -f1)
    status=$(echo "$line" | cut -f2)
    version=$(echo "$line" | cut -f3)
    heartbeat=$(echo "$line" | cut -f4)
    
    case "$status" in
        Online)  status_display="${GREEN}Online${NC}" ;;
        Offline) status_display="${RED}Offline${NC}" ;;
        *)       status_display="$status" ;;
    esac
    
    printf "%-20s " "$id"
    echo -e "$status_display\t$version\t$heartbeat"
done

echo ""
success "查询完成"
