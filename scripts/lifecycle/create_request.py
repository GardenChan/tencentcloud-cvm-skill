#!/usr/bin/env python3
"""Build one validated CVM request; never contact the cloud or print credentials.

Supported fields are common to RunInstances and InquiryPriceRunInstances (CVM
2017-03-12). Reject unsupported fields instead of silently dropping a purchase
option. More advanced API requests should use tccli through tccli_locked.py.
"""
import argparse
import copy
import json
import os
import re
import sys
import uuid

FIELDS = {
    "Region", "Placement", "InstanceType", "ImageId", "InstanceName",
    "InstanceChargeType", "InstanceChargePrepaid", "SystemDisk", "DataDisks",
    "VirtualPrivateCloud", "SecurityGroupIds", "InternetAccessible",
    "LoginSettings", "InstanceCount", "EnhancedService", "ClientToken",
    "HostName", "TagSpecification", "Metadata", "CpuTopology", "HpcClusterId",
}
# Explicit subset verified against the CVM 2017-03-12 SDK. SDK _deserialize
# ignores unknown nested keys, so reject them before they can change a purchase.
# Output-only DiskId and dedicated-host placement are intentionally unsupported.
SCHEMA = {field: None for field in FIELDS}
SCHEMA.update({
    "Placement": {key: None for key in ("Zone", "ProjectId")},
    "InstanceChargePrepaid": {key: None for key in ("Period", "RenewFlag")},
    "SystemDisk": {key: None for key in ("DiskType", "DiskSize", "CdcId", "DiskName")},
    "DataDisks": [{key: None for key in ("DiskSize", "DiskType", "DeleteWithInstance", "SnapshotId", "Encrypt", "KmsKeyId", "ThroughputPerformance", "CdcId", "BurstPerformance", "DiskName")}],
    "VirtualPrivateCloud": {"VpcId": None, "SubnetId": None, "AsVpcGateway": None, "PrivateIpAddresses": [None], "Ipv6AddressCount": None},
    "InternetAccessible": {key: None for key in ("InternetChargeType", "InternetMaxBandwidthOut", "PublicIpAssigned", "BandwidthPackageId", "InternetServiceProvider", "IPv4AddressType", "IPv6AddressType", "AntiDDoSPackageId")},
    "LoginSettings": {"Password": None, "KeyIds": [None], "KeepImageLogin": None},
    "EnhancedService": {key: {"Enabled": None} for key in ("SecurityService", "MonitorService", "AutomationService")},
    "TagSpecification": [{"ResourceType": None, "Tags": [{"Key": None, "Value": None}]}],
    "Metadata": {"Items": [{"Key": None, "Value": None}]},
    "CpuTopology": {"CoreCount": None, "ThreadPerCore": None},
    "SecurityGroupIds": [None],
})


def validate_fields(value, schema=SCHEMA, path="config"):
    if isinstance(schema, dict):
        if not isinstance(value, dict):
            raise ValueError(f"{path} 必须是对象")
        unknown = set(value) - set(schema)
        if unknown:
            raise ValueError(f"{path} 存在未支持的字段: " + ", ".join(sorted(unknown)))
        for key, item in value.items():
            validate_fields(item, schema[key], f"{path}.{key}")
    elif isinstance(schema, list):
        if not isinstance(value, list):
            raise ValueError(f"{path} 必须是数组")
        for index, item in enumerate(value):
            validate_fields(item, schema[0], f"{path}[{index}]")
    elif isinstance(value, (dict, list)):
        raise ValueError(f"{path} 必须是标量值")


def merge(base, override):
    result = copy.deepcopy(base)
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = merge(result[key], value)
        else:
            result[key] = copy.deepcopy(value)
    return result


def integer(value, label, minimum=1, maximum=None):
    if isinstance(value, bool):
        raise ValueError(f"{label} 必须是整数")
    if isinstance(value, str) and not value.isdigit():
        raise ValueError(f"{label} 必须是整数")
    if not isinstance(value, (int, str)):
        raise ValueError(f"{label} 必须是整数")
    number = int(value)
    if number < minimum or (maximum is not None and number > maximum):
        raise ValueError(f"{label} 超出有效范围")
    return number


def validate_billing(request):
    """Validate the supported instance/network billing subset without cloud calls.

    Verified 2026-11-08: InternetAccessible enum and permitted billing pairs:
    https://cloud.tencent.com/document/product/213/15753
    https://cloud.tencent.com/document/product/213/10578
    BANDWIDTH_PACKAGE needs separate pricing and is deliberately unsupported.
    """
    charge = request["InstanceChargeType"]
    if charge not in ("POSTPAID_BY_HOUR", "PREPAID"):
        raise ValueError("封装仅支持 POSTPAID_BY_HOUR 或 PREPAID")
    if charge == "PREPAID":
        prepaid = request.setdefault("InstanceChargePrepaid", {})
        period = integer(prepaid.get("Period"), "包年包月时长")
        if period not in list(range(1, 13)) + [24, 36, 48, 60]:
            raise ValueError("包年包月时长不受支持")
        prepaid["Period"] = period
        prepaid.setdefault("RenewFlag", "NOTIFY_AND_MANUAL_RENEW")
    elif "InstanceChargePrepaid" in request:
        raise ValueError("按量付费不能指定购买时长或 InstanceChargePrepaid")
    internet = request["InternetAccessible"]
    if not isinstance(internet.get("PublicIpAssigned"), bool):
        raise ValueError("PublicIpAssigned 必须是布尔值")
    internet["InternetMaxBandwidthOut"] = integer(internet.get("InternetMaxBandwidthOut", 0), "带宽", 0, 200)
    if internet["PublicIpAssigned"] and internet["InternetMaxBandwidthOut"] == 0:
        raise ValueError("申请公网 IP 时请明确设置正数带宽")
    network_charge = internet.get("InternetChargeType")
    supported = ("TRAFFIC_POSTPAID_BY_HOUR", "BANDWIDTH_POSTPAID_BY_HOUR", "BANDWIDTH_PREPAID")
    if network_charge not in supported:
        raise ValueError("公网计费仅支持 " + "、".join(supported))
    if network_charge == "BANDWIDTH_PREPAID" and charge != "PREPAID":
        raise ValueError("BANDWIDTH_PREPAID 仅支持 PREPAID 实例")
    if network_charge == "BANDWIDTH_POSTPAID_BY_HOUR" and charge != "POSTPAID_BY_HOUR":
        raise ValueError("BANDWIDTH_POSTPAID_BY_HOUR 仅支持 POSTPAID_BY_HOUR 实例")


def build(args):
    env = os.environ
    def default(name, fallback=""):
        return env.get("TENCENT_CVM_DEFAULT_" + name, fallback)
    request = {
        "Region": default("REGION", "ap-guangzhou"),
        "Placement": {"Zone": default("ZONE")},
        "InstanceType": default("INSTANCE_TYPE"),
        "ImageId": default("IMAGE_ID"),
        "InstanceChargeType": default("CHARGE_TYPE", "POSTPAID_BY_HOUR"),
        "SystemDisk": {"DiskType": "CLOUD_PREMIUM", "DiskSize": integer(default("DISK_SIZE", "20"), "系统盘")},
        "VirtualPrivateCloud": {"VpcId": default("VPC_ID"), "SubnetId": default("SUBNET_ID")},
        "SecurityGroupIds": [default("SG_ID")] if default("SG_ID") else [],
        "InternetAccessible": {"PublicIpAssigned": False, "InternetMaxBandwidthOut": 0, "InternetChargeType": "TRAFFIC_POSTPAID_BY_HOUR"},
        "InstanceCount": 1,
    }
    if default("DATA_DISK_SIZE"):
        request["DataDisks"] = [{"DiskType": "CLOUD_PREMIUM", "DiskSize": integer(default("DATA_DISK_SIZE"), "数据盘")}]
    if args.config:
        with open(args.config, encoding="utf-8") as stream:
            config = json.load(stream)
        if not isinstance(config, dict):
            raise ValueError("配置文件必须是 JSON 对象")
        validate_fields(config)
        request = merge(request, config)
    direct = {"region": "Region", "instance_type": "InstanceType", "image_id": "ImageId", "name": "InstanceName", "charge_type": "InstanceChargeType", "client_token": "ClientToken"}
    for attr, key in direct.items():
        if getattr(args, attr) is not None:
            request[key] = getattr(args, attr)
    nested = {"zone": ("Placement", "Zone"), "vpc_id": ("VirtualPrivateCloud", "VpcId"), "subnet_id": ("VirtualPrivateCloud", "SubnetId"), "disk_size": ("SystemDisk", "DiskSize"), "disk_type": ("SystemDisk", "DiskType"), "period": ("InstanceChargePrepaid", "Period")}
    for attr, (group, key) in nested.items():
        if getattr(args, attr) is not None:
            request.setdefault(group, {})[key] = getattr(args, attr)
    if args.sg_id:
        request["SecurityGroupIds"] = args.sg_id
    if args.data_disk_size is not None:
        size = integer(args.data_disk_size, "数据盘", 0)
        request["DataDisks"] = [{"DiskType": "CLOUD_PREMIUM", "DiskSize": size}] if size else []
    if args.key_id:
        request["LoginSettings"] = {"KeyIds": args.key_id}
    if args.password_login:
        if request.get("LoginSettings"):
            raise ValueError("--password-login 不能与配置中的 LoginSettings 或 --key-id 同用")
        # Password is added later through a protected temporary file.
    internet = request["InternetAccessible"]
    if args.internet_charge_type is not None:
        internet["InternetChargeType"] = args.internet_charge_type
    if args.public_ip is not None:
        internet["PublicIpAssigned"] = args.public_ip
        internet["InternetMaxBandwidthOut"] = (args.bandwidth if args.bandwidth is not None else (internet.get("InternetMaxBandwidthOut") or 5)) if args.public_ip else 0
    elif args.bandwidth is not None:
        internet["InternetMaxBandwidthOut"] = args.bandwidth
    if args.bandwidth is not None and not internet.get("PublicIpAssigned"):
        raise ValueError("--bandwidth 需要 --public-ip 或配置 PublicIpAssigned=true")
    if args.internet_charge_type is not None and not internet.get("PublicIpAssigned"):
        raise ValueError("--internet-charge-type 需要 --public-ip 或配置 PublicIpAssigned=true")
    if not re.fullmatch(r"[a-z][a-z0-9-]*-[0-9a-z]+", request["Region"]):
        raise ValueError("Region 格式不正确")
    for group in ("Placement", "SystemDisk", "VirtualPrivateCloud", "InternetAccessible"):
        if not isinstance(request[group], dict):
            raise ValueError(f"{group} 必须是对象")
    required = [
        (request["Placement"].get("Zone"), "Zone", re.escape(request["Region"]) + r"-\d+"),
        (request["InstanceType"], "InstanceType", r"[A-Za-z0-9]+\.[A-Za-z0-9]+"),
        (request["ImageId"], "ImageId", r"img-[A-Za-z0-9-]+"),
    ]
    for value, label, pattern in [
        (request["VirtualPrivateCloud"].get("VpcId"), "VpcId", r"vpc-[A-Za-z0-9-]+"),
        (request["VirtualPrivateCloud"].get("SubnetId"), "SubnetId", r"subnet-[A-Za-z0-9-]+"),
    ]:
        if args.allow_missing_network and value in (None, ""):
            request["VirtualPrivateCloud"].pop(label, None)
        else:
            required.append((value, label, pattern))
    for value, label, pattern in required:
        if not isinstance(value, str) or not re.fullmatch(pattern, value):
            raise ValueError(f"缺少或无效的 {label}")
    groups = request["SecurityGroupIds"]
    if not isinstance(groups, list) or (not groups and not args.allow_missing_network) or any(not isinstance(x, str) or not re.fullmatch(r"sg-[A-Za-z0-9-]+", x) for x in groups):
        raise ValueError("必须明确指定有效 SecurityGroupIds")
    if args.allow_missing_network:
        if not request["VirtualPrivateCloud"]:
            del request["VirtualPrivateCloud"]
        if not groups:
            del request["SecurityGroupIds"]
    request["SystemDisk"]["DiskSize"] = integer(request["SystemDisk"]["DiskSize"], "系统盘")
    disks = request.get("DataDisks", [])
    if not isinstance(disks, list):
        raise ValueError("DataDisks 必须是数组")
    for disk in disks:
        disk["DiskSize"] = integer(disk.get("DiskSize"), "数据盘")
    request["InstanceCount"] = integer(request["InstanceCount"], "创建封装一次只创建 1 台", 1, 1)
    validate_billing(request)
    login = request.get("LoginSettings", {})
    if not isinstance(login, dict):
        raise ValueError("LoginSettings 必须是对象")
    if sum(bool(login.get(key)) for key in ("Password", "KeyIds", "KeepImageLogin")) > 1:
        raise ValueError("Password、KeyIds、KeepImageLogin 不能同时启用")
    if "KeyIds" in login and (not isinstance(login["KeyIds"], list) or not login["KeyIds"] or any(not isinstance(x, str) or not re.fullmatch(r"skey-[A-Za-z0-9-]+", x) for x in login["KeyIds"])):
        raise ValueError("KeyIds 必须是 skey- 开头的密钥 ID 数组")
    token = request.setdefault("ClientToken", str(uuid.uuid4()))
    if not isinstance(token, str) or not re.fullmatch(r"[A-Za-z0-9_.:-]{1,64}", token):
        raise ValueError("ClientToken 必须是 1–64 位字母、数字或 _ . : -")
    request.setdefault("InstanceName", "cvm-" + token[:12])
    if not isinstance(request["InstanceName"], str) or not 1 <= len(request["InstanceName"]) <= 128:
        raise ValueError("实例名称长度必须为 1–128")
    return request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("config", "region", "zone", "instance-type", "image-id", "name", "disk-size", "disk-type", "data-disk-size", "vpc-id", "subnet-id", "charge-type", "period", "internet-charge-type", "client-token"):
        parser.add_argument("--" + name)
    parser.add_argument("--sg-id", action="append")
    login = parser.add_mutually_exclusive_group()
    login.add_argument("--key-id", action="append")
    login.add_argument("--password-login", action="store_true")
    public = parser.add_mutually_exclusive_group()
    public.add_argument("--public-ip", dest="public_ip", action="store_true", default=None)
    public.add_argument("--no-public-ip", dest="public_ip", action="store_false")
    parser.add_argument("--bandwidth", type=int)
    parser.add_argument("--allow-missing-network", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    try:
        print(json.dumps(build(args), ensure_ascii=False))
    except (ValueError, TypeError, AttributeError, OSError, KeyError) as error:
        parser.exit(2, f"配置错误: {error}\n")


if __name__ == "__main__":
    main()
