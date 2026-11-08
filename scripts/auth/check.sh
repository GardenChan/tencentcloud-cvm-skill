#!/bin/bash
# 通过只读 API 检查认证，不检查或展示凭证文件内容。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

show_help() {
    cat <<'EOF'
用法: check.sh [--profile <name>] [--region <region>]

调用一次 CVM DescribeRegions，检查当前认证及 API 连通性。
  --profile <name>  指定账号配置，优先于 TENCENT_CVM_PROFILE / TCCLI_PROFILE
  --region <region> 地域，默认 TENCENT_CVM_DEFAULT_REGION 或 ap-guangzhou
  -h, --help        显示帮助，不调用 API

检查成功只代表 DescribeRegions 可用，不代表其他 API 也有权限。
EOF
}

load_defaults
while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile|--region)
            [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || { error "$1 需要参数值"; exit 2; }
            if [[ "$1" == --profile ]]; then
                export TENCENT_CVM_PROFILE="$2"
            else
                REGION="$2"
            fi
            shift 2 ;;
        -h|--help) show_help; exit 0 ;;
        *) error "未知参数: $1"; show_help; exit 2 ;;
    esac
done

check_api_prerequisites
result=$(execute_tccli cvm DescribeRegions --region "$REGION") || exit $?
if ! printf '%s\n' "$result" | jq -e '.RegionSet | type == "array"' >/dev/null; then
    error "DescribeRegions 返回缺少 RegionSet，不能确认认证成功"
    exit 1
fi
success "认证与 API 连通性检查通过 (profile: $(tccli_profile)，地域: $REGION)"
info "已验证 DescribeRegions；其他操作仍需对应 CAM 权限"
