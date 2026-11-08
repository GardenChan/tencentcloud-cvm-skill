"""Behavioral offline tests for purchase planning and lifecycle safety."""
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FAKE = r'''
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
action = args[1]
request = {}
request_path = None
if "--cli-input-json" in args:
    source = args[args.index("--cli-input-json") + 1]
    if source.startswith("file://"):
        request_path = Path(source[7:])
        request = json.loads(request_path.read_text())
    else:
        request = json.loads(source)
record = {"args": args, "request": request, "has_password": bool(request.get("LoginSettings", {}).get("Password"))}
if request_path:
    record["mode"] = request_path.stat().st_mode & 0o777
    record["request_path"] = str(request_path)
if record["has_password"]:
    record["request"]["LoginSettings"]["Password"] = "<redacted>"
log = Path(os.environ["TEST_LOG"])
previous = [json.loads(x) for x in log.read_text().splitlines()] if log.exists() else []
with log.open("a") as stream:
    stream.write(json.dumps(record) + "\n")
mode = os.environ.get("TEST_MODE", "")
if mode == "fail" or (mode == "dryrun-fail" and request.get("DryRun")) or (mode == "purchase-fail" and action == "RunInstances" and not request.get("DryRun")):
    print("AuthFailure: simulated", file=sys.stderr)
    sys.exit(31)
if action == "InquiryPriceRunInstances":
    response = {"Price": {"InstancePrice": {"UnitPrice": 1, "ChargeUnit": "HOUR", "OriginalPrice": 99}}}
    period = request.get("InstanceChargePrepaid", {}).get("Period", 1)
    if request.get("InstanceChargeType") == "PREPAID":
        response["Price"]["InstancePrice"] = {"OriginalPrice": 99 * period}
    internet = request.get("InternetAccessible", {})
    if internet.get("PublicIpAssigned"):
        charge = internet["InternetChargeType"]
        bandwidth = internet["InternetMaxBandwidthOut"]
        if charge == "BANDWIDTH_PREPAID": network = {"OriginalPrice": bandwidth * 10 * period}
        elif charge == "BANDWIDTH_POSTPAID_BY_HOUR": network = {"ChargeUnit": "HOUR", "UnitPrice": bandwidth * 0.01}
        else: network = {"ChargeUnit": "GB", "UnitPrice": 0.8}
        response["Price"]["BandwidthPrice"] = network
    if mode == "no-price": response = {"Price": {}}
    if mode == "price-up": response["Price"]["InstancePrice"]["UnitPrice"] = 2
    if mode == "price-slight-up": response["Price"]["InstancePrice"]["UnitPrice"] = 1.125
    if mode == "price-down": response["Price"]["InstancePrice"]["UnitPrice"] = 0.5
elif action == "RunInstances":
    response = {"RequestId": "request-new"} if request.get("DryRun") else {"RequestId": "request-new", "InstanceIdSet": ["ins-test"]}
    if mode == "dryrun-empty" and request.get("DryRun"): response = {}
    if mode == "purchase-empty" and not request.get("DryRun"): response = {"RequestId": "request-new"}
elif action == "CreateImage": response = {"ImageId": "img-test", "RequestId": "request-new"}
elif action == "DescribeZones": response = {"ZoneSet": [{"Zone": "ap-guangzhou-3", "ZoneState": "AVAILABLE"}]}
elif action == "DescribeZoneInstanceConfigInfos":
    response = {"InstanceTypeQuotaSet": [
        {"InstanceType": "S5.MEDIUM2", "Status": "SOLD_OUT", "Cpu": 1, "Memory": 2, "Gpu": 0},
        {"InstanceType": "S6.LARGE8", "Status": "SELL", "Cpu": 4, "Memory": 8, "Gpu": 0},
        {"InstanceType": "GN7.LARGE32", "Status": "SELL", "Cpu": 8, "Memory": 32, "Gpu": 1}]}
elif action == "DescribeImages": response = {"ImageSet": [{"ImageId": "img-compatible", "ImageState": "NORMAL", "CreatedTime": "2026-01-01"}]}
elif action == "DescribeInstances":
    count = sum(x["args"][1] == action for x in previous)
    operation_id = "request-old" if count == 0 and mode == "stale" else "request-new"
    response = {"InstanceSet": [{"InstanceId": "ins-test", "InstanceState": "RUNNING", "LatestOperationRequestId": operation_id, "LatestOperationState": "FAILED" if mode == "operation-failed" else "SUCCESS", "PublicIpAddresses": ["203.0.113.7"]}]}
    if mode == "absent": response = {"InstanceSet": []}
    if mode == "malformed": response = {}
    if mode == "wait-timeout": response["InstanceSet"][0]["InstanceState"] = "PENDING"
    if "TEST_INSTANCE" in os.environ: response = {"InstanceSet": [json.loads(os.environ["TEST_INSTANCE"])]}
else: response = {"RequestId": "request-new"}
print(json.dumps(response))
'''


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cvm-lifecycle-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        executable = self.bin / "tccli"
        executable.write_text(f"#!{sys.executable}\n" + FAKE)
        executable.chmod(0o755)
        for name, path in [("python3", sys.executable), ("jq", shutil.which("jq"))]:
            if not path: self.skipTest(f"{name} required")
            (self.bin / name).symlink_to(path)
        self.log = self.directory / "calls.jsonl"
        self.passwords = self.directory / "state.json"
        self.env = {"HOME": str(self.directory), "PATH": f"{self.bin}:/usr/bin:/bin", "LANG": "en_US.UTF-8", "TEST_LOG": str(self.log), "TENCENT_CVM_PASSWORD_FILE": str(self.passwords), "TMPDIR": str(self.directory), "TENCENT_CVM_PROFILE": "test-account"}
        self.config = {"Region": "ap-guangzhou", "Placement": {"Zone": "ap-guangzhou-3", "ProjectId": 17}, "InstanceType": "S5.MEDIUM2", "ImageId": "img-test", "VirtualPrivateCloud": {"VpcId": "vpc-test", "SubnetId": "subnet-test"}, "SecurityGroupIds": ["sg-test"], "SystemDisk": {"DiskType": "CLOUD_SSD", "DiskSize": 40}, "ClientToken": "fixed-test-token"}
        self.config_file = self.directory / "config.json"
        self.config_file.write_text(json.dumps(self.config))

    def run_script(self, name, *args, stdin=None, **env):
        return subprocess.run(["/bin/bash", str(ROOT / "scripts/lifecycle" / name), *args], env={**self.env, **env}, input=stdin, text=True, capture_output=True, cwd=ROOT, timeout=15)

    def calls(self):
        return [json.loads(x) for x in self.log.read_text().splitlines()] if self.log.exists() else []

    def assert_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def create(self, *args, **kwargs):
        return self.run_script("create-instance.sh", "--config", str(self.config_file), *args, **kwargs)

    def test_plan_is_offline_and_respects_configuration_precedence(self):
        result = self.create("--plan", "--disk-size", "60", TENCENT_CVM_DEFAULT_DISK_SIZE="10", TENCENT_CVM_DEFAULT_ZONE="ap-beijing-2")
        self.assert_ok(result)
        plan = json.loads(result.stdout)
        self.assertEqual(plan["SystemDisk"], {"DiskType": "CLOUD_SSD", "DiskSize": 60})
        self.assertEqual(plan["Placement"], {"Zone": "ap-guangzhou-3", "ProjectId": 17})
        self.assertFalse(plan["InternetAccessible"]["PublicIpAssigned"])
        self.assertNotIn("LoginSettings", plan)
        self.assertEqual(self.calls(), [])

    def test_purchase_preserves_one_request_and_idempotency(self):
        marker = self.directory / "injected"
        literal = f'quoted "name"; touch {marker}'
        result = self.create("--yes", "--name", literal, "--key-id", "skey-test")
        self.assert_ok(result)
        calls = self.calls()
        self.assertEqual([x["args"][1] for x in calls], ["InquiryPriceRunInstances", "RunInstances", "RunInstances"])
        quoted, dry, created = [x["request"] for x in calls]
        self.assertEqual({k: v for k, v in dry.items() if k != "DryRun"}, quoted)
        self.assertTrue(dry["DryRun"])
        self.assertEqual(created, quoted)
        self.assertEqual(created["InstanceName"], literal)
        self.assertEqual(created["ClientToken"], "fixed-test-token")
        self.assertEqual(created["LoginSettings"], {"KeyIds": ["skey-test"]})
        self.assertFalse(marker.exists())
        for call in calls:
            self.assertEqual(call["mode"], 0o600)
            self.assertFalse(Path(call["request_path"]).exists())
            self.assertNotIn("--DryRun", call["args"])

    def test_dry_run_never_purchases_and_failure_stops(self):
        for mode in ("", "dryrun-fail", "dryrun-empty", "no-price"):
            with self.subTest(mode=mode):
                self.log.unlink(missing_ok=True)
                result = self.create("--dry-run", TEST_MODE=mode)
                if mode: self.assertNotEqual(result.returncode, 0)
                else: self.assert_ok(result)
                runs = [x for x in self.calls() if x["args"][1] == "RunInstances"]
                self.assertTrue(all(x["request"].get("DryRun") for x in runs))
                self.assertLessEqual(len(runs), 1)

    def test_password_not_in_argv_or_output(self):
        result = self.create("--yes", "--password-login")
        self.assert_ok(result)
        saved = json.loads(self.passwords.read_text())
        password = saved["ins-test"]["password"]
        self.assertNotIn(password, result.stdout + result.stderr + self.log.read_text())
        self.assertTrue(all(x["has_password"] for x in self.calls()))
        self.assertEqual(stat.S_IMODE(self.passwords.stat().st_mode), 0o600)

    def test_prepaid_requires_period_and_preserves_it(self):
        result = self.create("--plan", "--charge-type", "PREPAID")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])
        result = self.create("--yes", "--charge-type", "PREPAID", "--period", "12")
        self.assert_ok(result)
        for call in self.calls():
            self.assertEqual(call["request"]["InstanceChargePrepaid"], {"Period": 12, "RenewFlag": "NOTIFY_AND_MANUAL_RENEW"})

    def test_explicit_network_billing_preserves_cli_precedence_and_public_defaults(self):
        self.config_file.write_text(json.dumps({**self.config, "InternetAccessible": {
            "PublicIpAssigned": True, "InternetMaxBandwidthOut": 2, "InternetChargeType": "TRAFFIC_POSTPAID_BY_HOUR"}}))
        result = self.create("--plan", "--internet-charge-type", "BANDWIDTH_POSTPAID_BY_HOUR", "--bandwidth", "3")
        self.assert_ok(result)
        self.assertEqual(json.loads(result.stdout)["InternetAccessible"], {
            "PublicIpAssigned": True, "InternetMaxBandwidthOut": 3, "InternetChargeType": "BANDWIDTH_POSTPAID_BY_HOUR"})
        self.assertEqual(self.calls(), [])
        self.config_file.write_text(json.dumps(self.config))
        default = self.create("--plan", "--public-ip")
        self.assert_ok(default)
        self.assertEqual(json.loads(default.stdout)["InternetAccessible"], {
            "PublicIpAssigned": True, "InternetMaxBandwidthOut": 5, "InternetChargeType": "TRAFFIC_POSTPAID_BY_HOUR"})

    def test_unsupported_network_modes_and_billing_pairs_are_rejected_offline(self):
        cases = [("--internet-charge-type", "BANDWIDTH_POSTPAID_BY_HOUR"),
                 ("--public-ip", "--internet-charge-type", "BANDWIDTH_PACKAGE"),
                 ("--public-ip", "--internet-charge-type", "NONE"),
                 ("--public-ip", "--internet-charge-type", "BANDWIDTH_PREPAID"),
                 ("--charge-type", "PREPAID", "--period", "1", "--public-ip", "--internet-charge-type", "BANDWIDTH_POSTPAID_BY_HOUR")]
        for args in cases:
            with self.subTest(args=args):
                result = self.create("--yes", *args)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.calls(), [])
        for charge, network in (("POSTPAID_BY_HOUR", "BANDWIDTH_PREPAID"),
                                ("PREPAID", "BANDWIDTH_POSTPAID_BY_HOUR"),
                                ("POSTPAID_BY_HOUR", "BANDWIDTH_PACKAGE")):
            config = {**self.config, "InstanceChargeType": charge, "InternetAccessible": {
                "PublicIpAssigned": True, "InternetMaxBandwidthOut": 2, "InternetChargeType": network}}
            if charge == "PREPAID": config["InstanceChargePrepaid"] = {"Period": 1}
            self.config_file.write_text(json.dumps(config))
            result = self.create("--yes")
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(self.calls(), [])

    def test_prepaid_fixed_bandwidth_plan_includes_full_cost_and_cannot_be_overridden(self):
        path = self.directory / "public-plan.json"
        prepared = self.create("--prepare", str(path), "--charge-type", "PREPAID", "--period", "2",
                               "--public-ip", "--bandwidth", "2", "--internet-charge-type", "BANDWIDTH_PREPAID",
                               "--budget", "120", "--currency", "CNY")
        self.assert_ok(prepared)
        plan = json.loads(prepared.stdout)
        self.assertEqual(plan["cost_estimate"]["EstimatedTotal"], 238)
        self.assertEqual(plan["cost_estimate"]["MonthlyAverage"], 119)
        self.assertEqual(plan["cost_estimate"]["Budget"]["Status"], "WithinEstimate")
        self.assertEqual(plan["request"]["InstanceChargePrepaid"], {"Period": 2, "RenewFlag": "NOTIFY_AND_MANUAL_RENEW"})
        self.log.unlink()
        for args in (("--internet-charge-type", "TRAFFIC_POSTPAID_BY_HOUR"), ("--bandwidth", "10"),
                     ("--charge-type", "POSTPAID_BY_HOUR"), ("--period", "12"), ("--public-ip",)):
            with self.subTest(args=args):
                changed = self.run_script("create-instance.sh", "--from-plan", str(path), *args, "--yes")
                self.assertNotEqual(changed.returncode, 0)
                self.assertEqual(self.calls(), [])
        submitted = self.run_script("create-instance.sh", "--from-plan", str(path), "--yes")
        self.assert_ok(submitted)
        self.assertEqual(self.calls()[-1]["request"], plan["request"])

    def test_public_traffic_missing_usage_cannot_purchase_with_budget(self):
        result = self.create("--yes", "--public-ip", "--hours", "1", "--currency", "CNY", "--budget", "100")
        self.assertNotEqual(result.returncode, 0)
        runs = [call for call in self.calls() if call["args"][1] == "RunInstances"]
        self.assertTrue(runs)
        self.assertTrue(all(call["request"].get("DryRun") for call in runs))
        self.assertIn("用量不足", result.stderr)

    def test_hourly_fixed_bandwidth_purchase_keeps_the_quoted_network(self):
        result = self.create("--yes", "--public-ip", "--internet-charge-type", "BANDWIDTH_POSTPAID_BY_HOUR",
                             "--hours", "1", "--currency", "CNY", "--budget", "2")
        self.assert_ok(result)
        quoted, dryrun, purchased = [call["request"] for call in self.calls()]
        self.assertEqual(quoted, purchased)
        self.assertEqual(dryrun, {**quoted, "DryRun": True})
        self.assertEqual(purchased["InternetAccessible"]["InternetChargeType"], "BANDWIDTH_POSTPAID_BY_HOUR")
        self.assertEqual(purchased["InstanceChargeType"], "POSTPAID_BY_HOUR")

    def test_unknown_config_and_conflicting_login_rejected_without_api(self):
        for extra in ({"DryRun": False}, {"LoginSettings": {"KeyIds": ["skey-test"], "Password": "fake"}}):
            self.config_file.write_text(json.dumps({**self.config, **extra}))
            result = self.create("--plan")
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(self.calls(), [])

    def test_mutation_without_approval_does_not_call_api(self):
        for script in ("start-instance.sh", "stop-instance.sh", "reboot-instance.sh", "terminate-instance.sh", "reset-instance.sh"):
            with self.subTest(script=script):
                result = self.run_script(script, "--instance-id", "ins-test", stdin="n\n")
                self.assert_ok(result)
                self.assertEqual(self.calls(), [])

    def test_stop_defaults_to_soft_and_explicit_force_keeps_confirmation_semantics(self):
        for extra, expected in (([], "SOFT"), (["--force", "--stopped-mode", "STOP_CHARGING"], "HARD")):
            result = self.run_script("stop-instance.sh", "--instance-id", "ins-test", "--yes", *extra)
            self.assert_ok(result)
            args = self.calls()[-1]["args"]
            self.assertEqual(args[args.index("--StopType") + 1], expected)
            self.assertEqual(json.loads(args[args.index("--InstanceIds") + 1]), ["ins-test"])

    def test_image_name_is_literal_and_force_option_survives_dry_run(self):
        marker = self.directory / "injected"
        name = f'backup"; touch {marker}; echo "'
        result = self.run_script("create-image.sh", "--instance-id", "ins-test", "--image-name", name, "--force-poweroff", "--dry-run")
        self.assert_ok(result)
        args = self.calls()[0]["args"]
        self.assertEqual(args[args.index("--ImageName") + 1], name)
        self.assertEqual(args[args.index("--ForcePoweroff") + 1], "true")
        self.assertFalse(marker.exists())

    def test_reset_password_uses_protected_json_file(self):
        password = "Offline-only-test-Password1!"
        password_file = self.directory / "password-input"
        password_file.write_text(password)
        result = self.run_script("reset-instance.sh", "--instance-id", "ins-test", "--password-file", str(password_file), "--yes")
        self.assert_ok(result)
        call = self.calls()[0]
        self.assertTrue(call["has_password"])
        self.assertEqual(call["mode"], 0o600)
        self.assertNotIn(password, result.stdout + result.stderr + self.log.read_text())
        self.assertFalse(Path(call["request_path"]).exists())

    def test_wait_rejects_stale_completion_and_reports_current_failure(self):
        # Fake sleep keeps the two-poll success test fast, while the operation
        # response changes based on the fake API call count.
        sleep = self.bin / "sleep"
        sleep.write_text("#!/bin/sh\nexit 0\n")
        sleep.chmod(0o755)
        result = self.run_script("wait-instance.sh", "--instance-id", "ins-test", "--request-id", "request-new", TEST_MODE="stale")
        self.assert_ok(result)
        self.assertEqual(len(self.calls()), 2)
        self.log.unlink()
        result = self.run_script("wait-instance.sh", "--instance-id", "ins-test", "--request-id", "request-new", TEST_MODE="operation-failed")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.calls()), 1)

    def test_purchase_wait_accepts_new_instance_without_operation_metadata(self):
        missing = {"LatestOperation": None, "LatestOperationState": None, "LatestOperationRequestId": None}
        for metadata in ({}, missing):
            with self.subTest(metadata=metadata):
                self.log.unlink(missing_ok=True)
                instance = {"InstanceId": "ins-test", "InstanceState": "RUNNING", **metadata}
                result = self.create("--yes", "--wait", "--timeout", "1", TEST_INSTANCE=json.dumps(instance))
                self.assert_ok(result)
                self.assertEqual(json.loads(result.stdout)["Instance"], instance)
                purchases = [call for call in self.calls() if call["args"][1] == "RunInstances" and not call["request"].get("DryRun")]
                self.assertEqual(len(purchases), 1)
                self.assertEqual(sum(call["args"][1] == "DescribeInstances" for call in self.calls()), 1)

    def test_creation_wait_rejects_partial_or_stale_operation_metadata(self):
        cases = [
            {"LatestOperation": "RunInstances"},
            {"LatestOperationState": "SUCCESS"},
            {"LatestOperationRequestId": "request-new"},
            {"LatestOperation": "RebootInstances", "LatestOperationState": "SUCCESS", "LatestOperationRequestId": "request-old"},
            {"LatestOperation": "", "LatestOperationState": "", "LatestOperationRequestId": ""},
        ]
        for metadata in cases:
            with self.subTest(metadata=metadata):
                self.log.unlink(missing_ok=True)
                instance = {"InstanceId": "ins-test", "InstanceState": "RUNNING", **metadata}
                result = self.run_script("wait-instance.sh", "--instance-id", "ins-test", "--request-id", "request-new",
                                         "--created-instance", "--timeout", "1", TEST_INSTANCE=json.dumps(instance))
                self.assertEqual(result.returncode, 124, result.stdout + result.stderr)
                self.assertTrue(all(call["args"][1] == "DescribeInstances" for call in self.calls()))

    def test_existing_lifecycle_wait_stays_strict_without_operation_metadata(self):
        for script, state, action in (("reboot-instance.sh", "RUNNING", "RebootInstances"),
                                      ("stop-instance.sh", "STOPPED", "StopInstances")):
            with self.subTest(script=script):
                self.log.unlink(missing_ok=True)
                instance = {"InstanceId": "ins-test", "InstanceState": state, "LatestOperation": None,
                            "LatestOperationState": None, "LatestOperationRequestId": None}
                result = self.run_script(script, "--instance-id", "ins-test", "--yes", "--wait", "--timeout", "1",
                                         TEST_INSTANCE=json.dumps(instance))
                self.assertEqual(result.returncode, 124, result.stdout + result.stderr)
                self.assertEqual(sum(call["args"][1] == action for call in self.calls()), 1)

    def test_creation_wait_requires_request_and_running_target_before_api(self):
        for args in ((), ("--request-id", "request-new", "--state", "STOPPED"),
                     ("--request-id", "request-new", "--state", "ABSENT")):
            with self.subTest(args=args):
                result = self.run_script("wait-instance.sh", "--instance-id", "ins-test", "--created-instance", *args)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertEqual(self.calls(), [])

    def test_creation_wait_preserves_instance_identity_and_launch_state_checks(self):
        for instance_id, state, code in (("ins-other", "RUNNING", 124), ("ins-test", "PENDING", 124),
                                        ("ins-test", "LAUNCH_FAILED", 1)):
            with self.subTest(instance_id=instance_id, state=state):
                instance = {"InstanceId": instance_id, "InstanceState": state}
                result = self.run_script("wait-instance.sh", "--instance-id", "ins-test", "--request-id", "request-new",
                                         "--created-instance", "--timeout", "1", TEST_INSTANCE=json.dumps(instance))
                self.assertEqual(result.returncode, code, result.stdout + result.stderr)

    def test_terminate_submission_retains_local_record(self):
        original = '{"ins-test":{"host":"203.0.113.7"}}'
        self.passwords.write_text(original)
        result = self.run_script("terminate-instance.sh", "--instance-id", "ins-test", "--yes")
        self.assert_ok(result)
        self.assertEqual(self.passwords.read_text(), original)

    def test_prepared_plan_can_be_submitted_once_without_reentering_configuration(self):
        plan_path = self.directory / "approved-plan.json"
        prepared = self.create("--prepare", str(plan_path), "--key-id", "skey-test")
        self.assert_ok(prepared)
        plan = json.loads(prepared.stdout)
        self.assertEqual(plan["schema_version"], 2)
        self.assertEqual(plan["profile"], "test-account")
        self.assertEqual(plan["client_token"], "fixed-test-token")
        self.assertEqual(stat.S_IMODE(plan_path.stat().st_mode), 0o600)
        self.assertEqual([x["args"][1] for x in self.calls()], ["InquiryPriceRunInstances", "RunInstances"])
        self.assertTrue(self.calls()[-1]["request"]["DryRun"])
        self.log.unlink()
        submitted = self.run_script("create-instance.sh", "--from-plan", str(plan_path), "--yes", "--wait")
        self.assert_ok(submitted)
        result = json.loads(submitted.stdout)
        self.assertEqual(result["ClientToken"], "fixed-test-token")
        self.assertEqual(result["Instance"]["InstanceState"], "RUNNING")
        self.assertEqual([x["args"][1] for x in self.calls()], ["InquiryPriceRunInstances", "RunInstances", "RunInstances", "DescribeInstances"])
        self.assertEqual(self.calls()[2]["request"], plan["request"])

    def test_plan_price_increase_blocks_purchase_but_lower_quote_is_accepted(self):
        plan_path = self.directory / "approved-plan.json"
        self.assert_ok(self.create("--prepare", str(plan_path)))
        self.log.unlink()
        raised = self.run_script("create-instance.sh", "--from-plan", str(plan_path), "--yes", TEST_MODE="price-up")
        self.assertNotEqual(raised.returncode, 0)
        self.assertEqual([x["args"][1] for x in self.calls()], ["InquiryPriceRunInstances"])
        self.log.unlink()
        lower = self.run_script("create-instance.sh", "--from-plan", str(plan_path), "--yes", TEST_MODE="price-down")
        self.assert_ok(lower)
        self.assertEqual(self.calls()[-1]["args"][1], "RunInstances")
        self.assertNotIn("DryRun", self.calls()[-1]["request"])

    def test_plan_cannot_silently_switch_profile_or_configuration(self):
        plan_path = self.directory / "approved-plan.json"
        self.assert_ok(self.create("--prepare", str(plan_path)))
        self.log.unlink()
        wrong_account = self.run_script("create-instance.sh", "--from-plan", str(plan_path), "--yes", TENCENT_CVM_PROFILE="other-account")
        self.assertNotEqual(wrong_account.returncode, 0)
        self.assertEqual(self.calls(), [])
        override = self.run_script("create-instance.sh", "--from-plan", str(plan_path), "--disk-size", "100", "--yes")
        self.assertNotEqual(override.returncode, 0)
        self.assertEqual(self.calls(), [])
        plan = json.loads(plan_path.read_text())
        plan["request"]["ImageId"] = "img-other"
        plan_path.write_text(json.dumps(plan))
        edited = self.run_script("create-instance.sh", "--from-plan", str(plan_path), "--yes")
        self.assertNotEqual(edited.returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_prepared_plan_refuses_plaintext_password(self):
        result = self.create("--prepare", str(self.directory / "plan.json"), "--password-login")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_ambiguous_purchase_preserves_exact_secret_request_for_recovery(self):
        result = self.create("--yes", "--password-login", "--hours", "80", "--budget", "100", "--currency", "CNY", TEST_MODE="purchase-fail")
        self.assertNotEqual(result.returncode, 0)
        recoveries = list(self.directory.glob("cvm-create.*/recovery.json"))
        self.assertEqual(len(recoveries), 1)
        recovery = json.loads(recoveries[0].read_text())
        self.assertEqual(recovery["client_token"], "fixed-test-token")
        self.assertEqual(recovery["region"], "ap-guangzhou")
        self.assertEqual(recovery["estimate_options"]["budget"], "100")
        password = recovery["request"]["LoginSettings"]["Password"]
        self.assertTrue(password)
        self.assertNotIn(password, result.stdout + result.stderr + self.log.read_text())
        self.assertEqual(stat.S_IMODE(recoveries[0].stat().st_mode), 0o600)
        self.assertNotIn("--config", result.stderr)
        self.log.unlink()
        higher = self.run_script("create-instance.sh", "--resume", str(recoveries[0]), "--yes", TEST_MODE="price-slight-up")
        self.assertNotEqual(higher.returncode, 0)
        self.assertEqual([x["args"][1] for x in self.calls()], ["InquiryPriceRunInstances"])
        self.log.unlink()
        resumed = self.run_script("create-instance.sh", "--resume", str(recoveries[0]), "--yes", TEST_MODE="price-down")
        self.assert_ok(resumed)
        self.assertEqual(json.loads(self.passwords.read_text())["ins-test"]["password"], password)
        self.assertNotIn(password, resumed.stdout + resumed.stderr + self.log.read_text())

    def test_deferred_network_plan_locks_original_quote_before_network_exists(self):
        incomplete = {k: v for k, v in self.config.items() if k not in ("VirtualPrivateCloud", "SecurityGroupIds")}
        self.config_file.write_text(json.dumps(incomplete))
        path = self.directory / "pending-network.json"
        prepared = self.create("--prepare", str(path), "--defer-network", "--hours", "80", "--budget", "100", "--currency", "CNY")
        self.assert_ok(prepared)
        plan = json.loads(prepared.stdout)
        self.assertEqual(plan["state"], "pending_network")
        self.assertEqual(plan["pending_network"], ["VpcId", "SubnetId", "SecurityGroupIds"])
        self.assertIsNone(plan["preflight_request_id"])
        self.assertNotIn("VirtualPrivateCloud", plan["request"])
        self.assertNotIn("SecurityGroupIds", plan["request"])
        self.assertEqual([x["args"][1] for x in self.calls()], ["InquiryPriceRunInstances"])
        original = path.read_text()
        self.log.unlink()
        missing = self.run_script("create-instance.sh", "--from-plan", str(path), "--yes")
        self.assertNotEqual(missing.returncode, 0)
        self.assertEqual(self.calls(), [])
        bindings = ["--vpc-id", "vpc-new", "--subnet-id", "subnet-new", "--sg-id", "sg-new"]
        higher = self.run_script("create-instance.sh", "--from-plan", str(path), *bindings, "--yes", TEST_MODE="price-slight-up")
        self.assertNotEqual(higher.returncode, 0)  # 90 < 100 budget, but approved price was 80.
        self.assertEqual([x["args"][1] for x in self.calls()], ["InquiryPriceRunInstances"])
        self.log.unlink()
        lower = self.run_script("create-instance.sh", "--from-plan", str(path), *bindings, "--yes", "--wait", TEST_MODE="price-down")
        self.assert_ok(lower)
        self.assertEqual(json.loads(lower.stdout)["Instance"]["InstanceState"], "RUNNING")
        actual = self.calls()[2]["request"]
        self.assertEqual(actual["VirtualPrivateCloud"], {"VpcId": "vpc-new", "SubnetId": "subnet-new"})
        self.assertEqual(actual["SecurityGroupIds"], ["sg-new"])
        self.assertEqual({k: v for k, v in actual.items() if k not in ("VirtualPrivateCloud", "SecurityGroupIds")}, plan["request"])
        self.assertEqual(path.read_text(), original)

    def test_deferred_plan_cannot_replace_fixed_ids_and_recovery_keeps_binding(self):
        incomplete = {**self.config, "VirtualPrivateCloud": {"VpcId": "vpc-fixed"}, "SecurityGroupIds": []}
        self.config_file.write_text(json.dumps(incomplete))
        path = self.directory / "pending-network.json"
        self.assert_ok(self.create("--prepare", str(path), "--defer-network", "--hours", "80", "--budget", "100", "--currency", "CNY"))
        self.log.unlink()
        override = self.run_script("create-instance.sh", "--from-plan", str(path), "--vpc-id", "vpc-other", "--subnet-id", "subnet-new", "--sg-id", "sg-new", "--yes")
        self.assertNotEqual(override.returncode, 0)
        self.assertEqual(self.calls(), [])
        failed = self.run_script("create-instance.sh", "--from-plan", str(path), "--subnet-id", "subnet-new", "--sg-id", "sg-new", "--yes", TEST_MODE="purchase-fail")
        self.assertNotEqual(failed.returncode, 0)
        recovery_path, = self.directory.glob("cvm-create.*/recovery.json")
        recovery = json.loads(recovery_path.read_text())
        self.assertEqual(recovery["pending_network"], [])
        self.assertEqual(recovery["request"]["VirtualPrivateCloud"], {"VpcId": "vpc-fixed", "SubnetId": "subnet-new"})
        self.assertEqual(recovery["estimate_options"]["budget"], "100")
        self.log.unlink()
        resumed = self.run_script("create-instance.sh", "--resume", str(recovery_path), "--yes")
        self.assert_ok(resumed)
        self.assertEqual(self.calls()[-1]["request"], recovery["request"])

    def test_defer_network_is_only_an_explicit_preparation_mode(self):
        for args in (("--defer-network", "--yes"), ("--prepare", str(self.directory / "complete.json"), "--defer-network")):
            with self.subTest(args=args):
                result = self.create(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.calls(), [])

    def test_plan_integrity_covers_quote_budget_and_authentication_source(self):
        path = self.directory / "plan.json"
        self.assert_ok(self.create("--prepare", str(path), "--budget", "1000", "--currency", "CNY"))
        original = json.loads(path.read_text())
        self.log.unlink()
        for field in ("price", "estimate_options", "auth_source"):
            edited = json.loads(json.dumps(original))
            if field == "price": edited[field]["InstancePrice"]["UnitPrice"] = 50
            elif field == "estimate_options": edited[field].pop("budget")
            else: edited[field] = "environment"
            path.write_text(json.dumps(edited))
            result = self.run_script("create-instance.sh", "--from-plan", str(path), "--yes")
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(self.calls(), [])
        env_plan = self.directory / "env-plan.json"
        self.assert_ok(self.create("--prepare", str(env_plan), TENCENT_CVM_PROFILE="", TENCENTCLOUD_SECRET_ID="test-id", TENCENTCLOUD_SECRET_KEY="test-secret"))
        self.log.unlink()
        changed = self.run_script("create-instance.sh", "--from-plan", str(env_plan), "--yes", TENCENT_CVM_PROFILE="")
        self.assertNotEqual(changed.returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_unknown_nested_fields_are_rejected_before_sdk_can_drop_them(self):
        for extra in ({"Placement": {"Zone": "ap-guangzhou-3", "Typo": True}}, {"EnhancedService": {"AutomationService": {"Enabled": True, "Typo": True}}}, {"TagSpecification": [{"ResourceType": "instance", "Tags": [{"Key": "k", "Typo": "v"}]}]}, {"SystemDisk": {"DiskId": "disk-output-only", "DiskSize": 40}}):
            with self.subTest(extra=extra):
                self.config_file.write_text(json.dumps({**self.config, **extra}))
                result = self.create("--plan")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("未支持的字段", result.stderr)
                self.assertEqual(self.calls(), [])

    def test_recovery_with_broad_permissions_or_overrides_cannot_submit(self):
        self.assertNotEqual(self.create("--yes", TEST_MODE="purchase-fail").returncode, 0)
        recovery_path, = self.directory.glob("cvm-create.*/recovery.json")
        self.log.unlink()
        for override in (("--vpc-id", "vpc-other"), ("--budget", "1000000"), ("--password-login",)):
            result = self.run_script("create-instance.sh", "--resume", str(recovery_path), *override, "--yes")
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(self.calls(), [])
        recovery_path.chmod(0o644)
        exposed = self.run_script("create-instance.sh", "--resume", str(recovery_path), "--yes")
        self.assertNotEqual(exposed.returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_ambiguous_empty_submission_keeps_recovery(self):
        result = self.create("--yes", TEST_MODE="purchase-empty")
        self.assertNotEqual(result.returncode, 0)
        recovery_path, = self.directory.glob("cvm-create.*/recovery.json")
        self.assertIn(str(recovery_path), result.stderr)
        self.assertIn("缺少有效实例 ID", result.stderr)

    def test_purchase_wait_timeout_retains_instance_id_and_exit_status(self):
        result = self.create("--yes", "--wait", "--timeout", "1", TEST_MODE="wait-timeout")
        self.assertEqual(result.returncode, 124, result.stdout + result.stderr)
        output = json.loads(result.stdout)
        self.assertEqual(output["InstanceIdSet"], ["ins-test"])
        self.assertTrue(Path(output["RecoveryFile"]).exists())
        purchases = [call for call in self.calls() if call["args"][1] == "RunInstances" and not call["request"].get("DryRun")]
        self.assertEqual(len(purchases), 1)

    def test_wait_does_not_treat_malformed_response_as_resource_absent(self):
        result = self.run_script("wait-instance.sh", "--instance-id", "ins-test", "--state", "ABSENT", TEST_MODE="malformed")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.calls()), 1)

    def test_explicit_budget_blocks_unknown_or_excess_cost(self):
        exceeded = self.create("--yes", "--budget", "100", "--currency", "CNY")
        self.assertNotEqual(exceeded.returncode, 0)
        self.assertEqual([x["args"][1] for x in self.calls()], ["InquiryPriceRunInstances"])
        self.log.unlink()
        plan_path = self.directory / "unknown-budget-plan.json"
        prepared = self.create("--prepare", str(plan_path), "--budget", "1000")
        self.assert_ok(prepared)
        self.assertEqual(json.loads(prepared.stdout)["cost_estimate"]["Budget"]["Status"], "Unknown")
        self.log.unlink()
        submission = self.run_script("create-instance.sh", "--from-plan", str(plan_path), "--yes")
        self.assertNotEqual(submission.returncode, 0)
        self.assertTrue(all(x["request"].get("DryRun") for x in self.calls() if x["args"][1] == "RunInstances"))

    def test_reset_key_login_invalidates_saved_password_without_losing_host(self):
        self.passwords.write_text(json.dumps({"ins-test": {"password": "old-test-only", "host": "203.0.113.7", "region": "ap-guangzhou"}}))
        self.passwords.chmod(0o600)
        result = self.run_script("reset-instance.sh", "--instance-id", "ins-test", "--key-id", "skey-test", "--yes")
        self.assert_ok(result)
        record = json.loads(self.passwords.read_text())["ins-test"]
        self.assertNotIn("password", record)
        self.assertEqual(record["host"], "203.0.113.7")

    def test_recommendation_is_read_only_and_matches_images_per_type(self):
        result = self.run_script("recommend-instance.sh", "--scene", "blog-small", "--json")
        self.assert_ok(result)
        plans = json.loads(result.stdout)["Plans"]
        self.assertTrue(all(x["Available"] for x in plans))
        self.assertTrue(all(x["Config"]["InstanceType"] == "S6.LARGE8" for x in plans))
        self.assertTrue(all(not x["Config"]["InternetAccessible"]["PublicIpAssigned"] for x in plans))
        actions = [x["args"][1] for x in self.calls()]
        self.assertNotIn("RunInstances", actions)
        self.assertNotIn("DescribeVpcs", actions)
        self.assertNotIn("DescribeSecurityGroups", actions)
        self.assertEqual(actions.count("DescribeImages"), 3)


if __name__ == "__main__":
    unittest.main()
