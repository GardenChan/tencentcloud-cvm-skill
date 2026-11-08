#!/bin/bash
# Poll state and, when supplied, the exact latest-operation RequestId.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"
source "$SCRIPT_DIR/lifecycle-common.sh"
load_defaults
INSTANCE_ID="" STATE=RUNNING TIMEOUT=300 INTERVAL=5 REQUEST_ID="" CREATED_INSTANCE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --instance-id|--region|--state|--timeout|--interval|--request-id)
            lc_value "$@"
            case "$1" in
                --instance-id) INSTANCE_ID="$2" ;;
                --region) REGION="$2" ;;
                --state) STATE="$2" ;;
                --timeout) TIMEOUT="$2" ;;
                --interval) INTERVAL="$2" ;;
                --request-id) REQUEST_ID="$2" ;;
            esac; shift 2 ;;
        --created-instance) CREATED_INSTANCE=true; shift ;;
        -h|--help)
            printf '%s\n' '用法: wait-instance.sh --instance-id <id> [--region <region>] [--state RUNNING|STOPPED|ABSENT] [--request-id <id>] [--created-instance] [--timeout 300] [--interval 5]' '只读等待；--request-id 防止把旧操作的完成状态误认为本次完成。超时退出 124。' '--created-instance 仅用于 RunInstances 返回的新实例 ID 和 RequestId：目标必须是 RUNNING；仅操作元数据全部缺失时允许按实例状态确认。'
            exit 0 ;;
        *) error "未知参数: $1"; exit 2 ;;
    esac
done
lc_instance "$INSTANCE_ID"
case "$STATE" in RUNNING|STOPPED|ABSENT) ;; *) error "无效目标状态"; exit 2 ;; esac
if [[ "$CREATED_INSTANCE" == true && ( "$STATE" != RUNNING || -z "$REQUEST_ID" ) ]]; then
    error "--created-instance 需要本次 RunInstances 的 --request-id，且目标状态必须为 RUNNING"
    exit 2
fi
[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ && "$INTERVAL" =~ ^[1-9][0-9]*$ ]] || { error "等待时长必须为正整数"; exit 2; }
check_api_prerequisites
validate_region "$REGION"
ids=$(jq -cn --arg id "$INSTANCE_ID" '[$id]')
started=$SECONDS
while true; do
    result=$(execute_tccli cvm DescribeInstances --region "$REGION" --InstanceIds "$ids")
    printf '%s\n' "$result" | jq -e '(.Response // .).InstanceSet | type == "array"' >/dev/null || { error "实例查询响应缺少 InstanceSet，不能判定完成"; exit 1; }
    matches=$(printf '%s\n' "$result" | jq --arg id "$INSTANCE_ID" '[(.Response // .).InstanceSet[] | select(.InstanceId == $id)] | length')
    [[ "$matches" -le 1 ]] || { error "实例查询返回重复 ID，不能判定完成"; exit 1; }
    instance=$(printf '%s\n' "$result" | jq -c --arg id "$INSTANCE_ID" '(.Response // .).InstanceSet[]? | select(.InstanceId == $id)')
    if [[ -z "$instance" ]]; then
        if [[ "$STATE" == ABSENT ]]; then
            success "目标实例已不在查询结果中: $INSTANCE_ID"
            printf '%s\n' "$result"
            exit 0
        fi
    else
        current=$(printf '%s\n' "$instance" | jq -r '.InstanceState')
        operation=$(printf '%s\n' "$instance" | jq -r '.LatestOperationState // empty')
        operation_id=$(printf '%s\n' "$instance" | jq -r '.LatestOperationRequestId // empty')
        if [[ "$current" == LAUNCH_FAILED ]] || { [[ -n "$REQUEST_ID" && "$operation_id" == "$REQUEST_ID" && "$operation" == FAILED ]]; }; then
            error "实例操作失败: $INSTANCE_ID"
            printf '%s\n' "$instance" | jq '{InstanceId, InstanceState, LatestOperationState, LatestOperationRequestId, LatestOperationErrorMsg}' >&2
            exit 1
        fi
        # Newly created instances can omit all latest-operation metadata. Only
        # the ID returned by RunInstances may use this fallback; existing
        # lifecycle operations must still match their own request and SUCCESS.
        creation_ready=false
        if [[ "$CREATED_INSTANCE" == true ]] && printf '%s\n' "$instance" | jq -e '[.LatestOperation, .LatestOperationState, .LatestOperationRequestId] | all(. == null)' >/dev/null; then
            creation_ready=true
        fi
        if [[ "$current" == "$STATE" ]] && { [[ -z "$REQUEST_ID" ]] || [[ "$operation_id" == "$REQUEST_ID" && "$operation" == SUCCESS ]] || [[ "$creation_ready" == true ]]; }; then
            host=$(printf '%s\n' "$instance" | jq -r '.PublicIpAddresses[0] // .PrivateIpAddresses[0] // empty')
            if [[ -n "$host" ]] && declare -F save_instance_connection >/dev/null; then
                # Preserve a deliberately selected login user; otherwise use the
                # provider's actual default instead of assuming root (e.g. Ubuntu).
                login_user=$(instance_store get --id "$INSTANCE_ID" --field user 2>/dev/null) || login_user=""
                if [[ -z "$login_user" ]]; then
                    login_user=$(printf '%s\n' "$instance" | jq -r '.DefaultLoginUser | if type == "string" then select(test("^[a-zA-Z_][a-zA-Z0-9_.-]*$")) else empty end')
                fi
                save_instance_connection "$INSTANCE_ID" "$host" "$REGION" "$login_user" || warn "状态已完成，但本地连接信息未能更新"
            fi
            success "实例已达到 $STATE: $INSTANCE_ID"
            printf '%s\n' "$instance"
            exit 0
        fi
    fi
    elapsed=$((SECONDS - started))
    if [[ $elapsed -ge $TIMEOUT ]]; then
        error "等待超时: ${INSTANCE_ID}，目标 ${STATE}；请求未自动重试"
        exit 124
    fi
    remaining=$((TIMEOUT - elapsed))
    delay=$INTERVAL
    [[ $delay -gt $remaining ]] && delay=$remaining
    sleep "$delay"
done
