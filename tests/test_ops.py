"""Offline SSH/SCP and diagnostic grammar regressions. Never connects to a host."""
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
OPS = ROOT / "scripts/ops"
spec = importlib.util.spec_from_file_location("diagnostic_commands", OPS / "validate-command.py")
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)

FAKE_TOOL = r'''
import json
import os
from pathlib import Path
import subprocess
import sys

tool = Path(sys.argv[0]).name
args = sys.argv[1:]
entry = {"tool": tool, "args": args}
if tool == "sshpass":
    assert args[:2] == ["-d", "3"], "password must use a descriptor"
    entry["has_password_fd"] = bool(os.read(3, 4096).strip())
elif tool == "ssh":
    entry["stdin"] = sys.stdin.read()
with open(os.environ["OPS_TEST_LOG"], "a", encoding="utf-8") as stream:
    stream.write(json.dumps(entry) + "\n")
if tool == "sshpass":
    raise SystemExit(subprocess.run(args[2:]).returncode)
if tool == "tccli":
    print(json.dumps({"InstanceSet": [{"PublicIpAddresses": ["203.0.113.10"], "PrivateIpAddresses": ["10.0.0.10"]}]}))
raise SystemExit(int(os.environ.get("OPS_TEST_EXIT", "0")))
'''


class DiagnosticGrammarTests(unittest.TestCase):
    def test_read_only_variants_are_canonicalized(self):
        accepted = [
            "df -h", "fdisk -l", "ip addr show", "date -u", "hostname -I",
            "systemctl status nginx", "service nginx status", "journalctl -u nginx -n 100",
            "ping -c 4 example.com", "curl -I https://example.com", "tail -n 100 /var/log/syslog",
            'du -sh "/tmp/user\'s data"',
        ]
        for command in accepted:
            with self.subTest(command=command):
                args = validator.validate(command)
                rendered = " ".join(shlex.quote(arg) for arg in args)
                self.assertEqual(shlex.split(rendered), args)
        self.assertIn("--no-pager", validator.validate("systemctl status nginx"))
        self.assertIn("--max-time", validator.validate("curl -I https://example.com"))

    def test_shell_and_writable_prefix_bypasses_are_rejected(self):
        rejected = [
            "env sh -c id", "printenv", "hostname new-host", "date -s 2020-01-01",
            "timedatectl set-time 2020-01-01", "ip addr add 10.0.0.1/24 dev eth0",
            "service nginx stop", "journalctl --rotate", "journalctl -u nginx --vacuum-time=1d",
            "systemctl status nginx;reboot", "free -h\nreboot", "uptime$(reboot)",
            "df -h>/tmp/result", "curl -s https://example.com", "curl -I file:///etc/passwd",
            "curl -I https://user:password@example.com", "tail -n 100 /etc/shadow",
            "tail -n 100 /var/log/../../etc/shadow", "ping -c 100000 example.com",
            "nginx -T", "docker ps --config /tmp/arbitrary", "journalctl -u nginx -n -1",
        ]
        for command in rejected:
            with self.subTest(command=command):
                with self.assertRaises(ValueError):
                    validator.validate(command)


class SSHOperationsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cvm-ops-test-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.bin = self.work / "bin"
        self.bin.mkdir()
        for tool in ("bash", "dirname", "cat", "python3", "jq"):
            path = shutil.which(tool)
            if path:
                (self.bin / tool).symlink_to(path)
        for tool in ("ssh", "scp", "sshpass", "tccli"):
            target = self.bin / tool
            target.write_text(f"#!{sys.executable}\n" + FAKE_TOOL)
            target.chmod(0o755)
        self.log = self.work / "calls.jsonl"
        self.store = self.work / "connections.json"
        self.env = {key: os.environ[key] for key in ("TMPDIR", "LANG") if key in os.environ}
        self.env.update({"HOME": str(self.work), "PATH": str(self.bin), "OPS_TEST_LOG": str(self.log), "TENCENT_CVM_PASSWORD_FILE": str(self.store)})

    def run_script(self, name, *args, extra_env=None):
        env = {**self.env, **(extra_env or {})}
        return subprocess.run(["/bin/bash", str(OPS / f"{name}.sh"), *args], env=env,
                              input="", text=True, capture_output=True, timeout=10)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_help_is_offline_for_every_entrypoint(self):
        for entry in OPS.glob("*.sh"):
            if entry.name == "transport.sh":
                continue
            with self.subTest(entry=entry.name):
                result = self.run_script(entry.stem, "--help")
                self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [])

    def test_agent_auth_does_not_need_password_or_sshpass(self):
        (self.bin / "sshpass").unlink()
        result = self.run_script("remote-exec", "--host", "203.0.113.10", "--cmd", "df -h")
        self.assertEqual(result.returncode, 0, result.stderr)
        call, = self.calls()
        self.assertEqual(call["tool"], "ssh")
        self.assertIn("BatchMode=yes", call["args"])
        self.assertIn("StrictHostKeyChecking=yes", call["args"])
        self.assertNotIn("UserKnownHostsFile=/dev/null", call["args"])
        self.assertEqual(call["args"][-1], "df -h")

    def test_identity_and_explicit_accept_new_are_forwarded(self):
        identity = self.work / "id test"
        identity.write_text("dummy-not-a-real-key")
        result = self.run_script("remote-exec", "--host", "server.example", "--user", "ubuntu", "--port", "2222",
                                 "--identity", str(identity), "--accept-new-host-key", "--cmd", "uptime")
        self.assertEqual(result.returncode, 0, result.stderr)
        args = self.calls()[0]["args"]
        self.assertIn("StrictHostKeyChecking=accept-new", args)
        self.assertEqual(args[args.index("-i") + 1], str(identity))
        self.assertEqual(args[args.index("-p") + 1], "2222")
        self.assertIn("ubuntu@server.example", args)

    def test_password_is_sent_by_fd_not_process_arguments(self):
        password_file = self.work / "password"
        password_file.write_text("dummy-private-value\n")
        password_file.chmod(0o600)
        result = self.run_script("remote-exec", "--host", "203.0.113.10", "--password-file", str(password_file), "--cmd", "uptime")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        self.assertEqual([call["tool"] for call in calls], ["sshpass", "ssh"])
        self.assertTrue(calls[0]["has_password_fd"])
        self.assertNotIn("dummy-private-value", self.log.read_text() + result.stdout + result.stderr)
        self.assertNotIn("-p", calls[0]["args"][:2])

    def test_public_password_file_is_rejected_before_connection(self):
        password_file = self.work / "password"
        password_file.write_text("dummy")
        password_file.chmod(0o644)
        result = self.run_script("ssh-connect", "--host", "203.0.113.10", "--password-file", str(password_file))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_remote_failure_is_propagated_without_success_message_or_retry(self):
        for name, arguments in [
            ("remote-exec", ["--cmd", "uptime"]),
            ("system-info", []),
            ("service-manage", ["--service", "nginx", "--action", "restart", "--yes"]),
        ]:
            with self.subTest(name=name):
                self.log.unlink(missing_ok=True)
                result = self.run_script(name, "--host", "server.example", *arguments, extra_env={"OPS_TEST_EXIT": "17"})
                self.assertEqual(result.returncode, 17, result.stderr)
                self.assertNotIn("完成", result.stdout + result.stderr)
                self.assertEqual(len(self.calls()), 1)

    def test_mutations_need_confirmation_but_status_does_not(self):
        result = self.run_script("service-manage", "--host", "server.example", "--service", "nginx", "--action", "restart")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])
        result = self.run_script("service-manage", "--host", "server.example", "--service", "nginx")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(shlex.split(self.calls()[0]["args"][-1]), ["systemctl", "--no-pager", "status", "--", "nginx"])

    def test_injection_is_rejected_before_any_connection(self):
        variants = [
            ("service-manage", ["--service", "nginx;reboot", "--yes"]),
            ("network-check", ["--target", "$(touch /tmp/marker)"]),
            ("remote-exec", ["--cmd", "env sh -c id"]),
            ("remote-exec", ["--cmd", "df -h", "--host", "-oProxyCommand=sh"]),
            ("process-monitor", ["--top", "10;reboot"]),
            ("file-transfer", ["--download", "--remote", "/tmp/a;reboot", "--local", str(self.work), "--yes"]),
        ]
        for name, args in variants:
            with self.subTest(name=name, args=args):
                result = self.run_script(name, "--host", "server.example", *args)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.calls(), [])

    def test_log_filter_is_a_literal_remote_argument(self):
        value = "' ; touch /tmp/not-executed ; $(id)"
        result = self.run_script("log-viewer", "--host", "server.example", "--file", "/var/log/app log", "--filter", value)
        self.assertEqual(result.returncode, 0, result.stderr)
        call = self.calls()[0]
        self.assertEqual(shlex.split(call["args"][-1]), ["bash", "-s", "--", "/var/log/app log", "100", value, "false"])
        self.assertNotIn(value, call["stdin"])
        self.assertIn('grep --line-buffered -Fi -- "$filter"', call["stdin"])

    def test_download_confirmation_and_scp_failure(self):
        args = ["--host", "server.example", "--download", "--remote", "/var/log/app.log", "--local", str(self.work)]
        result = self.run_script("file-transfer", *args)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])
        result = self.run_script("file-transfer", *args, "--yes", extra_env={"OPS_TEST_EXIT": "21"})
        self.assertEqual(result.returncode, 21)
        self.assertNotIn("传输完成", result.stdout + result.stderr)
        self.assertEqual(self.calls()[0]["tool"], "scp")

    def test_instance_without_local_record_resolves_selected_private_address(self):
        result = self.run_script("remote-exec", "--instance-id", "ins-test", "--region", "ap-singapore", "--address", "private", "--cmd", "uptime")
        self.assertEqual(result.returncode, 0, result.stderr)
        api, ssh = self.calls()
        self.assertEqual(api["args"][:2], ["cvm", "DescribeInstances"])
        self.assertEqual(api["args"][api["args"].index("--region") + 1], "ap-singapore")
        self.assertIn("root@10.0.0.10", ssh["args"])


if __name__ == "__main__":
    unittest.main()
