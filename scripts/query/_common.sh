#!/bin/bash
# Shared query parsing and pagination. Public entrypoints are describe-*.sh.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common.sh"

query_value() {
    [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || { error "$1 需要参数值"; return 2; }
}

query_integer() {
    local value="$1" label="$2" minimum="$3" maximum="$4"
    [[ "$value" =~ ^(0|[1-9][0-9]*)$ && ${#value} -le 9 ]] &&
        (( value >= minimum && value <= maximum )) || {
        error "$label 必须是 $minimum 到 $maximum 的整数"; return 2;
    }
}

query_ids_json() {
    local value="$1" maximum="${2:-100}"
    jq -cen --arg value "$value" --argjson maximum "$maximum" '
      $value | split(",") |
      if length > 0 and length <= $maximum and
         all(.[]; test("^[a-z]+-[a-zA-Z0-9]+$")) and (unique | length) == length
      then . else error("资源 ID 应为不重复的逗号分隔列表") end'
}

# Arguments: service action set-key paginated offset limit all [API args...]
query_fetch() {
    local service="$1" action="$2" key="$3" paginated="$4" offset="$5" limit="$6" fetch_all="$7"
    shift 7
    local page count total first_total="" merged="" previous_page="" items page_index=0 start_offset="$offset" identity=""
    case "$key" in
        InstanceSet|InstanceStatusSet|AutomationAgentSet) identity=InstanceId ;;
        ImageSet) identity=ImageId ;; VpcSet) identity=VpcId ;; SubnetSet) identity=SubnetId ;;
        SecurityGroupSet) identity=SecurityGroupId ;; KeyPairSet) identity=KeyId ;;
        InvocationTaskSet) identity=InvocationTaskId ;;
    esac
    while :; do
        if [[ "$paginated" == true ]]; then
            page=$(execute_tccli "$service" "$action" "$@" --Offset "$offset" --Limit "$limit") || return $?
        else
            page=$(execute_tccli "$service" "$action" "$@") || return $?
        fi
        page=$(printf '%s\n' "$page" | jq -ce '.Response // .') || return 1
        if ! printf '%s\n' "$page" | jq -e --arg key "$key" '.[$key] | type == "array"' >/dev/null; then
            error "$action 响应缺少 $key 数组"; return 1
        fi
        count=$(printf '%s\n' "$page" | jq --arg key "$key" '.[$key] | length')
        if [[ "$paginated" == true ]]; then
            if ! total=$(printf '%s\n' "$page" | jq -er '.TotalCount | select(type == "number" and . >= 0 and floor == .)'); then
                error "$action 响应缺少有效 TotalCount"; return 1
            fi
        else
            total="$count"
        fi
        if [[ -z "$first_total" ]]; then first_total="$total"; fi
        if [[ "$fetch_all" == true && "$total" != "$first_total" ]]; then
            error "分页期间资源总数发生变化，请重新查询，未返回不完整结果"; return 1
        fi
        items=$(printf '%s\n' "$page" | jq -c --arg key "$key" '.[$key]')
        if [[ "$fetch_all" == true && $page_index -gt 0 && "$count" -gt 0 && "$items" == "$previous_page" ]]; then
            error "API 重复返回同一页，停止分页以避免无限循环"; return 1
        fi
        previous_page="$items"
        if [[ -z "$merged" ]]; then
            merged=$(printf '%s\n' "$page" | jq '._Pagination = {RequestIds: [(.RequestId // empty)]}')
        else
            merged=$(printf '%s\n%s\n' "$merged" "$page" | jq -sc --arg key "$key" '
              .[0] as $old | .[1] as $new | $old |
              .[$key] += $new[$key] | ._Pagination.RequestIds += [($new.RequestId // empty)]') || return 1
        fi
        if [[ "$fetch_all" == true && -n "$identity" ]]; then
            if ! printf '%s\n' "$merged" | jq -e --arg key "$key" --arg identity "$identity" '
              [.[$key][] | .[$identity] // empty] | length == (unique | length)' >/dev/null; then
                error '分页返回重复资源，列表可能正在变化，请重新查询'; return 1
            fi
        fi
        offset=$((offset + count))
        page_index=$((page_index + 1))
        if [[ "$paginated" != true || "$fetch_all" != true || $offset -ge $total ]]; then break; fi
        if [[ $count -eq 0 || $page_index -ge 10000 ]]; then
            error "分页未能取得完整结果，已停止"; return 1
        fi
    done
    printf '%s\n' "$merged" | jq --arg key "$key" --argjson start "$start_offset" --argjson total "$total" '
      ._Pagination += {Offset: $start, ReturnedCount: (.[$key] | length), TotalCount: $total,
        Complete: ($start == 0 and (.[$key] | length) >= $total)}'
}

query_main() {
    local kind="$1"; shift
    local service=cvm action key label paginated=true
    local region="${TENCENT_CVM_DEFAULT_REGION:-$DEFAULT_REGION}" limit=20 offset=0 fetch_all=false json=false available=false
    local ids="" name="" zone="" family="" instance_type="" platform="" image_type=PUBLIC_IMAGE vpc_id=""
    case "$kind" in
        instances) action=DescribeInstances; key=InstanceSet; label='实例' ;;
        key-pairs) action=DescribeKeyPairs; key=KeyPairSet; label='密钥对' ;;
        instance-status) action=DescribeInstancesStatus; key=InstanceStatusSet; label='实例状态' ;;
        images) action=DescribeImages; key=ImageSet; label='镜像' ;;
        instance-types) action=DescribeInstanceTypeConfigs; key=InstanceTypeConfigSet; label='实例机型'; paginated=false ;;
        regions) action=DescribeRegions; key=RegionSet; label='地域'; paginated=false ;;
        zones) action=DescribeZones; key=ZoneSet; label='可用区'; paginated=false ;;
        vpcs) service=vpc; action=DescribeVpcs; key=VpcSet; label=VPC ;;
        subnets) service=vpc; action=DescribeSubnets; key=SubnetSet; label='子网' ;;
        security-groups) service=vpc; action=DescribeSecurityGroups; key=SecurityGroupSet; label='安全组' ;;
        tat-agents) service=tat; action=DescribeAutomationAgentStatus; key=AutomationAgentSet; label='TAT Agent' ;;
        *) error "未知查询类型: $kind"; return 2 ;;
    esac
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                printf '用法: %s [选项]\n查询%s；默认只返回一页，--all 获取全部。\n' "$(basename "$0")" "$label"
                printf '%s\n' '  --region <region>  地域' '  --json             输出 JSON（含 _Pagination）' '  --all              自动获取全部分页' '  -h, --help         显示帮助'
                [[ "$paginated" != true ]] || printf '%s\n' '  --offset <n>       起始偏移，默认 0；不可与 --all 非零组合' '  --limit <n>        每页数量 1–100，默认 20'
                case "$kind" in
                    instances) printf '%s\n' '  --instance-id <ids>  实例 ID（逗号分隔，与 --name 互斥）' '  --name <name>        实例名称过滤' ;;
                    key-pairs) printf '%s\n' '  --key-id <ids>       密钥对 ID（逗号分隔）' '  --name <name>        密钥对名称过滤' ;;
                    instance-status|tat-agents) printf '%s\n' '  --instance-id <ids>  实例 ID，逗号分隔' ;;
                    images) printf '%s\n' '  --image-id <ids>     镜像 ID，逗号分隔' '  --instance-type <t>  查询兼容机型的镜像' '  --platform <name>    平台过滤' '  --image-type <type>  默认 PUBLIC_IMAGE；--type 为别名' '  --name <name>        镜像名过滤' ;;
                    instance-types) printf '%s\n' '  --zone <zone> --family <family> --type <type>  机型过滤' ;;
                    regions) printf '%s\n' '  --available          仅显示可用地域' ;;
                    vpcs) printf '%s\n' '  --vpc-id <ids>       VPC ID，逗号分隔' ;;
                    subnets) printf '%s\n' '  --subnet-id <ids>    子网 ID，与其他过滤互斥' '  --vpc-id <id> --zone <zone>  子网过滤' ;;
                    security-groups) printf '%s\n' '  --sg-id <ids>        安全组 ID，逗号分隔' '  --name <name>        安全组名称过滤' ;;
                esac
                return 0 ;;
            --json) json=true; shift ;;
            --all) fetch_all=true; shift ;;
            --available) [[ "$kind" == regions ]] || { error "$kind 不支持 $1"; return 2; }; available=true; shift ;;
            --region) query_value "$@" || return $?; region="$2"; shift 2 ;;
            --limit|--offset)
                [[ "$paginated" == true ]] || { error "$label 接口不使用分页参数"; return 2; }
                query_value "$@" || return $?; if [[ "$1" == --limit ]]; then limit="$2"; else offset="$2"; fi; shift 2 ;;
            --instance-id|--image-id|--vpc-id|--subnet-id|--sg-id|--key-id|--name|--zone|--family|--type|--instance-type|--platform|--image-type)
                query_value "$@" || return $?
                case "$kind:$1" in
                    key-pairs:--key-id|instances:--instance-id|instance-status:--instance-id|tat-agents:--instance-id|images:--image-id|vpcs:--vpc-id|subnets:--subnet-id|security-groups:--sg-id) ids="$2" ;;
                    key-pairs:--name|instances:--name|images:--name|security-groups:--name) name="$2" ;;
                    subnets:--vpc-id) vpc_id="$2" ;;
                    subnets:--zone|instance-types:--zone) zone="$2" ;;
                    instance-types:--family) family="$2" ;;
                    instance-types:--type|images:--instance-type) instance_type="$2" ;;
                    images:--platform) platform="$2" ;;
                    images:--image-type|images:--type) image_type="$2" ;;
                    *) error "$label 不支持 $1"; return 2 ;;
                esac
                shift 2 ;;
            *) error "未知参数: $1"; return 2 ;;
        esac
    done
    query_integer "$limit" --limit 1 100 || return $?
    query_integer "$offset" --offset 0 999999999 || return $?
    [[ "$fetch_all" != true || "$offset" == 0 ]] || { error '--all 不能与非零 --offset 组合'; return 2; }
    check_api_prerequisites
    validate_region "$region"
    local filters='[]' args=(--region "$region") ids_json result
    if [[ -n "$ids" ]]; then
        ids_json=$(query_ids_json "$ids") || return 2
        case "$kind" in
            instances|instance-status|tat-agents) args+=(--InstanceIds "$ids_json") ;;
            key-pairs) args+=(--KeyIds "$ids_json") ;;
            images) args+=(--ImageIds "$ids_json"); image_type="" ;;
            vpcs) args+=(--VpcIds "$ids_json") ;;
            subnets) args+=(--SubnetIds "$ids_json") ;;
            security-groups) args+=(--SecurityGroupIds "$ids_json") ;;
        esac
    fi
    case "$kind" in
        key-pairs) [[ -z "$name" ]] || filters=$(jq -cn --arg name "$name" '[{Name:"key-name",Values:[$name]}]') ;;
        instances) [[ -z "$name" ]] || filters=$(jq -cn --arg name "$name" '[{Name:"instance-name",Values:[$name]}]') ;;
        images)
            [[ -z "$instance_type" ]] || args+=(--InstanceType "$instance_type")
            filters=$(jq -cn --arg image_type "$image_type" --arg platform "$platform" --arg name "$name" '[{Name:"image-type",Values:[$image_type]},{Name:"platform",Values:[$platform]},{Name:"image-name",Values:[$name]}] | map(select(.Values[0] != ""))') ;;
        instance-types) filters=$(jq -cn --arg zone "$zone" --arg family "$family" --arg type "$instance_type" '[{Name:"zone",Values:[$zone]},{Name:"instance-family",Values:[$family]},{Name:"instance-type",Values:[$type]}] | map(select(.Values[0] != ""))') ;;
        subnets) filters=$(jq -cn --arg vpc "$vpc_id" --arg zone "$zone" '[{Name:"vpc-id",Values:[$vpc]},{Name:"zone",Values:[$zone]}] | map(select(.Values[0] != ""))') ;;
        security-groups) [[ -z "$name" ]] || filters=$(jq -cn --arg name "$name" '[{Name:"security-group-name",Values:[$name]}]') ;;
    esac
    if [[ -n "$ids" && "$filters" != '[]' ]]; then error 'ID 列表不能与名称、平台、VPC 或可用区过滤条件组合'; return 2; fi
    [[ "$filters" == '[]' ]] || args+=(--Filters "$filters")
    result=$(query_fetch "$service" "$action" "$key" "$paginated" "$offset" "$limit" "$fetch_all" "${args[@]}") || return $?
    if [[ "$available" == true ]]; then
        result=$(printf '%s\n' "$result" | jq '.RegionSet |= map(select(.RegionState == "AVAILABLE")) | ._Pagination.ReturnedCount = (.RegionSet|length) | ._Pagination.Filter = "available"')
    fi
    if [[ "$json" == true ]]; then printf '%s\n' "$result"; return 0; fi
    case "$kind" in
        instances) printf '实例 ID\t名称\t状态\t机型\t公网 IP\t内网 IP\n' ;;
        instance-status) printf '实例 ID\t状态\n' ;;
        images) printf '镜像 ID\t平台\t架构\t名称\n' ;;
        instance-types) printf '机型\t系列\tCPU\t内存 GB\t可用区\n' ;;
        regions) printf '地域\t名称\t状态\n' ;; zones) printf '可用区\t名称\t状态\n' ;;
        vpcs) printf 'VPC ID\t名称\tCIDR\n' ;; subnets) printf '子网 ID\t名称\tVPC\tCIDR\t可用区\t可用 IP\n' ;;
        security-groups) printf '安全组 ID\t名称\t描述\n' ;;
        key-pairs) printf '密钥对 ID\t名称\t项目 ID\t关联实例\n' ;;
        tat-agents) printf '实例 ID\tAgent 状态\t版本\t最后心跳\n' ;;
    esac
    printf '%s\n' "$result" | jq -r --arg kind "$kind" --arg key "$key" '
      .[$key][] | if $kind == "instances" then [.InstanceId,.InstanceName,.InstanceState,.InstanceType,(.PublicIpAddresses//[]|join(",")),(.PrivateIpAddresses//[]|join(","))]
      elif $kind == "key-pairs" then [.KeyId,.KeyName,.ProjectId,(.AssociatedInstanceIds//[]|join(","))]
      elif $kind == "instance-status" then [.InstanceId,.InstanceState]
      elif $kind == "images" then [.ImageId,.Platform,.Architecture,.ImageName]
      elif $kind == "instance-types" then [.InstanceType,.InstanceFamily,.CPU,.Memory,.Zone]
      elif $kind == "regions" then [.Region,.RegionName,.RegionState]
      elif $kind == "zones" then [.Zone,.ZoneName,.ZoneState]
      elif $kind == "vpcs" then [.VpcId,.VpcName,.CidrBlock]
      elif $kind == "subnets" then [.SubnetId,.SubnetName,.VpcId,.CidrBlock,.Zone,.AvailableIpAddressCount]
      elif $kind == "security-groups" then [.SecurityGroupId,.SecurityGroupName,.SecurityGroupDesc]
      else [.InstanceId,.AgentStatus,.Version,.LastHeartbeatTime] end | @tsv'
    printf '%s\n' "$result" | jq -r '._Pagination | "返回 \(.ReturnedCount) 条 / 总数 \(.TotalCount) 条；offset=\(.Offset)，完整=\(.Complete)"' >&2
}
