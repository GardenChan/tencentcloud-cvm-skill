#!/bin/bash
# tat-describe-invocation.sh - 查询 TAT 命令执行结果

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

show_help() {
    print_help_header "tat-describe-invocation.sh" "查询 TAT 命令执行结果"
    cat <<EOF
  --invocation-id <id>    执行 ID（必需）
  --region <region>       地域，默认 $DEFAULT_REGION
  --show-output           显示命令输出内容
  -h, --help              显示帮助

状态说明:
  PENDING    - 等待下发
  DELIVERING - 下发中
  RUNNING    - 运行中
  SUCCESS    - 执行成功
  FAILED     - 执行失败
  TIMEOUT    - 执行超时

示例:
  $0 --invocation-id inv-xxx
  $0 --invocation-id inv-xxx --show-output

EOF
}

check_api_prerequisites
load_defaults

INVOCATION_ID="" SHOW_OUTPUT=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --invocation-id) INVOCATION_ID="$2"; shift 2 ;;
        --region)        REGION="$2"; shift 2 ;;
        --show-output)   SHOW_OUTPUT=true; shift ;;
        -h|--help)       show_help; exit 0 ;;
        *)               error "未知参数: $1"; exit 1 ;;
    esac
done

[[ -z "$INVOCATION_ID" ]] && { error "缺少: --invocation-id"; exit 1; }
validate_region "$REGION"

info "查询执行结果 (执行 ID: $INVOCATION_ID)..."

# 查询执行概览
result=$(execute_tccli tat DescribeInvocations \
    --region "$REGION" \
    --InvocationIds "[\"$INVOCATION_ID\"]")

total=$(echo "$result" | jq -r '.TotalCount')
if [[ "$total" == "0" ]]; then
    error "未找到执行记录: $INVOCATION_ID"
    exit 1
fi

print_section "执行概览"
echo "$result" | jq -r '.InvocationSet[] | 
    "执行 ID:     \(.InvocationId)\n" +
    "命令 ID:     \(.CommandId)\n" +
    "状态:        \(.InvocationStatus)\n" +
    "创建时间:    \(.CreatedTime)\n" +
    "结束时间:    \(.EndTime // "进行中")"'

# 查询每个实例的执行详情
echo ""
print_section "实例执行详情"

HIDE_OUTPUT="true"
[[ "$SHOW_OUTPUT" == "true" ]] && HIDE_OUTPUT="false"

task_result=$(execute_tccli tat DescribeInvocationTasks \
    --region "$REGION" \
    --Filters "[{\"Name\":\"invocation-id\",\"Values\":[\"$INVOCATION_ID\"]}]" \
    --HideOutput "$HIDE_OUTPUT")

echo "$task_result" | jq -r '.InvocationTaskSet[] | 
    "实例 ID:     \(.InstanceId)\n" +
    "状态:        \(.TaskStatus)\n" +
    "开始时间:    \(.StartTime // "-")\n" +
    "结束时间:    \(.EndTime // "-")\n" +
    "退出码:      \(.TaskResult.ExitCode // "-")\n" +
    "----------------------------------------"'

# 显示输出内容
if [[ "$SHOW_OUTPUT" == "true" ]]; then
    echo ""
    print_section "命令输出"
    echo "$task_result" | jq -r '.InvocationTaskSet[] | 
        "=== 实例: \(.InstanceId) ===\n" +
        (if .TaskResult.Output then (.TaskResult.Output | @base64d) else "无输出" end) +
        "\n"'
fi

success "查询完成"
