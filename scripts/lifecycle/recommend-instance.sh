#!/bin/bash
# Read-only recommendations; never select a VPC/security group or buy a resource.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"
source "$SCRIPT_DIR/lifecycle-common.sh"
source "$SCRIPT_DIR/scene-presets.sh"

# Only structured API errors with an exact, candidate-local code can be skipped.
# Raw stderr/transport failures never become "no stock" by matching text.
candidate_fetch() {
    local action="$1"; shift
    local response exit_code=0 code message
    response=$(run_tccli cvm "$action" "$@") || exit_code=$?
    if ! printf '%s\n' "$response" | jq -e -s 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1; then
        error "$action 未返回结构化 API 响应；停止选型"
        (( exit_code != 0 )) || exit_code=1
        (( exit_code != 42 )) || exit_code=1
        return "$exit_code"
    fi
    response=$(printf '%s\n' "$response" | jq -c 'if .Response | type == "object" then .Response else . end') || return 1
    code=$(printf '%s\n' "$response" | jq -r '.Error.Code // empty')
    if [[ -n "$code" ]]; then
        case "$action:$code" in
            DescribeImages:ResourcesSoldOut.SpecifiedInstanceType|DescribeImages:InvalidParameterValue.InstanceTypeNotFound|\
            InquiryPriceRunInstances:ResourcesSoldOut.SpecifiedInstanceType|InquiryPriceRunInstances:ResourceUnavailable.InstanceType|\
            InquiryPriceRunInstances:InvalidParameterValue.InstanceTypeNotFound|InquiryPriceRunInstances:InvalidImageId.NotFound|\
            InquiryPriceRunInstances:InvalidParameter.InstanceImageNotSupport|InquiryPriceRunInstances:InvalidParameterValue.InvalidImageState|\
            InquiryPriceRunInstances:InvalidParameterValue.InvalidImageOsName|InquiryPriceRunInstances:InvalidParameterValue.InvalidImageFormat|\
            InquiryPriceRunInstances:InvalidParameterValue.ZoneNotSupported|InquiryPriceRunInstances:UnsupportedOperation.InvalidDisk|\
            InquiryPriceRunInstances:ResourceNotFound.NoDefaultCbs|InquiryPriceRunInstances:ResourceNotFound.NoDefaultCbsWithReason|\
            InquiryPriceRunInstances:ResourceInsufficient.CloudDiskUnavailable)
                printf '%s\n' "$response" | jq -c '{Code:.Error.Code,Message:(.Error.Message // ""),RequestId:(.RequestId // null)}'
                return 42 ;;
        esac
        message=$(printf '%s\n' "$response" | jq -r '.Error.Message // "未知错误"')
        error "API 错误: [$code] $message"
        case "$code" in
            AuthFailure*) show_auth_guidance ;;
            UnauthorizedOperation*) info "当前账号缺少此操作的 CAM 权限；重复登录不能修复权限不足" ;;
        esac
        return 1
    fi
    if (( exit_code != 0 )); then
        error "$action 调用失败（退出码 ${exit_code}）；停止选型"
        (( exit_code != 42 )) || exit_code=1
        return "$exit_code"
    fi
    printf '%s\n' "$response"
}

record_candidate_error() {
    candidate_errors=$(printf '%s\n' "$candidate_errors" | jq -c --arg tier "$tier" --arg action "$1" --arg type "$instance_type" --arg zone "$candidate_zone" --argjson detail "$2" \
        '. + [$detail + {Tier:$tier,Action:$action,InstanceType:$type,Zone:$zone}]')
    warn "跳过候选 ${instance_type}（${candidate_zone}）：$(printf '%s\n' "$2" | jq -r '.Code')"
}

load_defaults
SCENE="" ZONE_OVERRIDE="" IMAGE_OVERRIDE="" JSON_OUTPUT=false LIST_SCENES=false GPU_ONLY=false
BUDGET="" HOURS=720 CURRENCY="" BUDGET_CURRENCY="" CANDIDATE_LIMIT=5
CHARGE_TYPE=POSTPAID_BY_HOUR PERIOD="" PUBLIC_IP=false BANDWIDTH="" INTERNET_CHARGE_TYPE="" TRAFFIC_GB=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --scene) lc_value "$@"; SCENE="$2"; shift 2 ;;
        --region) lc_value "$@"; REGION="$2"; shift 2 ;;
        --zone) lc_value "$@"; ZONE_OVERRIDE="$2"; shift 2 ;;
        --image-id) lc_value "$@"; IMAGE_OVERRIDE="$2"; shift 2 ;;
        --budget) lc_value "$@"; BUDGET="$2"; shift 2 ;;
        --hours) lc_value "$@"; HOURS="$2"; shift 2 ;;
        --currency) lc_value "$@"; CURRENCY="$2"; shift 2 ;;
        --budget-currency) lc_value "$@"; BUDGET_CURRENCY="$2"; shift 2 ;;
        --candidate-limit) lc_value "$@"; CANDIDATE_LIMIT="$2"; shift 2 ;;
        --charge-type) lc_value "$@"; CHARGE_TYPE="$2"; shift 2 ;;
        --period) lc_value "$@"; PERIOD="$2"; shift 2 ;;
        --public-ip) PUBLIC_IP=true; shift ;;
        --bandwidth) lc_value "$@"; BANDWIDTH="$2"; shift 2 ;;
        --internet-charge-type) lc_value "$@"; INTERNET_CHARGE_TYPE="$2"; shift 2 ;;
        --traffic-gb) lc_value "$@"; TRAFFIC_GB="$2"; shift 2 ;;
        --gpu) GPU_ONLY=true; shift ;;
        --json) JSON_OUTPUT=true; shift ;;
        --list-scenes) LIST_SCENES=true; shift ;;
        -h|--help)
            cat <<'HELP'
用法: recommend-instance.sh --scene <scene> [--region <region>] [--zone <zone>] [--image-id <id>] [--gpu] [--json]
      recommend-instance.sh --list-scenes
只读选型：查询实时售卖状态，为有限候选池逐个查询兼容镜像和实际价格，按估算成本选择三档起步配置。
  --charge-type <type>   POSTPAID_BY_HOUR（默认）或 PREPAID；不会自动切换
  --period <months>      PREPAID 必填；1–12、24、36、48、60 月，不自动续费
  --public-ip            将公网纳入每个候选报价；默认无公网
  --bandwidth <Mbps>     需 --public-ip，默认 5 Mbps，范围 1–200
  --internet-charge-type <type>  需 --public-ip，默认 TRAFFIC_POSTPAID_BY_HOUR
                         BANDWIDTH_POSTPAID_BY_HOUR 仅用于按量实例
                         BANDWIDTH_PREPAID 仅用于包年包月实例
  --traffic-gb <GB>      按流量计费的出网用量假设；缺失时费用保持未知
  --budget <amount>      按量为 --hours 窗口预算；包年包月为月均预算，均非封顶
  --hours <n>            连续运行小时数，默认 720（30 天）
  --currency <code>      已核实的账号报价币种，如 CNY；不按地域猜币种
  --budget-currency <c>  预算币种，默认等于明确提供的 --currency
  --candidate-limit <n>  每档最多询价候选数，默认 5，范围 1–20
未确认币种时仍可比较同一账号原生价格，但不能判断货币预算是否满足。
固定带宽方案无需猜测流量；包年包月同时输出整期总价与月均，不能只按月均批准扣款。
不会选择网络/安全组或下单。场景规则不构成吞吐、模型容量或性能保证。
AI 场景默认筛选有 GPU 的机型；--gpu 可让其他场景也筛选 GPU。
--json 返回配置草案，需补充明确的 VPC、子网、安全组及登录方式后交 create-instance.sh 预检。
HELP
            exit 0 ;;
        *) error "未知参数: $1"; exit 2 ;;
    esac
done
[[ "$LIST_SCENES" == true ]] && { list_scenes; exit 0; }
[[ -n "$SCENE" ]] || { error "需要 --scene；可用 --list-scenes 查看"; exit 2; }
get_scene_config "$SCENE"
case "$SCENE" in ai-*) GPU_ONLY=true ;; esac
check_api_prerequisites
check_python_installed
validate_region "$REGION"
[[ "$CANDIDATE_LIMIT" =~ ^[0-9]+$ && ${#CANDIDATE_LIMIT} -le 2 ]] && (( 10#$CANDIDATE_LIMIT >= 1 && 10#$CANDIDATE_LIMIT <= 20 )) || { error "--candidate-limit 必须为 1–20"; exit 2; }
CANDIDATE_LIMIT=$((10#$CANDIDATE_LIMIT))
if [[ "$PUBLIC_IP" != true && ( -n "$BANDWIDTH" || -n "$INTERNET_CHARGE_TYPE" || -n "$TRAFFIC_GB" ) ]]; then
    error "--bandwidth/--internet-charge-type/--traffic-gb 需要 --public-ip"
    exit 2
fi
[[ -n "$BANDWIDTH" ]] || { if [[ "$PUBLIC_IP" == true ]]; then BANDWIDTH=5; else BANDWIDTH=0; fi; }
[[ -n "$INTERNET_CHARGE_TYPE" ]] || INTERNET_CHARGE_TYPE=TRAFFIC_POSTPAID_BY_HOUR
# Reuse the create-request validator so recommendations and purchases agree on
# supported periods and instance/network billing combinations before any API.
BILLING_CONFIG=$(python3 - "$SCRIPT_DIR" "$CHARGE_TYPE" "$PERIOD" "$PUBLIC_IP" "$BANDWIDTH" "$INTERNET_CHARGE_TYPE" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
from create_request import validate_billing
charge, period, public, bandwidth, network = sys.argv[2:]
request = {"InstanceChargeType": charge, "InternetAccessible": {
    "PublicIpAssigned": public == "true", "InternetMaxBandwidthOut": bandwidth,
    "InternetChargeType": network}}
if period:
    request["InstanceChargePrepaid"] = {"Period": period}
try:
    validate_billing(request)
except (ValueError, TypeError, AttributeError) as error:
    sys.exit("配置错误: " + str(error))
print(json.dumps(request))
PY
)
NETWORK_CHARGE=NONE
[[ "$PUBLIC_IP" != true ]] || NETWORK_CHARGE="$INTERNET_CHARGE_TYPE"
ESTIMATE_ARGS=(--charge-type "$CHARGE_TYPE" --internet-charge-type "$NETWORK_CHARGE" --hours "$HOURS")
[[ "$CHARGE_TYPE" != PREPAID ]] || ESTIMATE_ARGS+=(--period "$(printf '%s\n' "$BILLING_CONFIG" | jq -r '.InstanceChargePrepaid.Period')")
[[ -z "$TRAFFIC_GB" ]] || ESTIMATE_ARGS+=(--traffic-gb "$TRAFFIC_GB")
[[ -z "$BUDGET" ]] || ESTIMATE_ARGS+=(--budget "$BUDGET")
[[ -z "$CURRENCY" ]] || ESTIMATE_ARGS+=(--currency "$CURRENCY")
[[ -z "$BUDGET_CURRENCY" ]] || ESTIMATE_ARGS+=(--budget-currency "$BUDGET_CURRENCY")
# Validate pricing arguments locally before querying cloud resources.
validated_estimate=$(printf '%s\n' '{"Price":{}}' | python3 "$SCRIPT_DIR/price_estimate.py" "${ESTIMATE_ARGS[@]}")
HOURS=$(printf '%s\n' "$validated_estimate" | jq -c '.Hours')
umask 077
QUOTE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cvm-recommend.XXXXXX")
trap 'rm -rf "$QUOTE_DIR"' EXIT
QUOTE_REQUEST="$QUOTE_DIR/request.json"

if [[ -n "$ZONE_OVERRIDE" ]]; then
    ZONE="$ZONE_OVERRIDE"
else
    zones=$(execute_tccli cvm DescribeZones --region "$REGION")
    ZONE=$(printf '%s\n' "$zones" | jq -r '[(.Response // .).ZoneSet[] | select(.ZoneState == "AVAILABLE")] | .[0].Zone // empty')
fi
[[ "$ZONE" == "$REGION"-* && "$ZONE" =~ -[0-9]+$ ]] || { error "无可用或有效可用区，请明确 --zone"; exit 1; }
filters=$(jq -cn --arg zone "$ZONE_OVERRIDE" --arg charge "$CHARGE_TYPE" '[{Name:"instance-charge-type",Values:[$charge]}] + (if $zone == "" then [] else [{Name:"zone",Values:[$zone]}] end)')
stock=$(execute_tccli cvm DescribeZoneInstanceConfigInfos --region "$REGION" --Filters "$filters")
stock=$(printf '%s\n' "$stock" | jq -ce '(.Response // .).InstanceTypeQuotaSet | select(type == "array")')
plans='[]'
candidate_errors='[]'
for tier in eco balanced performance; do
    case "$tier" in
        eco) cpu="$ECO_CPU"; memory="$ECO_MEM"; disk="$ECO_DISK"; data_disk="$ECO_DATA_DISK" ;;
        balanced) cpu="$BAL_CPU"; memory="$BAL_MEM"; disk="$BAL_DISK"; data_disk="$BAL_DATA_DISK" ;;
        performance) cpu="$PRO_CPU"; memory="$PRO_MEM"; disk="$PRO_DISK"; data_disk="$PRO_DATA_DISK" ;;
    esac
    candidates=$(printf '%s\n' "$stock" | jq -c --argjson cpu "$cpu" --argjson memory "$memory" --argjson gpu "$GPU_ONLY" --argjson count "$CANDIDATE_LIMIT" --arg default_zone "$ZONE" --arg charge "$CHARGE_TYPE" '
      [.[] | select(.Status == "SELL" and .Cpu >= $cpu and .Memory >= $memory) |
        select(.InstanceChargeType == null or .InstanceChargeType == $charge) |
        select((($gpu == false) and (([.Gpu // 0, .GpuCount // 0] | max) == 0)) or (($gpu == true) and (([.Gpu // 0, .GpuCount // 0] | max) > 0))) |
        .Zone = (.Zone // $default_zone)] | unique_by([.Zone,.InstanceType]) | sort_by(.Cpu,.Memory,.InstanceType,.Zone) | .[:$count]')
    if [[ "$candidates" == '[]' ]]; then
        plans=$(printf '%s\n' "$plans" | jq --arg tier "$tier" '. + [{Tier:$tier,Available:false,Reason:"No matching sellable type"}]')
        continue
    fi
    priced='[]'
    while IFS= read -r candidate; do
        instance_type=$(printf '%s\n' "$candidate" | jq -r '.InstanceType')
        candidate_zone=$(printf '%s\n' "$candidate" | jq -r '.Zone')
        IMAGE_ARGS=(--region "$REGION" --InstanceType "$instance_type" --Limit 100)
        if [[ -n "$IMAGE_OVERRIDE" ]]; then
            IMAGE_ARGS+=(--ImageIds "$(jq -cn --arg id "$IMAGE_OVERRIDE" '[$id]')")
        else
            IMAGE_ARGS+=(--Filters "$(jq -cn --arg platform "$REC_PLATFORM" '[{Name:"image-type",Values:["PUBLIC_IMAGE"]},{Name:"platform",Values:[$platform]}]')")
        fi
        if images=$(candidate_fetch DescribeImages "${IMAGE_ARGS[@]}"); then :; else
            candidate_status=$?
            if [[ $candidate_status -eq 42 ]]; then record_candidate_error DescribeImages "$images"; continue; fi
            exit "$candidate_status"
        fi
        printf '%s\n' "$images" | jq -e '.ImageSet | type == "array"' >/dev/null || { error 'DescribeImages 响应缺少 ImageSet'; exit 1; }
        # Public images may omit CreatedTime. Keep the provider order unless all
        # eligible images have comparable timestamps; a missing time is not old.
        selected_image=$(printf '%s\n' "$images" | jq -c --arg requested "$IMAGE_OVERRIDE" '
          def created_timestamp:
            .CreatedTime | if type == "string" then (try fromdateiso8601 catch null) else null end;
          [(.Response // .).ImageSet[]? |
            select(.ImageState == "NORMAL" and .ImageDeprecated != true) |
            select($requested == "" or .ImageId == $requested)] |
          to_entries | map({image:.value,position:.key,created:(.value | created_timestamp)}) |
          if $requested == "" and length > 1 and all(.[]; .created != null)
          then sort_by(-.created,.position) else . end |
          .[0].image // empty')
        if [[ -z "$selected_image" ]]; then
            detail=$(printf '%s\n' "$images" | jq -c '{Code:"NoCompatibleNormalImage",Message:"No compatible normal image in the queried image page",RequestId:(.RequestId // null)}')
            record_candidate_error DescribeImages "$detail"
            continue
        fi
        image_id=$(printf '%s\n' "$selected_image" | jq -r '.ImageId')
        actual_disk=$(printf '%s\n' "$selected_image" | jq --argjson disk "$disk" '[.ImageSize // 0, $disk] | max')
        config=$(jq -cn --arg region "$REGION" --arg zone "$candidate_zone" --arg type "$instance_type" --arg image "$image_id" --argjson disk "$actual_disk" --arg data "$data_disk" --argjson billing "$BILLING_CONFIG" '{Region:$region,Placement:{Zone:$zone},InstanceType:$type,ImageId:$image,InstanceCount:1,SystemDisk:{DiskType:"CLOUD_PREMIUM",DiskSize:$disk}} + $billing + (if $data != "" and $data != "0" then {DataDisks:[{DiskType:"CLOUD_PREMIUM",DiskSize:($data|tonumber)}]} else {} end)')
        request=$(printf '%s\n' "$config" | jq -c 'del(.Region)')
        printf '%s\n' "$request" > "$QUOTE_REQUEST"
        if quote_response=$(candidate_fetch InquiryPriceRunInstances --region "$REGION" --cli-input-json "file://$QUOTE_REQUEST"); then :; else
            candidate_status=$?
            if [[ $candidate_status -eq 42 ]]; then record_candidate_error InquiryPriceRunInstances "$quote_response"; continue; fi
            exit "$candidate_status"
        fi
        quote=$(printf '%s\n' "$quote_response" | jq -ce '(.Response // .).Price | select(type == "object")')
        estimate=$(printf '%s\n' "$quote_response" | python3 "$SCRIPT_DIR/price_estimate.py" "${ESTIMATE_ARGS[@]}")
        priced=$(printf '%s\n' "$priced" | jq --arg tier "$tier" --argjson config "$config" --argjson price "$quote" --argjson estimate "$estimate" --argjson cpu "$(printf '%s\n' "$candidate" | jq '.Cpu')" --argjson memory "$(printf '%s\n' "$candidate" | jq '.Memory')" '. + [{Tier:$tier,Available:true,CPU:$cpu,MemoryGiB:$memory,Config:$config,Price:$price,CostEstimate:$estimate}]')
    done < <(printf '%s\n' "$candidates" | jq -c '.[]')
    if [[ "$priced" == '[]' ]]; then
        plans=$(printf '%s\n' "$plans" | jq --arg tier "$tier" '. + [{Tier:$tier,Available:false,Reason:"No usable quoted candidate in the bounded pool; inspect CandidateErrors"}]')
        continue
    fi
    # A single account's native amounts are comparable without inventing a currency;
    # budget comparisons stay Unknown until currency is explicitly established.
    selected=$(printf '%s\n' "$priced" | jq -c 'sort_by((if .CostEstimate.EstimatedTotal == null then 1 else 0 end), .CostEstimate.EstimatedTotal, .CPU, .MemoryGiB, .Config.InstanceType) | .[0]')
    selected=$(printf '%s\n' "$selected" | jq --argjson examined "$(printf '%s\n' "$priced" | jq length)" '. + {PricedCandidateCount:$examined}')
    plans=$(printf '%s\n%s\n' "$plans" "$selected" | jq -sc '.[0] + [.[1]]')
done
result=$(printf '%s\n' "$plans" | jq --arg scene "$SCENE" --arg profile "$(tccli_profile)" --arg region "$REGION" --arg zone "$ZONE_OVERRIDE" --argjson hours "$HOURS" --argjson limit "$CANDIDATE_LIMIT" --argjson candidate_errors "$candidate_errors" --argjson billing "$BILLING_CONFIG" '{Scene:$scene,Profile:$profile,Region:$region,Zone:(if $zone == "" then null else $zone end),Hours:$hours,ChargeType:$billing.InstanceChargeType,PeriodMonths:($billing.InstanceChargePrepaid.Period // null),InternetAccessible:$billing.InternetAccessible,CandidateLimitPerTier:$limit,SelectionScope:"Lowest estimated amount in the bounded quoted candidate pool, not a global cheapest claim",Plans:.,CandidateErrors:$candidate_errors,MissingConfiguration:["VirtualPrivateCloud.VpcId","VirtualPrivateCloud.SubnetId","SecurityGroupIds","LoginSettings (optional)"],Note:("Sizing starting points only; stock may change. " + (if $billing.InternetAccessible.PublicIpAssigned then "Public-network configuration is quoted; missing usage stays unknown. " else "Drafts have no public network. " end) + "Requote and preflight the final configuration before purchase; estimates are not spending caps") }')
if [[ "$JSON_OUTPUT" == true ]]; then
    printf '%s\n' "$result"
else
    info "只读候选：账号 $(tccli_profile)，地域 ${REGION}，可用区 $ZONE"
    printf '%s\n' "$plans" | jq -r '.[] | if .Available then [.Tier,.Config.InstanceType,(.CPU|tostring),(.MemoryGiB|tostring),.Config.ImageId,(.CostEstimate.EstimatedTotal|tostring),(.CostEstimate.MonthlyAverage|tostring),(.CostEstimate.Currency // "币种未确认"),.CostEstimate.Budget.Status,.Config.Placement.Zone] | @tsv else [.Tier,"不可用",.Reason] | @tsv end'
    info "列: 方案 / 机型 / CPU / GiB / 兼容镜像 / 整期或窗口估算 / 包月月均 / 币种 / 预算状态 / 可用区"
    info "实例计费 ${CHARGE_TYPE}；购买月数 ${PERIOD:-不适用}；按量估算 ${HOURS} 小时；公网 ${NETWORK_CHARGE}"
    info "估算仅覆盖本次配置和明确用量，不含其他新增服务，不代表完整博客成本或月度封顶"
    info "未选择网络或安全组，未购买。用 --json 获取配置草案，补全后交 create-instance.sh --dry-run 复核。"
fi
printf '%s\n' "$plans" | jq -e 'any(.[]; .Available)' >/dev/null || { error "没有可用候选，尝试其他可用区或明确规格"; exit 1; }
