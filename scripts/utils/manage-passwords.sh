#!/bin/bash
# 管理当前 profile 的本地连接记录；密码仅通过终端/文件/标准输入读取。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"
show_help() {
    cat <<'HELP'
用法: manage-passwords.sh [操作] [参数]
操作（一次一个）:
  --list                列出记录（隐藏密码，JSON）
  --show <id>           查看连接信息（隐藏密码，JSON）
  --add <id>            添加/更新密码；默认在终端隐藏输入
  --delete <id>         删除本地记录，不修改云实例
  --update-ip <id>      更新本地 host
参数:
  --host <host> --region <region> --user <user>
  --password-file <file> 从文件读取密码
  --password-stdin      从标准输入读取密码（不要将密码放命令行）
  --profile <name>      选择账号，与云 API 使用相同 profile
  --yes                 已确认删除指定记录
  -h, --help
HELP
}
ACTION="" INSTANCE_ID="" HOST="" REGION="" LOGIN_USER="" PASSWORD_FILE="" PASSWORD_STDIN=false YES=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --list)
            [[ -z "$ACTION" ]] || { error "一次只能选择一个操作"; exit 2; }
            ACTION=list; shift ;;
        --show|--add|--delete|--update-ip)
            [[ -z "$ACTION" ]] || { error "一次只能选择一个操作"; exit 2; }
            require_value "$@"; ACTION="${1#--}"; INSTANCE_ID="$2"; shift 2 ;;
        --host|--region|--user|--password-file|--profile)
            require_value "$@"
            case "$1" in
                --host) HOST="$2";; --region) REGION="$2";; --user) LOGIN_USER="$2";;
                --password-file) PASSWORD_FILE="$2";; --profile) export TENCENT_CVM_PROFILE="$2";;
            esac
            shift 2 ;;
        --password-stdin) PASSWORD_STDIN=true; shift ;;
        --password) error "请改用 --password-file/--password-stdin 或终端隐藏输入，避免密码进入命令历史"; exit 2 ;;
        --yes) YES=true; shift ;;
        -h|--help) show_help; exit 0 ;;
        *) error "未知参数: $1"; exit 2 ;;
    esac
done
[[ -n "$ACTION" ]] || { show_help; exit 2; }
[[ -z "$REGION" ]] || validate_region "$REGION"
case "$ACTION" in
    list) list_saved_instances ;;
    show) get_instance_info "$INSTANCE_ID" ;;
    delete)
        if [[ "$YES" != true ]]; then
            confirm "删除当前 profile $(tccli_profile) 的本地记录 $INSTANCE_ID?" || exit 1
        fi
        delete_instance_password "$INSTANCE_ID" ;;
    update-ip)
        [[ -n "$HOST" ]] || { error "缺少 --host"; exit 2; }
        update_instance_host "$INSTANCE_ID" "$HOST" ;;
    add)
        [[ -z "$PASSWORD_FILE" || "$PASSWORD_STDIN" != true ]] || { error "密码输入方式冲突"; exit 2; }
        PASSWORD=""
        if [[ -n "$PASSWORD_FILE" ]]; then
            PASSWORD=$(cat -- "$PASSWORD_FILE")
        elif [[ "$PASSWORD_STDIN" == true ]]; then
            PASSWORD=$(cat)
        elif [[ -t 0 ]]; then
            printf '实例密码: ' >&2
            IFS= read -r -s PASSWORD
            printf '\n' >&2
        else
            error "无交互终端，请使用 --password-file 或 --password-stdin"; exit 2
        fi
        [[ -n "$PASSWORD" ]] || { error "密码不能为空"; exit 2; }
        save_instance_password "$INSTANCE_ID" "$PASSWORD" "$HOST" "$REGION" "$LOGIN_USER"
        unset PASSWORD ;;
esac
