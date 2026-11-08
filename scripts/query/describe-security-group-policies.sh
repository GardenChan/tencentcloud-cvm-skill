#!/bin/bash
# Read-only ingress/egress policy inspection; never creates or opens ports.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"
REGION="${TENCENT_CVM_DEFAULT_REGION:-$DEFAULT_REGION}"
SG_ID="" JSON_OUTPUT=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            printf '%s\n' '用法: describe-security-group-policies.sh --sg-id <sg-id> [--region <region>] [--json]' '查询完整入站和出站规则，包括协议、端口、来源/目标和动作；不修改规则。'
            exit 0 ;;
        --json) JSON_OUTPUT=true; shift ;;
        --sg-id|--region)
            query_value "$@" || exit $?
            if [[ "$1" == --sg-id ]]; then SG_ID="$2"; else REGION="$2"; fi
            shift 2 ;;
        *) error "未知参数: $1"; exit 2 ;;
    esac
done
[[ "$SG_ID" =~ ^sg-[a-zA-Z0-9]+$ ]] || { error '需要有效 --sg-id'; exit 2; }
check_api_prerequisites
validate_region "$REGION"
result=$(execute_tccli vpc DescribeSecurityGroupPolicies --region "$REGION" --SecurityGroupId "$SG_ID") || exit $?
printf '%s\n' "$result" | jq -e '.SecurityGroupPolicySet | type == "object"' >/dev/null || { error '响应缺少安全组规则'; exit 1; }
if [[ "$JSON_OUTPUT" == true ]]; then printf '%s\n' "$result"; exit 0; fi
printf '%s\n' "$result" | jq -r '
  .SecurityGroupPolicySet | "规则版本: \(.Version)\n入站规则:", (.Ingress // [] | .[] | tojson),
  "出站规则:", (.Egress // [] | .[] | tojson)'
