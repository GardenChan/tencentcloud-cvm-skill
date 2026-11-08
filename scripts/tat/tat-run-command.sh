#!/bin/bash
# TAT single-command diagnostics; all target instances must complete before success.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

show_help() {
    cat <<'HELP'
用法: tat-run-command.sh --instance-id <ids> --cmd <command> [选项]
  --instance-id <ids>   目标 ID，逗号分隔，最多 200 个
  --cmd <command>       单条只读诊断命令（与 SSH 共用精确参数校验）
  --region <region>     地域
  --timeout <seconds>  云端命令超时，1–86400 秒，默认 60
  --wait               等待所有目标实例到达终态
  --wait-timeout <n>   本地等待上限，默认命令超时 + 120 秒
  --interval <n>       查询间隔，1–60 秒，默认 2
  --json               输出 JSON；--wait 时输出每个实例和汇总状态
  -h, --help           显示帮助
退出码：0=提交成功/全部执行成功，1=失败，2=参数错误，124=本地等待超时。
HELP
}

REGION="${TENCENT_CVM_DEFAULT_REGION:-$DEFAULT_REGION}"
INSTANCE_IDS="" CMD="" TIMEOUT=60 WAIT_TIMEOUT="" INTERVAL=2 WAIT=false JSON_OUTPUT=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) show_help; exit 0 ;;
        --wait) WAIT=true; shift ;;
        --json) JSON_OUTPUT=true; shift ;;
        --instance-id|--cmd|--region|--timeout|--wait-timeout|--interval)
            query_value "$@" || exit $?
            case "$1" in
                --instance-id) INSTANCE_IDS="$2" ;; --cmd) CMD="$2" ;; --region) REGION="$2" ;;
                --timeout) TIMEOUT="$2" ;; --wait-timeout) WAIT_TIMEOUT="$2" ;; --interval) INTERVAL="$2" ;;
            esac
            shift 2 ;;
        *) error "未知参数: $1"; exit 2 ;;
    esac
done
[[ -n "$INSTANCE_IDS" && -n "$CMD" ]] || { error '需要 --instance-id 和 --cmd'; exit 2; }
query_integer "$TIMEOUT" --timeout 1 86400 || exit $?
query_integer "$INTERVAL" --interval 1 60 || exit $?
WAIT_TIMEOUT="${WAIT_TIMEOUT:-$((TIMEOUT + 120))}"
query_integer "$WAIT_TIMEOUT" --wait-timeout 1 172800 || exit $?
check_api_prerequisites
check_python_installed
validate_region "$REGION"
IDS_JSON=$(query_ids_json "$INSTANCE_IDS" 200) || exit 2
CMD=$(python3 "$SCRIPT_DIR/../ops/validate-command.py" --command "$CMD") || exit 2
CMD_BASE64=$(printf '%s' "$CMD" | base64 | tr -d '\r\n')
result=$(execute_tccli tat RunCommand --region "$REGION" --InstanceIds "$IDS_JSON" \
    --Content "$CMD_BASE64" --CommandType SHELL --Timeout "$TIMEOUT" \
    --CommandName "skill-diagnostic-$(date +%s)") || exit $?
invocation_id=$(printf '%s\n' "$result" | jq -er '.InvocationId | select(type == "string" and length > 0)') || {
    error '响应缺少 InvocationId；不要自动重新提交命令'; exit 1;
}
success "命令已提交，执行 ID: $invocation_id"
if [[ "$WAIT" != true ]]; then
    if [[ "$JSON_OUTPUT" == true ]]; then printf '%s\n' "$result"; else printf '执行 ID: %s\n' "$invocation_id"; fi
    exit 0
fi

# Poll all pages and all requested targets. A failed target does not hide still-running targets.
deadline=$((SECONDS + WAIT_TIMEOUT))
while :; do
    tasks=$(tat_tasks "$invocation_id" "$REGION" false) || exit $?
    combined=$(tat_result "$invocation_id" "$IDS_JSON" "$tasks")
    state=$(printf '%s\n' "$combined" | jq -r '.Summary.Status')
    case "$state" in
        SUCCESS) tat_print_result "$combined" "$JSON_OUTPUT" true; success '所有目标执行成功'; exit 0 ;;
        FAILED) tat_print_result "$combined" "$JSON_OUTPUT" true; error '部分或全部目标执行失败'; exit 1 ;;
    esac
    if (( SECONDS >= deadline )); then
        combined=$(printf '%s\n' "$combined" | jq '.Summary.Status = "WAIT_TIMEOUT"')
        tat_print_result "$combined" "$JSON_OUTPUT" true
        error "本地等待超时，命令可能仍在运行；继续查询执行 ID: $invocation_id"
        exit 124
    fi
    remaining=$((deadline - SECONDS))
    pause="$INTERVAL"
    (( pause <= remaining )) || pause="$remaining"
    sleep "$pause"
done
