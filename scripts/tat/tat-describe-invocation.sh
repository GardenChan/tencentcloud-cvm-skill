#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"
REGION="${TENCENT_CVM_DEFAULT_REGION:-$DEFAULT_REGION}"
INVOCATION_ID="" SHOW_OUTPUT=false JSON_OUTPUT=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            cat <<'HELP'
用法: tat-describe-invocation.sh --invocation-id <id> [选项]
  --region <region>  地域
  --show-output      显示输出；JSON 中保留 API Base64 原文
  --json             输出执行概览、所有分页任务及汇总 JSON
  -h, --help         显示帮助
读取成功不代表任务成功，请检查 Summary.Status 和每台实例的退出码。
HELP
            exit 0 ;;
        --show-output) SHOW_OUTPUT=true; shift ;;
        --json) JSON_OUTPUT=true; shift ;;
        --invocation-id|--region)
            query_value "$@" || exit $?
            if [[ "$1" == --invocation-id ]]; then INVOCATION_ID="$2"; else REGION="$2"; fi
            shift 2 ;;
        *) error "未知参数: $1"; exit 2 ;;
    esac
done
[[ "$INVOCATION_ID" =~ ^inv-[a-zA-Z0-9]+$ ]] || { error '需要有效 --invocation-id'; exit 2; }
check_api_prerequisites
validate_region "$REGION"
ids=$(jq -cn --arg id "$INVOCATION_ID" '[$id]')
overview=$(execute_tccli tat DescribeInvocations --region "$REGION" --InvocationIds "$ids") || exit $?
invocation=$(printf '%s\n' "$overview" | jq -ce --arg id "$INVOCATION_ID" '.InvocationSet[] | select(.InvocationId == $id)') || { error '未找到执行记录'; exit 1; }
expected=$(printf '%s\n' "$invocation" | jq -c '[.InvocationTaskBasicInfoSet[]?.InstanceId] | unique')
hide=true
[[ "$SHOW_OUTPUT" != true ]] || hide=false
tasks=$(tat_tasks "$INVOCATION_ID" "$REGION" "$hide") || exit $?
# If the overview has not populated task IDs yet, do not invent completion.
combined=$(tat_result "$INVOCATION_ID" "$expected" "$tasks")
combined=$(printf '%s\n%s\n' "$combined" "$invocation" | jq -sc '.[0] + {Invocation:.[1]}')
if [[ "$expected" == '[]' ]]; then combined=$(printf '%s\n' "$combined" | jq '.Summary.Status = "UNKNOWN"'); fi
tat_print_result "$combined" "$JSON_OUTPUT" "$SHOW_OUTPUT"
