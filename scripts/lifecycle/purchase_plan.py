#!/usr/bin/env python3
"""Store and revalidate an immutable, password-free purchase proposal.

A plan is a review artifact, never authorization. Submission still requires the
caller to pass --yes after the user approved that exact proposal.
"""
import argparse
import copy
import datetime
import hashlib
import json
import math
import os
import stat
import sys


def read_json(path):
    with open(path, encoding="utf-8") as stream:
        return json.load(stream)


def fingerprint(plan):
    content = json.dumps({k: v for k, v in plan.items() if k != "plan_hash"}, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False)
    return hashlib.sha256(content.encode()).hexdigest()


def auth_source():
    selected = os.environ.get("TENCENT_CVM_PROFILE") or os.environ.get("TCCLI_PROFILE")
    credentials = os.environ.get("TENCENTCLOUD_SECRET_ID") and os.environ.get("TENCENTCLOUD_SECRET_KEY")
    return "environment" if not selected and credentials else "profile"


def missing_network(request):
    vpc = request.get("VirtualPrivateCloud", {})
    missing = [name for name in ("VpcId", "SubnetId") if not vpc.get(name)]
    if not request.get("SecurityGroupIds"):
        missing.append("SecurityGroupIds")
    return missing


def load_plan(path, profile, recovery=False):
    if recovery:
        metadata = os.lstat(path)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_mode & 0o077 or metadata.st_uid != os.getuid():
            raise ValueError("恢复文件必须由当前用户拥有，且仅当前用户可读写（权限 600）")
    plan = read_json(path)
    if not isinstance(plan, dict) or plan.get("schema_version") != 2:
        raise ValueError("不支持的购买计划格式，请重新准备方案")
    if plan.get("kind") != ("purchase_recovery" if recovery else "purchase_plan"):
        raise ValueError("恢复文件只能使用 --resume；普通计划使用 --from-plan")
    if plan.get("profile") != profile:
        raise ValueError("当前账号 profile 与已准备的计划不同，需重新准备方案")
    if plan.get("auth_source") != auth_source():
        raise ValueError("认证来源已改变（环境凭证/profile），需重新准备方案")
    request = plan.get("request")
    if not isinstance(request, dict) or not isinstance(plan.get("region"), str):
        raise ValueError("计划缺少有效地域或请求")
    if request.get("LoginSettings", {}).get("Password") and not recovery:
        raise ValueError("购买计划不得存储明文密码；请选择密钥或腾讯云默认登录方式")
    if plan.get("client_token") != request.get("ClientToken"):
        raise ValueError("计划的幂等标识不一致")
    if plan.get("plan_hash") != fingerprint(plan):
        raise ValueError("购买配置、报价或预算在准备后被修改，需重新询价并确认")
    if not isinstance(plan.get("price"), dict):
        raise ValueError("计划缺少报价")
    missing = missing_network(request)
    if plan.get("pending_network") != missing or bool(missing) != (plan.get("state") == "pending_network"):
        raise ValueError("计划网络状态不一致")
    if recovery and missing:
        raise ValueError("恢复文件必须包含已绑定的完整网络配置")
    return plan


def bind_network(plan, args):
    updates = {"VpcId": args.vpc_id, "SubnetId": args.subnet_id, "SecurityGroupIds": args.sg_id}
    supplied = {key: value for key, value in updates.items() if value is not None}
    missing = plan["pending_network"]
    if supplied and not missing:
        raise ValueError("已准备的完整计划不允许覆盖网络配置")
    if any(key not in missing for key in supplied):
        raise ValueError("只能补充原计划缺少的网络 ID，不能覆盖已固定的网络")
    if missing and set(supplied) != set(missing):
        raise ValueError("仍需明确补充网络 ID: " + ", ".join(sorted(set(missing) - set(supplied))))
    if supplied:
        plan = copy.deepcopy(plan)
        plan["source_plan_hash"] = plan["plan_hash"]
        for key, value in supplied.items():
            if key == "SecurityGroupIds":
                plan["request"][key] = value
            else:
                plan["request"].setdefault("VirtualPrivateCloud", {})[key] = value
        plan["pending_network"] = []
        plan["state"] = "pending_preflight"
        plan["plan_hash"] = fingerprint(plan)
    return plan


def no_increase(old, new, path="Price"):
    """Conservatively reject any added charge or change in pricing units.

    Compare effective amounts, allowing discounts to lower the price. Do not
    infer interchangeability between different units, currencies or components.
    """
    if isinstance(old, dict) and isinstance(new, dict):
        if old.keys() != new.keys():
            raise ValueError(f"{path} 的计费项目变化，需要重新确认")
        for key in old:
            no_increase(old[key], new[key], f"{path}.{key}")
    elif isinstance(old, list) and isinstance(new, list):
        if len(old) != len(new):
            raise ValueError(f"{path} 的计费项目变化，需要重新确认")
        for index, (previous, current) in enumerate(zip(old, new)):
            no_increase(previous, current, f"{path}[{index}]")
    elif type(old) in (int, float) and type(new) in (int, float):
        if not math.isfinite(old) or not math.isfinite(new) or new > old:
            raise ValueError(f"{path} 报价升高，需要重新确认")
    elif old != new or type(old) != type(new):
        raise ValueError(f"{path} 的计费口径变化，需要重新确认")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    load = sub.add_parser("load")
    load.add_argument("--path", required=True)
    load.add_argument("--profile", required=True)
    load.add_argument("--recovery", action="store_true")
    load.add_argument("--vpc-id")
    load.add_argument("--subnet-id")
    load.add_argument("--sg-id", action="append")
    create = sub.add_parser("create")
    for name in ("path", "profile", "region", "request-file", "price-file"):
        create.add_argument("--" + name, required=True)
    create.add_argument("--preflight-file")
    create.add_argument("--defer-network", action="store_true")
    create.add_argument("--recovery", action="store_true")
    create.add_argument("--base-plan")
    create.add_argument("--estimate-file")
    create.add_argument("--estimate-options-file")
    check = sub.add_parser("check-price")
    for name in ("path", "profile", "price-file"):
        check.add_argument("--" + name, required=True)
    check.add_argument("--recovery", action="store_true")
    args = parser.parse_args()
    try:
        if args.command == "load":
            plan = bind_network(load_plan(args.path, args.profile, args.recovery), args)
            print(json.dumps(plan, ensure_ascii=False))
        elif args.command == "check-price":
            plan = load_plan(args.path, args.profile, args.recovery)
            quote = read_json(args.price_file)
            no_increase(plan["price"], quote)
        else:
            request = read_json(args.request_file)
            if request.get("LoginSettings", {}).get("Password") and not args.recovery:
                raise ValueError("--prepare 不接受密码，请选择 --key-id 或腾讯云默认登录方式")
            missing = missing_network(request)
            if bool(missing) != args.defer_network:
                raise ValueError("--defer-network 仅适用于明确缺少网络 ID 的方案")
            if args.recovery and missing:
                raise ValueError("恢复请求不能缺少网络 ID")
            preflight_id = None
            if not args.defer_network:
                if not args.preflight_file:
                    raise ValueError("完整配置需要预检结果")
                preflight = read_json(args.preflight_file)
                preflight_id = preflight.get("Response", preflight)["RequestId"]
            plan = {
                "schema_version": 2,
                "kind": "purchase_recovery" if args.recovery else "purchase_plan",
                "profile": args.profile,
                "auth_source": auth_source(),
                "region": args.region,
                "request": request,
                "client_token": request["ClientToken"],
                "price": read_json(args.price_file),
                "state": "pending_network" if args.defer_network else "ready",
                "pending_network": missing,
                "preflight_request_id": preflight_id,
                "prepared_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            }
            if args.estimate_file:
                plan["cost_estimate"] = read_json(args.estimate_file)
            if args.estimate_options_file:
                plan["estimate_options"] = read_json(args.estimate_options_file)
            if args.base_plan:
                if not args.recovery:
                    raise ValueError("base-plan 只能用于保存已验证请求的恢复文件")
                base = read_json(args.base_plan)
                if base.get("plan_hash") != fingerprint(base):
                    raise ValueError("原计划完整性校验失败")
                for key in ("price", "estimate_options", "cost_estimate"):
                    if key in base:
                        plan[key] = base[key]
                plan["source_plan_hash"] = base["plan_hash"]
            plan["plan_hash"] = fingerprint(plan)
            encoded = json.dumps(plan, ensure_ascii=False, indent=2, allow_nan=False) + "\n"
            descriptor = os.open(args.path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                stream.write(encoded)
            if not args.recovery:
                print(encoded, end="")
    except (ValueError, TypeError, AttributeError, KeyError, OSError) as error:
        parser.exit(2, f"购买计划错误: {error}\n")


if __name__ == "__main__":
    main()
