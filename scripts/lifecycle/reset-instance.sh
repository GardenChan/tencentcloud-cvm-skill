#!/bin/bash
# Reset system disk; credentials travel in a protected file, never CLI argv.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"
source "$SCRIPT_DIR/lifecycle-common.sh"
load_defaults
INSTANCE_ID="" IMAGE_ID="" PASSWORD_FILE="" KEY_ID="" PASSWORD_LOGIN=false ASSUME_YES=false WAIT=false TIMEOUT=300
while [[ $# -gt 0 ]]; do
    case "$1" in
        --instance-id) lc_value "$@"; INSTANCE_ID="$2"; shift 2 ;;
        --image-id) lc_value "$@"; IMAGE_ID="$2"; shift 2 ;;
        --region) lc_value "$@"; REGION="$2"; shift 2 ;;
        --key-id) lc_value "$@"; KEY_ID="$2"; shift 2 ;;
        --password-file) lc_value "$@"; PASSWORD_FILE="$2"; shift 2 ;;
        --password-login) PASSWORD_LOGIN=true; shift ;;
        --yes) ASSUME_YES=true; shift ;;
        --wait) WAIT=true; shift ;;
        --timeout) lc_value "$@"; TIMEOUT="$2"; shift 2 ;;
        --password) error "不再通过命令行传密码（tccli 会记录参数），请用 --password-file 或 --password-login"; exit 2 ;;
        -h|--help)
            cat <<'HELP'
用法: reset-instance.sh --instance-id <id> [--image-id <id>] [--region <region>]
       [--key-id <id> | --password-login | --password-file <file>] [--yes] [--wait] [--timeout 300]
重装清除系统盘数据。默认由腾讯云生成密码；--password-login 自动生成并在本地私密存储。
--password-file 在本机读取密码，不在命令参数和输出中传明文；不要将文件加入仓库。
HELP
            exit 0 ;;
        *) error "未知参数: $1"; exit 2 ;;
    esac
done
lc_instance "$INSTANCE_ID"
[[ -z "$IMAGE_ID" || "$IMAGE_ID" =~ ^img-[A-Za-z0-9-]+$ ]] || { error "无效镜像 ID"; exit 2; }
[[ -z "$KEY_ID" || "$KEY_ID" =~ ^skey-[A-Za-z0-9-]+$ ]] || { error "无效密钥 ID"; exit 2; }
[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] || { error "--timeout 需要正整数"; exit 2; }
methods=0
[[ -n "$KEY_ID" ]] && methods=$((methods + 1))
[[ -n "$PASSWORD_FILE" ]] && methods=$((methods + 1))
[[ "$PASSWORD_LOGIN" == true ]] && methods=$((methods + 1))
[[ $methods -le 1 ]] || { error "登录方式不能同时指定"; exit 2; }
check_api_prerequisites
validate_region "$REGION"
lc_confirm "重装将清除系统盘数据，确认已备份并执行？"
umask 077
REQUEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cvm-reset.XXXXXX")
KEEP_REQUEST=false
trap 'if [[ "$KEEP_REQUEST" != true ]]; then rm -rf "$REQUEST_DIR"; fi' EXIT
REQUEST_FILE="$REQUEST_DIR/request.json"
jq -n --arg id "$INSTANCE_ID" --arg image "$IMAGE_ID" --arg key "$KEY_ID" '{InstanceId:$id} + (if $image != "" then {ImageId:$image} else {} end) + (if $key != "" then {LoginSettings:{KeyIds:[$key]}} else {} end)' > "$REQUEST_FILE"
PASSWORD=""
if [[ "$PASSWORD_LOGIN" == true ]]; then
    PASSWORD=$(generate_password)
elif [[ -n "$PASSWORD_FILE" ]]; then
    [[ -f "$PASSWORD_FILE" ]] || { error "密码文件不存在"; exit 2; }
    PASSWORD=$(cat "$PASSWORD_FILE")
    [[ -n "$PASSWORD" ]] || { error "密码文件为空"; exit 2; }
fi
if [[ -n "$PASSWORD" ]]; then
    printf '%s' "$PASSWORD" | jq --rawfile password /dev/stdin '.LoginSettings = {Password: $password}' "$REQUEST_FILE" > "$REQUEST_DIR/password.json"
    mv "$REQUEST_DIR/password.json" "$REQUEST_FILE"
fi
if ! result=$(execute_tccli cvm ResetInstance --region "$REGION" --cli-input-json "file://$REQUEST_FILE"); then
    KEEP_REQUEST=true
    error "重装结果不明，请先查询实例，不自动重放重装请求"
    warn "本次请求已私密保留: $REQUEST_FILE"
    exit 1
fi
if [[ -n "$PASSWORD" ]]; then
    if ! save_instance_password "$INSTANCE_ID" "$PASSWORD" "$(get_instance_host "$INSTANCE_ID" || true)" "$REGION"; then
        KEEP_REQUEST=true
        error "重装请求已提交，但本地密码记录保存失败"
        warn "本次登录设置仍保留在私密请求文件: $REQUEST_FILE"
        printf '%s\n' "$result"
        exit 1
    fi
else
    clear_instance_password "$INSTANCE_ID" || warn "旧密码记录未能清理，请勿继续使用原密码"
fi
success "重装请求已提交，尚未确认完成；旧连接信息可能不再有效"
printf '%s\n' "$result"
lc_wait "$result" RUNNING
