#!/usr/bin/env python3
"""Plan or provision explicit CVM network prerequisites, without deleting resources.

Verified against Tencent Cloud VPC API documentation, 2026-11-08:
CreateVpc: https://cloud.tencent.com/document/product/215/15774
CreateSubnet: https://cloud.tencent.com/document/product/215/15782
CreateSecurityGroupWithPolicies: https://cloud.tencent.com/document/api/215/43279
"""
import argparse
import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import sys
import tempfile

COMMON = Path(__file__).resolve().parents[1] / "common.sh"
ENTRY = Path(__file__).with_name("ensure-network.sh")
IDS = {"VpcId": "vpc-", "SubnetId": "subnet-", "SecurityGroupId": "sg-"}
READS = {
    "VpcId": ("DescribeVpcs", "VpcIds", "VpcSet"),
    "SubnetId": ("DescribeSubnets", "SubnetIds", "SubnetSet"),
    "SecurityGroupId": ("DescribeSecurityGroups", "SecurityGroupIds", "SecurityGroupSet"),
}


class NetworkError(Exception):
    pass


def cidr(value):
    try:
        result = ipaddress.ip_network(value, strict=True)
    except ValueError as exc:
        raise NetworkError(f"无效 CIDR: {value}") from exc
    if result.version != 4:
        raise NetworkError("当前网络前置只配置 IPv4")
    return result


def private_cidr(value, minimum_prefix):
    result = cidr(value)
    allowed = [ipaddress.ip_network(item) for item in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")]
    if not any(result.subnet_of(block) for block in allowed) or not minimum_prefix <= result.prefixlen <= 28:
        raise NetworkError(f"网段须为 RFC1918 私网 CIDR，掩码范围 /{minimum_prefix}–/28")
    return result


def api(region, service, action, **parameters):
    argv = ["/bin/bash", "-c", 'source "$1"; shift; check_api_prerequisites; execute_tccli "$@"',
            "network-api", str(COMMON), service, action, "--region", region]
    for key, value in parameters.items():
        argv += [f"--{key}", json.dumps(value, ensure_ascii=False) if isinstance(value, (dict, list, bool)) else str(value)]
    proc = subprocess.run(argv, stdout=subprocess.PIPE, text=True)
    if proc.returncode:
        raise NetworkError(f"{action} 失败，已停止；不自动重试创建请求")
    try:
        result = json.loads(proc.stdout)
    except ValueError as exc:
        raise NetworkError(f"{action} 未返回有效 JSON") from exc
    if not isinstance(result, dict):
        raise NetworkError(f"{action} 响应不是对象")
    return result


def fetch(region, field, resource_id):
    action, parameter, result_key = READS[field]
    result = api(region, "vpc", action, **{parameter: [resource_id]})
    items = result.get(result_key)
    if not isinstance(items, list) or len(items) != 1 or items[0].get(field) != resource_id:
        raise NetworkError(f"当前账号/地域未精确找到 {resource_id}")
    if items[0].get("Region") not in (None, region):
        raise NetworkError(f"{resource_id} 不属于地域 {region}")
    return items[0]


def subnet_inventory(region, vpc_id):
    result = []
    offset = 0
    while True:
        page = api(region, "vpc", "DescribeSubnets", Filters=[{"Name": "vpc-id", "Values": [vpc_id]}], Offset=offset, Limit=100)
        items, total = page.get("SubnetSet"), page.get("TotalCount")
        if not isinstance(items, list) or not isinstance(total, int):
            raise NetworkError("子网列表缺少有效分页信息")
        if any(item.get("VpcId") != vpc_id for item in items):
            raise NetworkError("子网查询返回了其他 VPC 的资源")
        result.extend(items)
        offset += len(items)
        if offset >= total:
            return result
        if not items or offset > 100000:
            raise NetworkError("子网分页没有进展，已停止")


def policy_set(args):
    ingress = []
    if args.allow_web:
        for port in ("80", "443"):
            ingress.append({"Protocol": "TCP", "Port": port, "CidrBlock": "0.0.0.0/0", "Action": "ACCEPT"})
    if args.ssh_cidr:
        scope = cidr(args.ssh_cidr)
        if scope.prefixlen == 0 or scope.is_multicast:
            raise NetworkError("SSH 来源必须是明确限定的 IPv4 CIDR，不能使用 0.0.0.0/0")
        ingress.append({"Protocol": "TCP", "Port": "22", "CidrBlock": str(scope), "Action": "ACCEPT"})
    # ALL protocol has no Port field (the API defines these as exclusive).
    return {"Ingress": ingress, "Egress": [{"Protocol": "ALL", "CidrBlock": "0.0.0.0/0", "Action": "ACCEPT"}]}


def normalized_policies(policies):
    keys = ("Protocol", "Port", "CidrBlock", "Ipv6CidrBlock", "Action", "SecurityGroupId", "AddressTemplate", "ServiceTemplate")

    def clean_template(value):
        if not isinstance(value, dict):
            return value
        # DescribeSecurityGroupPolicies fills absent templates with empty ID
        # fields. These do not add a rule constraint; real template IDs do.
        cleaned = {}
        for key, field in value.items():
            field = clean_template(field)
            if field not in (None, "", {}):
                cleaned[key] = field
        return cleaned

    result = {}
    for direction in ("Ingress", "Egress"):
        rules = policies.get(direction, [])
        if not isinstance(rules, list):
            raise NetworkError("安全组规则格式无效")
        cleaned = []
        for rule in rules:
            item = {}
            for key in keys:
                value = rule.get(key)
                if key in ("AddressTemplate", "ServiceTemplate"):
                    value = clean_template(value)
                if value not in (None, "", {}):
                    item[key] = value
            for key in ("Protocol", "Action"):
                if isinstance(item.get(key), str):
                    item[key] = item[key].upper()
            if item.get("Protocol") == "ALL" and str(item.get("Port", "")).upper() == "ALL":
                item.pop("Port", None)
            cleaned.append(json.dumps(item, sort_keys=True))
        result[direction] = sorted(cleaned)
    return result


class Checkpoint:
    def __init__(self, path, writable):
        self.path = path
        self.lock = None
        self.value = None
        if path.is_symlink():
            raise NetworkError("checkpoint 不能是符号链接")
        if writable:
            path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            lock_path = path.with_suffix(path.suffix + ".lock")
            flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
            self.lock = os.open(lock_path, flags, 0o600)
            os.fchmod(self.lock, 0o600)
            try:
                fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as exc:
                raise NetworkError("同一网络计划正在执行，请等待该进程结束") from exc
        if path.exists():
            if not stat.S_ISREG(path.stat().st_mode):
                raise NetworkError("checkpoint 必须是普通文件")
            with path.open(encoding="utf-8") as stream:
                self.value = json.load(stream)
            if not isinstance(self.value, dict) or self.value.get("Version") != 1:
                raise NetworkError("checkpoint 格式或版本无效")

    def save(self):
        if self.lock is None:
            return
        fd, name = tempfile.mkstemp(prefix=".network-", dir=self.path.parent)
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as stream:
                json.dump(self.value, stream, ensure_ascii=False, indent=2)
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(name, self.path)
        finally:
            if os.path.exists(name):
                os.unlink(name)

    def close(self):
        if self.lock is not None:
            os.close(self.lock)
            self.lock = None


class Workflow:
    def __init__(self, args):
        self.args = args
        self.profile = args.profile or os.environ.get("TENCENT_CVM_PROFILE") or os.environ.get("TCCLI_PROFILE") or "default"
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", self.profile):
            raise NetworkError("profile 格式无效")
        selected_profile = args.profile or os.environ.get("TENCENT_CVM_PROFILE") or os.environ.get("TCCLI_PROFILE")
        environment_credentials = bool(os.environ.get("TENCENTCLOUD_SECRET_ID") and os.environ.get("TENCENTCLOUD_SECRET_KEY"))
        self.auth_source = "environment" if not selected_profile and environment_credentials else "profile"
        if args.profile:
            os.environ["TENCENT_CVM_PROFILE"] = args.profile
        if not re.fullmatch(r"[a-z]{2,}-[a-z0-9]+(?:-[a-z0-9]+)*", args.region) or not args.zone.startswith(args.region + "-"):
            raise NetworkError("地域或可用区格式无效，且 zone 必须属于所选地域")
        if not args.name or len(args.name.encode("utf-8")) > 48 or any(ord(c) < 32 for c in args.name):
            raise NetworkError("--name 须为 1–48 字节且不含控制字符")
        self.policies = policy_set(args)
        for value, prefix in ((args.vpc_id, "vpc-"), (args.subnet_id, "subnet-"), (args.sg_id, "sg-")):
            if value and not re.fullmatch(re.escape(prefix) + r"[A-Za-z0-9]+", value):
                raise NetworkError(f"资源 ID 格式无效: {value}")
        if args.vpc_cidr:
            private_cidr(args.vpc_cidr, 12)
        if args.subnet_cidr:
            private_cidr(args.subnet_cidr, 16)
        token = hashlib.sha256((args.region + ":" + args.zone + ":" + args.name).encode()).hexdigest()[:16]
        self.state_path = Path(args.state_file).expanduser().absolute() if args.state_file else Path.home() / ".tencent-cvm" / self.profile / "networks" / (token + ".json")
        self.checkpoint = Checkpoint(self.state_path, args.yes)
        self.loaded_checkpoint = self.checkpoint.value is not None
        self.config = {"Profile": self.profile, "AuthSource": self.auth_source, "Region": args.region, "Zone": args.zone, "Name": args.name,
                       "VpcCidr": args.vpc_cidr, "SubnetCidr": args.subnet_cidr, "NewSecurityGroupPolicies": self.policies}
        if self.checkpoint.value and self.checkpoint.value.get("Config") != self.config:
            raise NetworkError("checkpoint 属于不同账号/地域/配置；请使用原配置恢复或另选 --state-file")
        self.state = self.checkpoint.value or {"Version": 1, "Config": self.config, "Resources": {}, "Created": {}, "PendingOperation": None}
        self.checkpoint.value = self.state
        self.ids = self.state["Resources"]
        self.explicit = {"VpcId": args.vpc_id, "SubnetId": args.subnet_id, "SecurityGroupId": args.sg_id}
        for field, value in self.explicit.items():
            if value and self.ids.get(field) not in (None, value):
                raise NetworkError(f"{field} 与 checkpoint 中已完成的资源不一致")
            if value:
                self.ids[field] = value
        self.plan = None

    def resume_command(self, execute=False):
        args = ["bash", str(ENTRY), "--region", self.args.region, "--zone", self.args.zone,
                "--name", self.args.name, "--state-file", str(self.state_path)]
        if self.auth_source == "profile":
            args += ["--profile", self.profile]
        if self.args.create:
            args += ["--create"]
        for option in ("vpc_cidr", "subnet_cidr", "ssh_cidr"):
            value = getattr(self.args, option)
            # A fresh read-only plan emits concrete CIDRs for its apply command.
            if execute and self.plan and not self.loaded_checkpoint and option in ("vpc_cidr", "subnet_cidr"):
                value = self.plan["Vpc" if option == "vpc_cidr" else "Subnet"]["CidrBlock"]
            if value:
                args += ["--" + option.replace("_", "-"), value]
        if self.args.allow_web:
            args += ["--allow-web"]
        for field, option in (("VpcId", "--vpc-id"), ("SubnetId", "--subnet-id"), ("SecurityGroupId", "--sg-id")):
            if self.ids.get(field):
                args += [option, self.ids[field]]
        return " ".join(shlex.quote(arg) for arg in args + ["--yes" if execute else "--plan"])

    def output(self, status, message=None):
        result = {"Status": status, "Profile": self.profile, "AuthSource": self.auth_source, "Region": self.args.region, "Zone": self.args.zone,
                  "VpcId": self.ids.get("VpcId"), "SubnetId": self.ids.get("SubnetId"), "SecurityGroupId": self.ids.get("SecurityGroupId"),
                  "VirtualPrivateCloud": {k: self.ids.get(k) for k in ("VpcId", "SubnetId")},
                  "SecurityGroupIds": [self.ids["SecurityGroupId"]] if self.ids.get("SecurityGroupId") else [],
                  "Created": self.state["Created"], "StateFile": str(self.state_path),
                  "PendingOperation": self.state.get("PendingOperation"), "ResumeCommand": self.resume_command()}
        if self.plan:
            result["Plan"] = self.plan
            if status == "planned":
                result["ExecuteCommand"] = self.resume_command(execute=True)
        if message:
            result["Error"] = message
        pending = self.state.get("PendingOperation")
        if pending:
            resource = pending["Resource"]
            action, filter_name, name_field = {
                "VpcId": ("DescribeVpcs", "vpc-name", "VpcName"),
                "SubnetId": ("DescribeSubnets", "subnet-name", "SubnetName"),
                "SecurityGroupId": ("DescribeSecurityGroups", "security-group-name", "GroupName"),
            }[resource]
            lookup = ["python3", str(COMMON.parent / "tccli_locked.py"), "vpc", action, "--region", self.args.region,
                      "--output", "json", "--Filters", json.dumps([{"Name": filter_name, "Values": [pending["Parameters"][name_field]]}], ensure_ascii=False)]
            if self.auth_source == "profile":
                lookup += ["--profile", self.profile]
            result["ReconcileCommand"] = " ".join(shlex.quote(arg) for arg in lookup)
            result["RecoveryNote"] = "先查询同名资源并核对网段/可用区/规则；找到后向原命令显式补充对应 ID 恢复。确认未创建且需改参数时，用已创建 ID 和新的 state-file 重新生成计划。"
        return result

    def build_plan(self):
        a = self.args
        pending = self.state.get("PendingOperation")
        if pending and not self.explicit.get(pending["Resource"]):
            raise NetworkError(f"上次 {pending['Action']} 结果未确认；先查询已创建资源，再显式传入对应 ID 恢复，不能直接重复创建")
        zones = api(a.region, "cvm", "DescribeZones").get("ZoneSet")
        if not isinstance(zones, list) or not any(zone.get("Zone") == a.zone and zone.get("ZoneState") == "AVAILABLE" for zone in zones):
            raise NetworkError("所选可用区不存在或不可用")
        resources = {}
        for field, resource_id in self.ids.items():
            resources[field] = fetch(a.region, field, resource_id)
        subnet = resources.get("SubnetId")
        if subnet:
            if subnet.get("Zone") != a.zone:
                raise NetworkError("指定子网不属于所选可用区")
            if self.ids.get("VpcId") and subnet.get("VpcId") != self.ids["VpcId"]:
                raise NetworkError("指定子网不属于所选 VPC")
            if not self.ids.get("VpcId"):
                self.ids["VpcId"] = subnet["VpcId"]
                resources["VpcId"] = fetch(a.region, "VpcId", subnet["VpcId"])
        missing = [field for field in IDS if not self.ids.get(field)]
        if missing and not a.create:
            raise NetworkError("缺少明确资源 ID: " + ", ".join(missing) + "；允许新建时请加 --create，默认仍只生成计划")
        vpc = resources.get("VpcId")
        vpc_cidr = private_cidr(vpc["CidrBlock"] if vpc else (a.vpc_cidr or "10.0.0.0/16"), 12)
        if vpc and a.vpc_cidr and str(vpc_cidr) != a.vpc_cidr:
            raise NetworkError("复用 VPC 的 CIDR 与指定值不同")
        fixed_subnet = self.state.get("PlannedSubnetCidr")
        requested_subnet = a.subnet_cidr or fixed_subnet
        subnet_cidr = private_cidr(subnet["CidrBlock"] if subnet else (requested_subnet or str(next(vpc_cidr.subnets(new_prefix=max(vpc_cidr.prefixlen, 24))))), 16)
        if not subnet_cidr.subnet_of(vpc_cidr):
            raise NetworkError("子网 CIDR 不在 VPC 网段内")
        if subnet and a.subnet_cidr and str(subnet_cidr) != a.subnet_cidr:
            raise NetworkError("复用子网的 CIDR 与指定值不同")
        if vpc and not subnet:
            existing = subnet_inventory(a.region, self.ids["VpcId"])
            used = [cidr(item["CidrBlock"]) for item in existing]
            if not requested_subnet:
                candidates = vpc_cidr.subnets(new_prefix=max(vpc_cidr.prefixlen, 24))
                subnet_cidr = next((candidate for candidate in candidates if not any(candidate.overlaps(item) for item in used)), None)
                if subnet_cidr is None:
                    raise NetworkError("VPC 没有可分配的默认子网，请明确指定其他 --subnet-cidr")
            elif any(subnet_cidr.overlaps(item) for item in used):
                raise NetworkError("待创建子网与已有子网重叠")
        policies = self.policies
        if self.ids.get("SecurityGroupId"):
            policies = api(a.region, "vpc", "DescribeSecurityGroupPolicies", SecurityGroupId=self.ids["SecurityGroupId"]).get("SecurityGroupPolicySet")
            if not isinstance(policies, dict):
                raise NetworkError("安全组规则查询未返回规则集合")
            normalized_policies(policies)
            if self.state["Created"].get("SecurityGroupId") and normalized_policies(policies) != normalized_policies(self.policies):
                raise NetworkError("已创建安全组的规则与原计划不一致，已停止；不会覆盖现有规则")
            if a.allow_web or a.ssh_cidr:
                # These flags describe newly created policies, never edits to existing groups.
                if not self.state["Created"].get("SecurityGroupId") and not (pending and pending["Resource"] == "SecurityGroupId"):
                    raise NetworkError("--allow-web/--ssh-cidr 仅用于新建安全组；复用安全组仅检查现有规则，不自动修改")
        if pending:
            field = pending["Resource"]
            current = resources[field]
            param = pending["Parameters"]
            pairs = {"VpcId": (("VpcName", "VpcName"), ("CidrBlock", "CidrBlock")),
                     "SubnetId": (("SubnetName", "SubnetName"), ("CidrBlock", "CidrBlock"), ("Zone", "Zone"), ("VpcId", "VpcId")),
                     "SecurityGroupId": (("SecurityGroupName", "GroupName"),)}[field]
            if any(current.get(actual) != param[expected] for actual, expected in pairs):
                raise NetworkError("恢复 ID 的实际配置与上次待确认创建请求不一致")
            if field == "SecurityGroupId" and normalized_policies(policies) != normalized_policies(param["SecurityGroupPolicySet"]):
                raise NetworkError("恢复的安全组规则与待确认计划不一致")
            self.state["Created"][field] = self.ids[field]
            self.state["PendingOperation"] = None
        self.plan = {
            "Vpc": {"Mode": "reuse" if vpc else "create", "VpcId": self.ids.get("VpcId"), "Name": vpc.get("VpcName") if vpc else a.name + "-vpc", "CidrBlock": str(vpc_cidr)},
            "Subnet": {"Mode": "reuse" if subnet else "create", "SubnetId": self.ids.get("SubnetId"), "Name": subnet.get("SubnetName") if subnet else a.name + "-subnet", "CidrBlock": str(subnet_cidr), "Zone": a.zone},
            "SecurityGroup": {"Mode": "reuse" if self.ids.get("SecurityGroupId") else "create", "SecurityGroupId": self.ids.get("SecurityGroupId"), "Name": resources["SecurityGroupId"].get("SecurityGroupName") if self.ids.get("SecurityGroupId") else a.name + "-sg", "Policies": policies,
                              "Review": "复用组规则仅展示，不改写；模板引用等规则应进一步核对" if self.ids.get("SecurityGroupId") else "默认无入站规则；按明确选项开放 Web/限定来源 SSH，出站放行 IPv4"},
        }
        self.state["PlannedSubnetCidr"] = str(subnet_cidr)

    def create_one(self, field, action, parameters, result_key):
        self.state["PendingOperation"] = {"Resource": field, "Action": action, "Parameters": parameters}
        self.checkpoint.save()  # Before the request: a crash/timeout must never trigger blind replay.
        result = api(self.args.region, "vpc", action, **parameters)
        resource_id = result.get(result_key, {}).get(field)
        if not isinstance(resource_id, str) or not re.fullmatch(re.escape(IDS[field]) + r"[A-Za-z0-9]+", resource_id):
            raise NetworkError(f"{action} 未返回有效资源 ID，需要先核实创建结果")
        self.ids[field] = resource_id
        self.state["Created"][field] = resource_id
        self.state["PendingOperation"] = None
        self.checkpoint.save()

    def run(self):
        self.build_plan()
        if not self.args.yes:
            return self.output("planned")
        self.checkpoint.save()
        if not self.ids.get("VpcId"):
            self.create_one("VpcId", "CreateVpc", {"VpcName": self.plan["Vpc"]["Name"], "CidrBlock": self.plan["Vpc"]["CidrBlock"]}, "Vpc")
        if not self.ids.get("SubnetId"):
            self.create_one("SubnetId", "CreateSubnet", {"VpcId": self.ids["VpcId"], "SubnetName": self.plan["Subnet"]["Name"],
                            "CidrBlock": self.plan["Subnet"]["CidrBlock"], "Zone": self.args.zone}, "Subnet")
        if not self.ids.get("SecurityGroupId"):
            self.create_one("SecurityGroupId", "CreateSecurityGroupWithPolicies", {"GroupName": self.plan["SecurityGroup"]["Name"],
                            "GroupDescription": "CVM skill explicit network plan", "SecurityGroupPolicySet": self.policies}, "SecurityGroup")
        return self.output("ready")


def arguments():
    parser = argparse.ArgumentParser(description="明确复用或创建 CVM 网络；默认仅输出 JSON 计划，--yes 执行已确认计划，不交互重复确认。")
    parser.add_argument("--region", required=True)
    parser.add_argument("--zone", required=True)
    parser.add_argument("--profile")
    parser.add_argument("--vpc-id")
    parser.add_argument("--subnet-id")
    parser.add_argument("--sg-id")
    parser.add_argument("--create", action="store_true", help="允许创建缺少的资源；未加 --yes 时仍只读")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--plan", action="store_true", help="只读查询并输出计划（默认）")
    mode.add_argument("--yes", action="store_true", help="执行已获授权的具体计划，不重复询问")
    parser.add_argument("--name", default="cvm-skill-network", help="资源名称前缀，最多 48 UTF-8 字节")
    parser.add_argument("--vpc-cidr", help="新 VPC 默认 10.0.0.0/16")
    parser.add_argument("--subnet-cidr", help="默认选择 VPC 中第一个不重叠的 /24 或更小子网，具体值展示在计划中")
    parser.add_argument("--allow-web", action="store_true", help="仅新建 SG：允许公网 TCP 80/443")
    parser.add_argument("--ssh-cidr", help="仅新建 SG：允许明确 IPv4 CIDR 访问 TCP 22，禁止 0.0.0.0/0")
    parser.add_argument("--state-file", help="恢复 checkpoint 路径；默认按 profile/region/zone/name 隔离，权限 600")
    return parser.parse_args()


def main():
    workflow = None
    try:
        workflow = Workflow(arguments())
        output = workflow.run()
        status = 0
    except (NetworkError, OSError, ValueError, KeyError, TypeError) as exc:
        message = str(exc)
        print(message, file=sys.stderr)
        output = workflow.output("blocked", message) if workflow else {"Status": "blocked", "Error": message}
        status = 1
    finally:
        if workflow:
            workflow.checkpoint.close()
    print(json.dumps(output, ensure_ascii=False, indent=2))
    return status


if __name__ == "__main__":
    sys.exit(main())
