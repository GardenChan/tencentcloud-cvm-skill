#!/usr/bin/env python3
"""Offline authentication regressions; no real tccli or cloud account is used.

Run: python3 -m unittest discover -s tests -v
"""

import json
import errno
import fcntl
import importlib.util
import os
from pathlib import Path
import pty
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
COMMON = ROOT / "scripts/common.sh"

FAKE_TCCLI = r'''
import json
import os
import sys

args = sys.argv[1:]
logged = list(args)
request = {}
if "--cli-input-json" in args:
    source = args[args.index("--cli-input-json") + 1]
    if source.startswith("file://"):
        with open(source[7:], encoding="utf-8") as stream:
            request = json.load(stream)
    else:
        request = json.loads(source)
    # Retain the semantic marker for assertions, without any request secrets.
    if request.get("DryRun"):
        logged += ["TEST_REQUEST_DRY_RUN", "true"]
for sensitive in ("--LoginSettings", "--secretId", "--secretKey", "--token"):
    if sensitive in logged:
        logged[logged.index(sensitive) + 1] = "<redacted test value>"
with open(os.environ["TEST_TCCLI_LOG"], "a", encoding="utf-8") as stream:
    stream.write(json.dumps(logged) + "\n")

if "help" in args or "--help" in args:
    print("auth login --profile NAME --browser no")
    raise SystemExit(0)
if args[:2] == ["auth", "login"]:
    if os.environ.get("TEST_LOGIN_STATE"):
        import termios
        with open(os.environ["TEST_LOGIN_STATE"], "w") as stream:
            json.dump({"pid": os.getpid(), "echo": bool(termios.tcgetattr(0)[3] & termios.ECHO)}, stream)
    if os.environ.get("TEST_LOGIN_SLEEP"):
        import time
        time.sleep(30)
    if os.environ.get("TEST_LOGIN_FAIL"):
        print("login cancelled", file=sys.stderr)
        raise SystemExit(23)
    print("Login completed (simulated)")
    raise SystemExit(0)

mode = os.environ.get("TEST_TCCLI_MODE", "success")
if mode == "failure":
    print("AuthFailure.TokenFailure: expired simulated credential", file=sys.stderr)
    raise SystemExit(37)
if mode == "raw_failure":
    print("raw stdout diagnostic")
    print("raw stderr diagnostic", file=sys.stderr)
    raise SystemExit(37)
if mode == "error_json":
    print(json.dumps({"Error": {"Code": "AuthFailure.TokenFailure", "Message": "expired"}}))
    raise SystemExit(0)
if mode == "nested_error":
    print(json.dumps({"Response": {"Error": {"Code": "UnauthorizedOperation", "Message": "denied"}}}))
    raise SystemExit(0)
if mode == "not_json":
    print("refresh failed; this is not an API response")
    raise SystemExit(0)
if mode == "warning":
    print("simulated credential refresh notice", file=sys.stderr)

action = args[1]
responses = {
    "DescribeRegions": {"TotalCount": 1, "RegionSet": [{"Region": "ap-guangzhou", "RegionName": "Guangzhou", "RegionState": "AVAILABLE"}]},
    "DescribeInstances": {"TotalCount": 0, "InstanceSet": []},
    "InquiryPriceRunInstances": {"Price": {"InstancePrice": {"UnitPrice": 1.0, "UnitPriceDiscount": 0.8, "ChargeUnit": "HOUR"}}},
}
if action == "RunInstances":
    if "--DryRun" in args or request.get("DryRun"):
        print(json.dumps({"RequestId": "offline-dry-run"}))
        raise SystemExit(0)
    print(json.dumps({"InstanceIdSet": ["ins-offline-test"]}))
else:
    print(json.dumps(responses.get(action, {"RequestId": "offline-test"})))
'''


class AuthenticationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cvm-auth-test-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        self.log = self.directory / "calls.jsonl"
        fake = self.bin / "tccli"
        fake.write_text(f"#!{sys.executable}\n" + FAKE_TCCLI, encoding="utf-8")
        fake.chmod(0o755)
        for name, executable in (("python3", sys.executable), ("jq", shutil.which("jq"))):
            if not executable:
                self.skipTest(f"{name} is required to run offline script tests")
            (self.bin / name).symlink_to(executable)

        self.home = self.directory / "home"
        self.home.mkdir()
        # Isolate configuration locks and all native state. Only fake tccli is
        # reachable; no inherited cloud variables reach child processes.
        self.env = {
            "HOME": str(self.home),
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "LANG": "en_US.UTF-8",
            "TEST_TCCLI_LOG": str(self.log),
            "TENCENT_CVM_PASSWORD_FILE": str(self.directory / "passwords.json"),
        }

    def shell(self, code, **environment):
        return subprocess.run(
            ["/bin/bash", "-c", 'source "$1"\n' + code, "auth-test", str(COMMON)],
            cwd=ROOT,
            env={**self.env, **environment},
            text=True,
            capture_output=True,
            timeout=15,
        )

    def script(self, path, *arguments, stdin=None, tty=False, **environment):
        if tty:
            master, slave = pty.openpty()
            try:
                process = subprocess.Popen(
                    ["/bin/bash", str(ROOT / path), *arguments],
                    cwd=ROOT,
                    env={**self.env, **environment},
                    stdin=slave,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                try:
                    stdout, stderr = process.communicate(timeout=20)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.communicate()
                    raise
                return subprocess.CompletedProcess(process.args, process.returncode, stdout, stderr)
            finally:
                os.close(master)
                os.close(slave)
        return subprocess.run(
            ["/bin/bash", str(ROOT / path), *arguments],
            cwd=ROOT,
            env={**self.env, **environment},
            input=stdin,
            text=True,
            capture_output=True,
            timeout=20,
        )

    def calls(self):
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def assert_profile(self, call, name):
        self.assertEqual(call.count("--profile"), 1, call)
        self.assertEqual(call[call.index("--profile") + 1], name, call)

    def test_prerequisites_do_not_require_secret_environment_or_call_api(self):
        result = self.shell("set -u\ncheck_api_prerequisites")
        self.assert_success(result)
        self.assertEqual(self.calls(), [])

    def test_profile_precedence(self):
        for values, expected in (
            ({}, "default"),
            ({"TCCLI_PROFILE": "native"}, "native"),
            ({"TCCLI_PROFILE": "native", "TENCENT_CVM_PROFILE": "cvm"}, "cvm"),
        ):
            with self.subTest(expected=expected):
                result = self.shell("set -u\ntccli_profile", **values)
                self.assert_success(result)
                self.assertEqual(result.stdout.strip(), expected)

    def test_api_passes_profile_and_json_output(self):
        result = self.shell(
            "set -eu\nexecute_tccli cvm DescribeRegions",
            TENCENT_CVM_PROFILE="project-account",
        )
        self.assert_success(result)
        self.assertEqual(json.loads(result.stdout)["TotalCount"], 1)
        self.assertEqual(len(self.calls()), 1)
        call = self.calls()[0]
        self.assert_profile(call, "project-account")
        self.assertEqual(call[call.index("--output") + 1], "json")

    def test_environment_credentials_are_not_disabled_by_default_profile(self):
        result = self.shell("execute_tccli cvm DescribeRegions",
                            TENCENTCLOUD_SECRET_ID="fixture-id", TENCENTCLOUD_SECRET_KEY="fixture-key")
        self.assert_success(result)
        self.assertNotIn("--profile", self.calls()[0])
        self.log.unlink()
        result = self.shell("execute_tccli cvm DescribeRegions", TENCENT_CVM_PROFILE="work",
                            TENCENTCLOUD_SECRET_ID="fixture-id", TENCENTCLOUD_SECRET_KEY="fixture-key")
        self.assert_success(result)
        self.assert_profile(self.calls()[0], "work")

    def test_stderr_notice_does_not_pollute_json(self):
        result = self.shell("execute_tccli cvm DescribeRegions", TEST_TCCLI_MODE="warning")
        self.assert_success(result)
        self.assertEqual(json.loads(result.stdout)["TotalCount"], 1)
        self.assertIn("simulated credential refresh notice", result.stderr)

    def test_raw_wrapper_preserves_failure_status_and_streams(self):
        result = self.shell("run_tccli cvm DescribeRegions", TEST_TCCLI_MODE="raw_failure")
        self.assertEqual(result.returncode, 37)
        self.assertEqual(result.stdout.strip(), "raw stdout diagnostic")
        self.assertIn("raw stderr diagnostic", result.stderr)

    def test_api_failures_are_rejected_without_retry_or_login(self):
        for mode in ("failure", "error_json", "nested_error", "not_json"):
            with self.subTest(mode=mode):
                self.log.unlink(missing_ok=True)
                result = self.shell("set -eu\nexecute_tccli cvm DescribeRegions", TEST_TCCLI_MODE=mode)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(len(self.calls()), 1)
                self.assertEqual(self.calls()[0][:2], ["cvm", "DescribeRegions"])

    def test_query_does_not_report_success_after_auth_failure(self):
        result = self.script("scripts/query/describe-instances.sh", TEST_TCCLI_MODE="failure")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("查询完成", result.stdout)
        self.assertNotIn("[OK]", result.stdout)

    def test_check_uses_selected_profile_and_region(self):
        result = self.script(
            "scripts/auth/check.sh", "--profile", "check-account", "--region", "ap-shanghai"
        )
        self.assert_success(result)
        self.assertEqual(len(self.calls()), 1)
        call = self.calls()[0]
        self.assertEqual(call[:2], ["cvm", "DescribeRegions"])
        self.assert_profile(call, "check-account")
        self.assertEqual(call[call.index("--region") + 1], "ap-shanghai")
        self.assertIn("check-account", result.stdout + result.stderr)

    def test_invalid_login_timeout_does_not_start_cli(self):
        for value in ("0", "3601", "-1", "abc"):
            result = self.script("scripts/auth/login.sh", "--timeout", value)
            self.assertEqual(result.returncode, 2)
        self.assertEqual(self.calls(), [])

    def test_help_does_not_require_cloud_dependencies(self):
        offline_bin = self.directory / "offline-bin"
        offline_bin.mkdir()
        for name in ("dirname", "basename", "cat"):
            (offline_bin / name).symlink_to(shutil.which(name))
        for path in (
            "scripts/auth/login.sh",
            "scripts/auth/check.sh",
            "scripts/query/describe-instances.sh",
            "scripts/lifecycle/create-instance.sh",
            "scripts/lifecycle/recommend-instance.sh",
        ):
            with self.subTest(path=path):
                result = self.script(path, "--help", PATH=str(offline_bin))
                self.assert_success(result)
        result = self.script("scripts/lifecycle/recommend-instance.sh", "--list-scenes", PATH=str(offline_bin))
        self.assert_success(result)
        self.assertEqual(self.calls(), [])

    def test_creation_uses_one_profile_for_price_dry_run_and_purchase(self):
        result = self.script(
            "scripts/lifecycle/create-instance.sh",
            "--zone", "ap-guangzhou-3",
            "--instance-type", "S5.MEDIUM2",
            "--image-id", "img-offline",
            "--vpc-id", "vpc-offline",
            "--subnet-id", "subnet-offline",
            "--sg-id", "sg-offline",
            stdin="y\ny\ny\ny\n",
            TENCENT_CVM_PROFILE="purchase-account",
        )
        self.assert_success(result)
        calls = self.calls()
        self.assertEqual(
            [call[1] for call in calls],
            ["InquiryPriceRunInstances", "RunInstances", "RunInstances"],
        )
        self.assertIn("TEST_REQUEST_DRY_RUN", calls[1])
        self.assertNotIn("TEST_REQUEST_DRY_RUN", calls[2])
        for call in calls:
            self.assert_profile(call, "purchase-account")
            self.assertEqual(call[call.index("--output") + 1], "json")

    def test_recommendation_stops_after_auth_error(self):
        result = self.script(
            "scripts/lifecycle/recommend-instance.sh", "--scene", "blog-small",
            TEST_TCCLI_MODE="failure", TENCENT_CVM_PROFILE="recommend-account",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("¥0", result.stdout)
        self.assertNotIn("￥0", result.stdout)
        calls = self.calls()
        self.assertEqual(len(calls), 1, calls)
        self.assert_profile(calls[0], "recommend-account")

    def test_password_generation_without_shuf(self):
        result = self.shell("generate_password 20")
        self.assert_success(result)
        password = result.stdout.strip()
        self.assertEqual(len(password), 20)
        for pattern in (r"[A-Z]", r"[a-z]", r"[0-9]", r"[^A-Za-z0-9]"):
            self.assertRegex(password, pattern)


FAKE_NATIVE_LOGIN = r'''
import json, os, pathlib, queue, time, uuid
from types import SimpleNamespace
from urllib.parse import urlencode
from . import browser_flow

def forbidden_browser(*args, **kwargs):
    raise AssertionError("The native browser opener must be replaced")
webbrowser = SimpleNamespace(open=forbidden_browser)

def login(use_browser, profile, language):
    if os.environ.get('TEST_NATIVE_FAILURE'):
        raise RuntimeError('fixture exception must not enter public state')
    port, result = browser_flow.try_run(9000, 9100)
    state = uuid.uuid4().hex
    callback = os.environ.get('TEST_NATIVE_BAD_REDIRECT') or 'http://localhost:%d' % port
    redirect = 'https://cli.cloud.tencent.com/oauth?' + urlencode({'redirect_url': callback, 'lang':'zh-CN', 'site':'cn'})
    url = 'https://cloud.tencent.com/open/authorize?' + urlencode({'scope':'login','app_id':'100038427476','redirect_url':redirect,'state':state})
    if not webbrowser.open(url):
        raise RuntimeError('cannot open')
    token = result.get(timeout=30)
    if token['state'] != state:
        raise ValueError('invalid state')
    if os.environ.get('TEST_NATIVE_SAVE_DELAY'):
        if os.environ.get('TEST_NATIVE_IGNORE_TERM'):
            import signal
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
        pathlib.Path(os.environ['TEST_NATIVE_SAVE_MARKER']).write_text(str(os.getpid()))
        time.sleep(float(os.environ['TEST_NATIVE_SAVE_DELAY']))
    path = pathlib.Path.home()/'.tccli'/(profile+'.credential')
    path.write_text(json.dumps({'secretId':'fixture-secret','oauth':{'refreshToken':'fixture-refresh'}}))
'''
FAKE_NATIVE_TRANSPORT = r'''
from http.server import BaseHTTPRequestHandler
from socketserver import ThreadingTCPServer
from urllib.parse import parse_qs, urlsplit
import queue

class ThreadingHTTPServer(ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

class HTTPHandler(BaseHTTPRequestHandler):
    result_queue = queue.Queue(1)
    def do_GET(self):
        value = parse_qs(urlsplit(self.path).query)
        self.result_queue.put({'state':value['state'][0]})
        self.send_response(307)
        self.send_header('Location',value['redirect_url'][0])
        self.end_headers()
    def log_message(self,*args):
        pass

def try_run(start,end):
    raise AssertionError('The native wildcard transport must be replaced')
'''


class LinkAuthorizationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='cvm-link-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.states = self.root/'sessions'
        self.home = self.root/'home'
        self.home.mkdir()
        self.bin = self.root/'bin'
        self.bin.mkdir()
        self.log = self.root/'calls.jsonl'
        fake = self.bin/'tccli'
        fake.write_text(f'#!{sys.executable}\n'+FAKE_TCCLI)
        fake.chmod(0o755)
        for name, executable in (('python3',sys.executable),('jq',shutil.which('jq'))):
            (self.bin/name).symlink_to(executable)
        package = self.root/'modules/tccli/plugins/auth'
        package.mkdir(parents=True)
        for directory in (package,package.parent,package.parent.parent):
            (directory/'__init__.py').write_text('')
        (package/'login.py').write_text(FAKE_NATIVE_LOGIN)
        (package/'browser_flow.py').write_text(FAKE_NATIVE_TRANSPORT)
        self.env = {'PATH':f'{self.bin}:/usr/bin:/bin','HOME':str(self.home),
                    'PYTHONPATH':str(self.root/'modules'), 'PYTHONDONTWRITEBYTECODE':'1',
                    'TEST_TCCLI_LOG':str(self.log),'TENCENT_CVM_AUTH_STATE_DIR':str(self.states)}
        self.addCleanup(self.cleanup_sessions)

    def run_flow(self,*args,**env):
        result = subprocess.run(['/bin/bash',str(ROOT/'scripts/auth/login.sh'),*args],
                                env={**self.env,**env},text=True,capture_output=True,timeout=12)
        return result, json.loads(result.stdout)

    def cleanup_sessions(self):
        if self.states.exists():
            for path in self.states.iterdir():
                if path.is_dir():
                    self.run_flow('--cancel',path.name)

    def start(self,**env):
        result, data = self.run_flow('--execution-context','local','--profile','review',**env)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(data['status'],'awaiting_authorization')
        return data

    def poll(self,session_id,terminal=True):
        deadline=time.monotonic()+8
        while time.monotonic()<deadline:
            result,data=self.run_flow('--status',session_id)
            if not terminal or data['status'] not in ('starting','awaiting_authorization','verifying','stopping'):
                return result,data
            time.sleep(.05)
        self.fail('authorization status did not reach terminal state')

    def callback(self,session,bad_state=False,host='127.0.0.1'):
        import http.client
        from urllib.parse import parse_qs,urlsplit,urlencode
        query=parse_qs(urlsplit(session['auth_url']).query)
        inner=parse_qs(urlsplit(query['redirect_url'][0]).query)
        target=urlsplit(inner['redirect_url'][0])
        self.assertEqual(target.hostname,'localhost')
        self.assertNotEqual(target.port,9000)
        connection=http.client.HTTPConnection(host,target.port,timeout=2)
        body={'state':'old-session' if bad_state else query['state'][0],
              'redirect_url':'https://cli.cloud.tencent.com/oauth_success?lang=zh-CN',
              'access_token':'fixture-access','refresh_token':'fixture-refresh',
              'open_id':'fixture-open','site':'cn','expires_at':'9999999999'}
        connection.request('GET','/?'+urlencode(body))
        response=connection.getresponse()
        code=response.status
        response.read()
        connection.close()
        return code

    def test_start_is_link_only_and_reuses_pending_session(self):
        first=self.start()
        second=self.start()
        self.assertEqual(first['session_id'],second['session_id'])
        self.assertEqual(first['auth_url'],second['auth_url'])
        self.assertEqual(first['callback_scope'],'same_machine')
        self.assertFalse(self.log.exists())
        self.assertFalse((self.home/'.tccli/review.credential').exists())
        self.assertEqual((self.states/first['session_id']/'state.json').stat().st_mode&0o777,0o600)

    def test_native_callback_then_read_only_check_reaches_ready_without_secrets_in_state(self):
        session=self.start()
        self.assertEqual(self.callback(session),307)
        result,data=self.poll(session['session_id'])
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(data['status'],'ready')
        self.assertNotIn('auth_url',data)
        calls=[json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertEqual(len(calls),1)
        self.assertEqual(calls[0][:2],['cvm','DescribeRegions'])
        self.assertEqual(calls[0][calls[0].index('--profile')+1],'review')
        for path in self.states.rglob('*'):
            if path.is_file():
                text=path.read_text()
                for secret in ('fixture-secret','fixture-refresh','fixture-access','access_token=', 'refresh_token='):
                    self.assertNotIn(secret,text)
        self.assertEqual((self.home/'.tccli/review.credential').stat().st_mode&0o777,0o600)

    def test_old_callback_cannot_complete_current_session(self):
        session=self.start()
        self.assertEqual(self.callback(session,bad_state=True),400)
        _,data=self.poll(session['session_id'],terminal=False)
        self.assertEqual(data['status'],'awaiting_authorization')
        self.assertEqual(self.callback(session),307)
        _,data=self.poll(session['session_id'])
        self.assertEqual(data['status'],'ready')

    def test_cancel_only_current_worker_and_start_produces_new_link(self):
        old=self.start()
        _,cancelled=self.run_flow('--cancel',old['session_id'])
        self.assertEqual(cancelled['status'],'cancelled')
        current=self.start()
        self.assertNotEqual(old['session_id'],current['session_id'])
        self.assertNotEqual(old['auth_url'],current['auth_url'])
        self.assertFalse(self.log.exists())

    def test_expiration_is_terminal_and_does_not_verify_api(self):
        result,session=self.run_flow('--execution-context','local','--profile','short','--timeout','1')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        _,data=self.poll(session['session_id'])
        self.assertEqual(data['status'],'expired')
        self.assertNotIn('auth_url',data)
        self.assertFalse(self.log.exists())

    def test_remote_or_unknown_context_never_starts_local_auth(self):
        for context in ('remote','unknown'):
            result,data=self.run_flow('--execution-context',context)
            self.assertEqual(result.returncode,1)
            self.assertEqual(data['status'],'needs_host_auth')
            self.assertNotIn('auth_url',data)
        self.assertFalse(self.states.exists())
        self.assertFalse((self.home/'.tccli').exists())

    def test_native_failure_is_sanitized_and_does_not_verify(self):
        result,data=self.run_flow('--execution-context','local',TEST_NATIVE_FAILURE='1')
        self.assertEqual(result.returncode,1)
        self.assertEqual(data['status'],'failed')
        self.assertNotIn('fixture exception',result.stdout+result.stderr)
        self.assertFalse(self.log.exists())

    def test_browser_success_requires_api_check_success(self):
        session=self.start(TEST_TCCLI_MODE='failure')
        self.assertEqual(self.callback(session),307)
        result,data=self.poll(session['session_id'])
        self.assertEqual(result.returncode,1)
        self.assertEqual(data['error']['code'],'AUTH_CHECK_FAILED')
        self.assertIn('保存认证',data['error']['message'])
        self.assertIn('无需重新登录',data['error']['message'])

    def test_manual_codes_and_unsupported_runtime_are_rejected(self):
        result=subprocess.run(['/bin/bash',str(ROOT/'scripts/auth/login.sh'),'--no-browser'],
                              env=self.env,text=True,capture_output=True)
        self.assertEqual(result.returncode,2)
        fake=self.bin/'tccli'
        fake.write_text('#!/bin/sh\nexit 0\n')
        result,data=self.run_flow('--execution-context','local')
        self.assertEqual(result.returncode,1)
        self.assertEqual(data['error']['code'],'UNSUPPORTED_RUNTIME')
        self.assertFalse(self.log.exists())

    def test_native_link_must_point_to_the_owned_loopback_listener(self):
        for callback in ('http://localhost:1', 'http://example.com:9000', 'http://name@localhost:9000',
                         'http://localhost:9000/?token=fixture', 'https://localhost:9000'):
            result,data=self.run_flow('--execution-context','local',TEST_NATIVE_BAD_REDIRECT=callback)
            self.assertEqual(result.returncode,1,result.stdout+result.stderr)
            self.assertEqual(data['error']['code'],'UNSUPPORTED_AUTH_URL')
            self.assertNotIn('auth_url',data)
        self.assertFalse(self.log.exists())

    def test_ipv6_callback_and_both_addresses_are_exclusively_owned(self):
        from urllib.parse import parse_qs, urlsplit
        session=self.start()
        outer=parse_qs(urlsplit(session['auth_url']).query)
        inner=parse_qs(urlsplit(outer['redirect_url'][0]).query)
        port=urlsplit(inner['redirect_url'][0]).port
        for family,address in ((socket.AF_INET,'127.0.0.1'),(socket.AF_INET6,'::1')):
            with socket.socket(family,socket.SOCK_STREAM) as contender:
                with self.assertRaises(OSError) as raised:
                    contender.bind((address,port))
                self.assertEqual(raised.exception.errno,errno.EADDRINUSE)
        self.assertEqual(self.callback(session,host='::1'),307)
        _,ready=self.poll(session['session_id'])
        self.assertEqual(ready['status'],'ready')

    def test_cancel_waits_for_native_exit_before_acknowledging_or_restarting(self):
        marker=self.root/'save-started'
        session=self.start(TEST_NATIVE_SAVE_DELAY='0.7',TEST_NATIVE_SAVE_MARKER=str(marker),TEST_NATIVE_IGNORE_TERM='1')
        self.assertEqual(self.callback(session),307)
        deadline=time.monotonic()+2
        while not marker.exists() and time.monotonic()<deadline:
            time.sleep(.01)
        self.assertTrue(marker.exists())
        native_pid=int(marker.read_text())
        _,cancelled=self.run_flow('--cancel',session['session_id'])
        self.assertEqual(cancelled['status'],'cancelled')
        with self.assertRaises(ProcessLookupError):
            os.kill(native_pid,0)
        current=self.start()
        self.assertNotEqual(current['session_id'],session['session_id'])
        time.sleep(.8)
        self.assertFalse((self.home/'.tccli/review.credential').exists())
        self.assertFalse(self.log.exists())

    def test_expiry_stops_native_writer_before_publishing_expired(self):
        marker=self.root/'save-started'
        result,session=self.run_flow('--execution-context','local','--profile','review','--timeout','1',
                                     TEST_NATIVE_SAVE_DELAY='1.3',TEST_NATIVE_SAVE_MARKER=str(marker),TEST_NATIVE_IGNORE_TERM='1')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(self.callback(session),307)
        _,expired=self.poll(session['session_id'])
        self.assertEqual(expired['status'],'expired')
        with self.assertRaises(ProcessLookupError):
            os.kill(int(marker.read_text()),0)
        time.sleep(.4)
        self.assertFalse((self.home/'.tccli/review.credential').exists())

    def test_terminal_state_does_not_bypass_profile_lifecycle_lock(self):
        session=self.start()
        self.run_flow('--cancel',session['session_id'])
        descriptor=os.open(self.states/'profile-review.active',os.O_RDWR)
        try:
            fcntl.flock(descriptor,fcntl.LOCK_EX)
            _,blocked=self.run_flow('--execution-context','local','--profile','review')
            self.assertEqual(blocked['status'],'stopping')
            self.assertEqual(blocked['session_id'],session['session_id'])
            self.assertNotIn('auth_url',blocked)
        finally:
            os.close(descriptor)
        current=self.start()
        self.assertNotEqual(current['session_id'],session['session_id'])


class LoopbackBindingTests(unittest.TestCase):
    def test_ipv6_collision_closes_ipv4_and_reselects_one_shared_port(self):
        spec=importlib.util.spec_from_file_location('auth_loopback_binding',ROOT/'scripts/auth/login_flow.py')
        flow=importlib.util.module_from_spec(spec)
        spec.loader.exec_module(flow)
        created=[]
        ports=iter((41001,41002))
        class FakeServer:
            def __init__(self,address,handler):
                port=next(ports) if self.address_family==socket.AF_INET else address[1]
                if self.address_family==socket.AF_INET6 and port==41001:
                    raise OSError(errno.EADDRINUSE,'fixture IPv6 service')
                self.server_address=(address[0],port)
                self.closed=False
                created.append(self)
            def server_close(self):
                self.closed=True
        servers=flow.loopback_servers(FakeServer,object())
        self.assertTrue(created[0].closed)
        self.assertEqual([server.server_address for server in servers],[('127.0.0.1',41002),('::1',41002)])
        self.assertFalse(any(server.closed for server in servers))


class StatusRaceTests(unittest.TestCase):
    def setUp(self):
        spec=importlib.util.spec_from_file_location('auth_status_race',ROOT/'scripts/auth/login_flow.py')
        self.flow=importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.flow)
        self.pending={'version':2,'profile':'review','status':'verifying'}
        self.ready=dict(self.pending,status='ready')
        self.directory=Path('/unused/auth/session')

    def test_supervisor_final_publish_before_exit_cannot_regress_to_failed(self):
        with mock.patch.object(self.flow,'read_json',side_effect=[self.pending,self.ready]), \
             mock.patch.object(self.flow,'process_alive',return_value=False), \
             mock.patch.object(self.flow,'lifecycle_file') as lock, \
             mock.patch.object(self.flow,'update_status') as write:
            self.assertEqual(self.flow.status(self.directory),self.ready)
        lock.assert_not_called()
        write.assert_not_called()

    def test_busy_successor_lock_cannot_regress_latest_ready_to_stopping(self):
        with mock.patch.object(self.flow,'read_json',side_effect=[self.pending,self.pending,self.ready]), \
             mock.patch.object(self.flow,'process_alive',return_value=False), \
             mock.patch.object(self.flow,'lifecycle_file',return_value=99), \
             mock.patch.object(self.flow.fcntl,'flock',side_effect=BlockingIOError), \
             mock.patch.object(self.flow.os,'close'), \
             mock.patch.object(self.flow,'update_status') as write:
            self.assertEqual(self.flow.status(self.directory),self.ready)
        write.assert_not_called()

    def test_free_lifecycle_lock_requires_fresh_state_before_recovery_write(self):
        with mock.patch.object(self.flow,'read_json',side_effect=[self.pending,self.pending,self.ready]), \
             mock.patch.object(self.flow,'process_alive',return_value=False), \
             mock.patch.object(self.flow,'lifecycle_file',return_value=99), \
             mock.patch.object(self.flow.fcntl,'flock') as lock, \
             mock.patch.object(self.flow.os,'close'), \
             mock.patch.object(self.flow,'update_status') as write:
            self.assertEqual(self.flow.status(self.directory),self.ready)
        lock.assert_called_once_with(99,fcntl.LOCK_EX|fcntl.LOCK_NB)
        write.assert_not_called()

    def test_start_waiter_does_not_replace_result_published_during_poll(self):
        flow=self.flow
        class FinishedSupervisor:
            pid=12345
            def __init__(self,arguments,**kwargs):
                self.directory=Path(arguments[arguments.index('--directory')+1])
            def poll(self):
                latest=flow.read_json(self.directory/'state.json')
                flow.update_status(self.directory,latest,'ready')
                return 0
        with tempfile.TemporaryDirectory(prefix='cvm-start-race-') as temporary, \
             mock.patch.object(flow,'state_root',return_value=Path(temporary)), \
             mock.patch.object(flow,'native_python',return_value=sys.executable), \
             mock.patch.object(flow.subprocess,'Popen',side_effect=FinishedSupervisor):
            value=flow.start('review',300,'local')
            self.assertEqual(value['status'],'ready')
            self.assertEqual(flow.read_json(Path(temporary)/value['session_id']/'state.json')['status'],'ready')


if __name__ == '__main__':
    unittest.main()
