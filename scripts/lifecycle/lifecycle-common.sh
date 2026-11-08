#!/bin/bash
# Helpers for lifecycle entrypoints; no cloud calls when sourced.
lc_value() {
    [[ $# -ge 2 && -n "$2" ]] || { error "$1 需要参数值"; exit 2; }
}
lc_instance() {
    [[ "$1" =~ ^ins-[A-Za-z0-9-]+$ ]] || { error "无效实例 ID"; exit 2; }
}
lc_confirm() {
    info "账号: $(tccli_profile)；地域: ${REGION}；目标: $INSTANCE_ID"
    [[ "$ASSUME_YES" == true ]] && return 0
    confirm "$1" || { info "已取消"; exit 0; }
}
lc_wait() {
    local result="$1" state="$2" request_id
    [[ "$WAIT" == true ]] || return 0
    request_id=$(printf '%s\n' "$result" | jq -r '(.Response // .).RequestId // empty')
    [[ -n "$request_id" ]] || { error "响应缺少 RequestId，无法确认本次操作完成"; return 1; }
    local args=(--instance-id "$INSTANCE_ID" --region "$REGION" --state "$state" --timeout "$TIMEOUT")
    [[ -n "$request_id" ]] && args+=(--request-id "$request_id")
    bash "$SCRIPT_DIR/wait-instance.sh" "${args[@]}"
}
