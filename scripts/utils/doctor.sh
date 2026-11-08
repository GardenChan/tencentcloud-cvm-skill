#!/bin/bash
# 默认仅检查本地依赖；--api 才进行只读认证检查。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"
JSON=false API=false REGION="${TENCENT_CVM_DEFAULT_REGION:-$DEFAULT_REGION}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) JSON=true; shift;;
        --api) API=true; shift;;
        --profile|--region)
            require_value "$@"
            if [[ "$1" == --profile ]]; then export TENCENT_CVM_PROFILE="$2"; else REGION="$2"; fi
            shift 2;;
        -h|--help)
            printf '%s\n' '用法: doctor.sh [--json] [--api] [--profile <name>] [--region <region>]' '默认只检查依赖和路径，不读取凭证、不运行 tccli、不联网。' '--api 额外调用 DescribeRegions 验证认证；SSH密码模式才需要sshpass。'; exit 0;;
        *) error "未知参数: $1"; exit 2;;
    esac
done
check_python_installed
PROFILE=$(tccli_profile)
STORE=$(password_file_path)
REPORT=$(CVM_DOCTOR_PROFILE="$PROFILE" CVM_DOCTOR_STORE="$STORE" python3 - <<'PY'
import json
import os
import shutil
import sys
required = ('bash', 'python3', 'jq', 'tccli')
optional = {'ssh': 'SSH 运维', 'scp': '文件传输', 'sshpass': '仅 SSH 密码认证'}
tools = {name: {'path': shutil.which(name), 'required': name in required} for name in (*required, *optional)}
result = {'profile': os.environ['CVM_DOCTOR_PROFILE'], 'connection_store': os.environ['CVM_DOCTOR_STORE'], 'tools': tools, 'ready': all(tools[n]['path'] for n in required), 'credentials_checked': False}
print(json.dumps(result, ensure_ascii=False, indent=2))
PY
)
STATUS=0
if [[ "$API" == true ]]; then
    # Explicit --profile was exported above. Preserve native environment
    # credentials when no profile was selected instead of forcing "default".
    bash "$SCRIPT_DIR/../auth/check.sh" --region "$REGION" >&2 || STATUS=$?
fi
printf '%s\n' "$REPORT" | python3 -c '
import json, sys
report = json.load(sys.stdin)
report["credentials_checked"] = sys.argv[2] == "true"
report["api_ready"] = (int(sys.argv[3]) == 0) if report["credentials_checked"] else None
if sys.argv[1] == "true":
    print(json.dumps(report, ensure_ascii=False, indent=2))
else:
    print("Profile:", report["profile"])
    print("本地连接记录:", report["connection_store"])
    for name, item in report["tools"].items():
        print(name + ": " + (item["path"] or "未安装") + (" (必需)" if item["required"] else " (可选)"))
    print("API 检查:", report["api_ready"] if report["credentials_checked"] else "未执行；可加 --api")
sys.exit(0 if report["ready"] else 1)
' "$JSON" "$API" "$STATUS" || exit $?
exit "$STATUS"
