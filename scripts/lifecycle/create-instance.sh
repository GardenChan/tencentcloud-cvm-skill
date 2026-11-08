#!/bin/bash
# Prepare one immutable request, quote, preflight, and submit after one approval.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

show_help() {
    cat <<'HELP'
用法: create-instance.sh [配置参数] [--plan | --dry-run | --prepare <plan.json>] [--yes] [--wait]

配置优先级: 命令行 > JSON 配置 > TENCENT_CVM_DEFAULT_* > 默认值。
  --config <file>         JSON 配置（见 assets/create-instance-template.json）
  --region <region>       地域；--zone <zone> 可用区
  --instance-type <type>  机型；--image-id <id> 镜像；--name <name> 名称
  --vpc-id <id>           VPC；--subnet-id <id> 子网；--sg-id <id> 安全组（可重复）
  --disk-size <GB>        系统盘；--disk-type <type> 系统盘类型
  --data-disk-size <GB>   数据盘，0 表示不创建
  --charge-type <type>    POSTPAID_BY_HOUR（默认）或 PREPAID
  --period <months>      PREPAID 必需购买月数，默认不自动续费
  --key-id <id>           SSH 密钥 ID（可重复）；与 --password-login 互斥
  --password-login       生成本地密码；默认由腾讯云生成并通过站内信通知
  --public-ip            显式申请公网 IP；默认无公网
  --bandwidth <Mbps>     公网出带宽，开启公网时默认 5 Mbps、按流量计费
  --internet-charge-type <type>  显式公网计费；需 --public-ip 或配置已开启公网
                         TRAFFIC_POSTPAID_BY_HOUR（默认，需流量假设才能估算）
                         BANDWIDTH_POSTPAID_BY_HOUR（仅按量实例，按小时带宽）
                         BANDWIDTH_PREPAID（仅包年包月实例，按购买期带宽）
  --no-public-ip          覆盖配置，关闭公网申请
  --client-token <token> 幂等标识；重试同一请求须复用同一 token 和参数
  --prepare <file>       询价和预检后保存无密码购买计划，不购买、不覆盖已有文件
  --defer-network        配合 --prepare，仅询价并锁定缺网络方案；不声称预检通过
  --from-plan <file>     从已审阅计划购买；待网络方案仅可补原先缺少的网络 ID
  --resume <file>        从私密恢复文件复用请求、报价、预算和认证来源
  --plan                 只展示本地脱敏 JSON，不调用 API
  --dry-run              询价、预检查后退出，不购买
  --yes                  已批准所示配置和费用，跳过唯一一次购买确认
  --wait                 等待实例 RUNNING（默认仅返回提交结果）
  --timeout <seconds>    等待上限，默认 300 秒
  --hours <n>            按量费用估算时长，默认 720 小时（30 天）
  --currency <code>      已确认的报价币种，如 CNY；不按地域推断
  --budget <amount>      本次时长预算；包年包月为平均每月预算
  --budget-currency <c>  预算币种，默认跟随 --currency
  --traffic-gb <GB>      出网流量假设；未提供时流量费用保持未知
  -h, --help             显示帮助，不需要安装依赖
HELP
}

REQUEST_ARGS=()
NETWORK_ARGS=()
PLAN=false DRY_RUN=false ASSUME_YES=false WAIT=false PASSWORD_LOGIN=false DEFER_NETWORK=false TIMEOUT=300 PREPARE_FILE="" FROM_PLAN="" RESUME_FILE=""
ESTIMATE_HOURS=720 ESTIMATE_CURRENCY="" ESTIMATE_BUDGET="" ESTIMATE_BUDGET_CURRENCY="" ESTIMATE_TRAFFIC="" ESTIMATE_SPECIFIED=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --hours|--currency|--budget|--budget-currency|--traffic-gb)
            [[ $# -ge 2 && -n "$2" ]] || { error "$1 需要参数值"; exit 2; }
            case "$1" in
                --hours) ESTIMATE_HOURS="$2" ;;
                --currency) ESTIMATE_CURRENCY="$2" ;;
                --budget) ESTIMATE_BUDGET="$2" ;;
                --budget-currency) ESTIMATE_BUDGET_CURRENCY="$2" ;;
                --traffic-gb) ESTIMATE_TRAFFIC="$2" ;;
            esac
            ESTIMATE_SPECIFIED=true; shift 2 ;;
        --prepare|--from-plan|--resume)
            [[ $# -ge 2 && -n "$2" ]] || { error "$1 需要文件路径"; exit 2; }
            case "$1" in
                --prepare) PREPARE_FILE="$2" ;;
                --from-plan) FROM_PLAN="$2" ;;
                --resume) RESUME_FILE="$2" ;;
            esac
            shift 2 ;;
        --defer-network) DEFER_NETWORK=true; shift ;;
        --plan) PLAN=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --yes) ASSUME_YES=true; shift ;;
        --wait) WAIT=true; shift ;;
        --timeout)
            [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || { error "--timeout 需要正整数"; exit 2; }
            TIMEOUT="$2"; shift 2 ;;
        --password-login) PASSWORD_LOGIN=true; REQUEST_ARGS+=("$1"); shift ;;
        --public-ip|--no-public-ip) REQUEST_ARGS+=("$1"); shift ;;
        --vpc-id|--subnet-id|--sg-id)
            [[ $# -ge 2 && -n "$2" ]] || { error "$1 需要参数值"; exit 2; }
            NETWORK_ARGS+=("$1" "$2"); shift 2 ;;
        --config|--region|--zone|--instance-type|--image-id|--name|--disk-size|--disk-type|--data-disk-size|--charge-type|--period|--key-id|--bandwidth|--internet-charge-type|--client-token)
            [[ $# -ge 2 && -n "$2" ]] || { error "$1 需要参数值"; exit 2; }
            REQUEST_ARGS+=("$1" "$2"); shift 2 ;;
        -h|--help) show_help; exit 0 ;;
        *) error "未知参数: $1"; exit 2 ;;
    esac
done
[[ "$PLAN" == true && "$DRY_RUN" == true ]] && { error "--plan 与 --dry-run 不能同用"; exit 2; }
[[ -n "$RESUME_FILE" && ( -n "$FROM_PLAN" || -n "$PREPARE_FILE" || -n "${NETWORK_ARGS[*]-}" ) ]] && { error "--resume 不能与其他计划模式或网络参数同用"; exit 2; }
[[ -n "$RESUME_FILE" ]] && FROM_PLAN="$RESUME_FILE"
[[ -n "$PREPARE_FILE" && ( "$PLAN" == true || "$DRY_RUN" == true || -n "$FROM_PLAN" ) ]] && { error "--prepare 不能与 --plan/--dry-run/--from-plan/--resume 同用"; exit 2; }
[[ "$DEFER_NETWORK" == true && -z "$PREPARE_FILE" ]] && { error "--defer-network 仅可与 --prepare 同用"; exit 2; }
[[ -n "$FROM_PLAN" && ( -n "${REQUEST_ARGS[*]-}" || "$ESTIMATE_SPECIFIED" == true ) ]] && { error "--from-plan 不允许修改已准备的配置；请创建新计划"; exit 2; }
[[ -n "$PREPARE_FILE" && "$PASSWORD_LOGIN" == true ]] && { error "--prepare 不接受密码，请用 --key-id 或腾讯云默认登录方式"; exit 2; }
check_python_installed
check_jq_installed
approved_plan=""
RECOVERY_ARGS=()
[[ -n "$RESUME_FILE" ]] && RECOVERY_ARGS+=(--recovery)
if [[ -n "$FROM_PLAN" ]]; then
    approved_plan=$(python3 "$SCRIPT_DIR/purchase_plan.py" load --path "$FROM_PLAN" --profile "$(tccli_profile)" ${RECOVERY_ARGS[@]+"${RECOVERY_ARGS[@]}"} ${NETWORK_ARGS[@]+"${NETWORK_ARGS[@]}"})
    ESTIMATE_HOURS=$(printf '%s\n' "$approved_plan" | jq -r '.estimate_options.hours // "720"')
    ESTIMATE_CURRENCY=$(printf '%s\n' "$approved_plan" | jq -r '.estimate_options.currency // empty')
    ESTIMATE_BUDGET=$(printf '%s\n' "$approved_plan" | jq -r '.estimate_options.budget // empty')
    ESTIMATE_BUDGET_CURRENCY=$(printf '%s\n' "$approved_plan" | jq -r '.estimate_options.budget_currency // empty')
    ESTIMATE_TRAFFIC=$(printf '%s\n' "$approved_plan" | jq -r '.estimate_options.traffic_gb // empty')
    request=$(printf '%s\n' "$approved_plan" | jq '.request + {Region:.region}' | python3 "$SCRIPT_DIR/create_request.py" --config /dev/stdin)
    # Rebuilding must preserve every approved request field; do not quietly add defaults.
    original_request=$(printf '%s\n' "$approved_plan" | jq -Sc '.request')
    rebuilt_request=$(printf '%s\n' "$request" | jq -Sc 'del(.Region)')
    [[ "$original_request" == "$rebuilt_request" ]] || { error "计划配置已不兼容当前默认值，请重新准备方案"; exit 2; }
else
    [[ "$DEFER_NETWORK" == true ]] && REQUEST_ARGS+=(--allow-missing-network)
    request=$(python3 "$SCRIPT_DIR/create_request.py" ${REQUEST_ARGS[@]+"${REQUEST_ARGS[@]}"} ${NETWORK_ARGS[@]+"${NETWORK_ARGS[@]}"})
fi
if [[ "$DEFER_NETWORK" == true ]] && printf '%s\n' "$request" | jq -e '.VirtualPrivateCloud.VpcId and .VirtualPrivateCloud.SubnetId and ((.SecurityGroupIds // []) | length > 0)' >/dev/null; then
    error "--defer-network 仅适用于缺少网络 ID 的方案；完整配置请直接 --prepare"
    exit 2
fi
if [[ -n "$PREPARE_FILE" ]] && printf '%s\n' "$request" | jq -e '.LoginSettings.Password' >/dev/null; then
    error "--prepare 不接受含密码的配置"
    exit 2
fi
REGION=$(printf '%s\n' "$request" | jq -r '.Region')
TOKEN=$(printf '%s\n' "$request" | jq -r '.ClientToken')

if [[ "$PLAN" == true ]]; then
    if [[ "$PASSWORD_LOGIN" == true ]] || printf '%s\n' "$request" | jq -e '.LoginSettings.Password' >/dev/null; then
        info "计划不包含密码；执行时请重新指定 --password-login 或使用本地私密配置"
    fi
    printf '%s\n' "$request" | jq 'del(.LoginSettings.Password)'
    exit 0
fi
check_api_prerequisites

# tccli records argv in its own log. Pass a protected file, never a password in argv.
umask 077
REQUEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cvm-create.XXXXXX")
KEEP_REQUEST=false
trap 'if [[ "$KEEP_REQUEST" != true ]]; then rm -rf "$REQUEST_DIR"; fi' EXIT
REQUEST_FILE="$REQUEST_DIR/request.json"
printf '%s\n' "$request" | jq 'del(.Region)' > "$REQUEST_FILE"
[[ -n "$approved_plan" ]] && printf '%s\n' "$approved_plan" > "$REQUEST_DIR/approved-plan.json"
PASSWORD=""
if [[ "$PASSWORD_LOGIN" == true ]]; then
    PASSWORD=$(generate_password)
    printf '%s' "$PASSWORD" | jq --rawfile password /dev/stdin '.LoginSettings = {Password: $password}' "$REQUEST_FILE" > "$REQUEST_DIR/with-password.json"
    mv "$REQUEST_DIR/with-password.json" "$REQUEST_FILE"
else
    PASSWORD=$(jq -r '.LoginSettings.Password // empty' "$REQUEST_FILE")
fi

info "账号: $(tccli_profile)；地域: ${REGION}；ClientToken: $TOKEN"
jq 'del(.LoginSettings.Password)' "$REQUEST_FILE" >&2
info "正在对最终配置询价..."
result=$(execute_tccli cvm InquiryPriceRunInstances --region "$REGION" --cli-input-json "file://$REQUEST_FILE")
if [[ $(jq -r '.InstanceChargeType' "$REQUEST_FILE") == PREPAID ]]; then
    price_filter='(.Response // .).Price.InstancePrice | (.DiscountPrice // .OriginalPrice)'
else
    price_filter='(.Response // .).Price.InstancePrice | (.UnitPriceDiscount // .UnitPrice)'
fi
if ! printf '%s\n' "$result" | jq -e "$price_filter | type == \"number\" and . >= 0" >/dev/null; then
    error "询价缺少有效实例价格，已停止"
    exit 1
fi
# Preserve provider price units and components instead of presenting a guessed total.
printf '%s\n' "$result" | jq '(.Response // .).Price' > "$REQUEST_DIR/price.json"
cat "$REQUEST_DIR/price.json" >&2
if [[ -n "$FROM_PLAN" ]]; then
    python3 "$SCRIPT_DIR/purchase_plan.py" check-price --path "$REQUEST_DIR/approved-plan.json" --profile "$(tccli_profile)" --price-file "$REQUEST_DIR/price.json" ${RECOVERY_ARGS[@]+"${RECOVERY_ARGS[@]}"}
fi
CHARGE_TYPE=$(jq -r '.InstanceChargeType' "$REQUEST_FILE")
NETWORK_CHARGE=$(jq -r 'if .InternetAccessible.PublicIpAssigned and (.InternetAccessible.InternetMaxBandwidthOut > 0) then .InternetAccessible.InternetChargeType else "NONE" end' "$REQUEST_FILE")
ESTIMATE_ARGS=(--charge-type "$CHARGE_TYPE" --internet-charge-type "$NETWORK_CHARGE" --hours "$ESTIMATE_HOURS")
[[ "$CHARGE_TYPE" == PREPAID ]] && ESTIMATE_ARGS+=(--period "$(jq -r '.InstanceChargePrepaid.Period' "$REQUEST_FILE")")
[[ -n "$ESTIMATE_CURRENCY" ]] && ESTIMATE_ARGS+=(--currency "$ESTIMATE_CURRENCY")
[[ -n "$ESTIMATE_BUDGET" ]] && ESTIMATE_ARGS+=(--budget "$ESTIMATE_BUDGET")
[[ -n "$ESTIMATE_BUDGET_CURRENCY" ]] && ESTIMATE_ARGS+=(--budget-currency "$ESTIMATE_BUDGET_CURRENCY")
[[ -n "$ESTIMATE_TRAFFIC" ]] && ESTIMATE_ARGS+=(--traffic-gb "$ESTIMATE_TRAFFIC")
printf '%s\n' "$result" | python3 "$SCRIPT_DIR/price_estimate.py" "${ESTIMATE_ARGS[@]}" > "$REQUEST_DIR/estimate.json"
jq -n --arg hours "$ESTIMATE_HOURS" --arg currency "$ESTIMATE_CURRENCY" --arg budget "$ESTIMATE_BUDGET" --arg budget_currency "$ESTIMATE_BUDGET_CURRENCY" --arg traffic "$ESTIMATE_TRAFFIC" '{hours:$hours} + (if $currency != "" then {currency:$currency} else {} end) + (if $budget != "" then {budget:$budget} else {} end) + (if $budget_currency != "" then {budget_currency:$budget_currency} else {} end) + (if $traffic != "" then {traffic_gb:$traffic} else {} end)' > "$REQUEST_DIR/estimate-options.json"
jq '{Status,Currency,Hours,EstimatedTotal,MonthlyAverage,Budget,NotIncludedOrUnknown}' "$REQUEST_DIR/estimate.json" >&2
if [[ $(jq -r '.Budget.Status' "$REQUEST_DIR/estimate.json") == Exceeds ]]; then
    error "当前已知费用已超出预算，未购买；请调整方案后重新确认"
    exit 1
fi
info "估算依赖时长与用量假设，不是费用上限；未知项目不会按 0 处理"

if [[ "$DEFER_NETWORK" == true ]]; then
    python3 "$SCRIPT_DIR/purchase_plan.py" create --path "$PREPARE_FILE" --profile "$(tccli_profile)" --region "$REGION" --request-file "$REQUEST_FILE" --price-file "$REQUEST_DIR/price.json" --estimate-file "$REQUEST_DIR/estimate.json" --estimate-options-file "$REQUEST_DIR/estimate-options.json" --defer-network
    success "已锁定规格、报价和预算，未购买；网络尚未准备，尚未完成最终预检"
    exit 0
fi
info "正在验证同一份配置（DryRun）..."
jq '. + {DryRun:true}' "$REQUEST_FILE" > "$REQUEST_DIR/dry-run.json"
dryrun=$(execute_tccli cvm RunInstances --region "$REGION" --cli-input-json "file://$REQUEST_DIR/dry-run.json")
if ! printf '%s\n' "$dryrun" | jq -e '(.Response // .).RequestId | type == "string" and length > 0' >/dev/null; then
    error "预检查响应缺少 RequestId，未购买"
    exit 1
fi
printf '%s\n' "$dryrun" > "$REQUEST_DIR/preflight.json"
if [[ -n "$PREPARE_FILE" ]]; then
    python3 "$SCRIPT_DIR/purchase_plan.py" create --path "$PREPARE_FILE" --profile "$(tccli_profile)" --region "$REGION" --request-file "$REQUEST_FILE" --price-file "$REQUEST_DIR/price.json" --preflight-file "$REQUEST_DIR/preflight.json" --estimate-file "$REQUEST_DIR/estimate.json" --estimate-options-file "$REQUEST_DIR/estimate-options.json"
    success "方案已准备，未购买；确认后可用 --from-plan 复用配置和幂等标识"
    exit 0
fi
if [[ "$DRY_RUN" == true ]]; then
    success "询价与预检查通过，未购买"
    printf '%s\n' "$dryrun"
    exit 0
fi

if [[ -n "$ESTIMATE_BUDGET" && $(jq -r '.Budget.Status' "$REQUEST_DIR/estimate.json") == Unknown ]]; then
    error "已指定预算，但币种、价格或用量不足以确认符合预算；未购买。补全假设或明确调整预算约束后重新准备方案"
    exit 1
fi
if [[ "$ASSUME_YES" != true ]]; then
    confirm "按上述账号、配置和价格创建 1 台实例（产生费用）？" || { info "已取消"; exit 0; }
fi
# Write before submitting: a timeout or process interruption must preserve the
# complete approved constraints and the exact bound request, including secrets.
SAVE_RECOVERY_ARGS=()
[[ -n "$approved_plan" ]] && SAVE_RECOVERY_ARGS+=(--base-plan "$REQUEST_DIR/approved-plan.json")
RECOVERY_FILE="$REQUEST_DIR/recovery.json"
python3 "$SCRIPT_DIR/purchase_plan.py" create --path "$RECOVERY_FILE" --profile "$(tccli_profile)" --region "$REGION" --request-file "$REQUEST_FILE" --price-file "$REQUEST_DIR/price.json" --preflight-file "$REQUEST_DIR/preflight.json" --estimate-file "$REQUEST_DIR/estimate.json" --estimate-options-file "$REQUEST_DIR/estimate-options.json" --recovery ${SAVE_RECOVERY_ARGS[@]+"${SAVE_RECOVERY_ARGS[@]}"}
KEEP_REQUEST=true
info "提交期间的私密恢复文件: $RECOVERY_FILE"
if ! result=$(execute_tccli cvm RunInstances --region "$REGION" --cli-input-json "file://$REQUEST_FILE"); then
    error "创建结果不明。先查询实际实例，不能重新生成参数下单。"
    warn "原请求及批准的报价/预算已私密保留；核实需要重试后使用 --resume $RECOVERY_FILE --yes，复用网络 ID、ClientToken 和凭证"
    exit 1
fi
INSTANCE_ID=$(printf '%s\n' "$result" | jq -r '(.Response // .).InstanceIdSet[0] // empty')
if [[ ! "$INSTANCE_ID" =~ ^ins-[A-Za-z0-9-]+$ ]]; then
    error "创建响应缺少有效实例 ID，请先查询，不要重复购买"
    warn "原请求及约束已私密保留: ${RECOVERY_FILE}；核实后使用 --resume"
    exit 1
fi
if [[ -n "$PASSWORD" ]]; then
    if ! save_instance_password "$INSTANCE_ID" "$PASSWORD" "" "$REGION"; then
        error "实例请求已提交: ${INSTANCE_ID}，但本地密码记录保存失败；不要重复购买"
        warn "登录凭证及原请求仍保留在私密恢复文件: $RECOVERY_FILE"
        printf '%s\n' "$result"
        exit 1
    fi
elif declare -F save_instance_connection >/dev/null; then
    save_instance_connection "$INSTANCE_ID" "" "$REGION" "" || warn "创建请求已提交，但本地连接信息未保存"
fi
success "创建请求已提交: ${INSTANCE_ID}；尚未确认运行"
if [[ "$WAIT" == true ]]; then
    wait_args=(--instance-id "$INSTANCE_ID" --region "$REGION" --state RUNNING --created-instance --timeout "$TIMEOUT")
    request_id=$(printf '%s\n' "$result" | jq -r '(.Response // .).RequestId // empty')
    [[ -n "$request_id" ]] && wait_args+=(--request-id "$request_id")
    if instance=$(bash "$SCRIPT_DIR/wait-instance.sh" "${wait_args[@]}"); then
        :
    else
        wait_status=$?
        warn "实例已提交: ${INSTANCE_ID}，等待未成功；先查询实例状态，不要重复购买"
        printf '%s\n' "$result" | jq --arg token "$TOKEN" --arg recovery "$RECOVERY_FILE" '(.Response // .) + {ClientToken:$token,RecoveryFile:$recovery}'
        exit "$wait_status"
    fi
    printf '%s\n' "$result" | jq --arg token "$TOKEN" --argjson instance "$instance" '(.Response // .) + {ClientToken:$token,Instance:$instance}'
else
    printf '%s\n' "$result" | jq --arg token "$TOKEN" '(.Response // .) + {ClientToken:$token}'
fi
KEEP_REQUEST=false
