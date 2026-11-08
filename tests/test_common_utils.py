"""Regression checks for account isolation, local state, and distributable packages."""
import concurrent.futures
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
STORE = ROOT / 'scripts/instance_store.py'
COMMON = ROOT / 'scripts/common.sh'


class LocalStateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.file = self.directory / 'private' / 'records.json'
        self.home = self.directory / 'home'
        self.home.mkdir()
        self.env = {'PATH': os.environ['PATH'], 'HOME': str(self.home), 'LANG': 'en_US.UTF-8',
                    'CVM_STORE_FILE': str(self.file), 'TENCENT_CVM_PASSWORD_FILE': str(self.file)}

    def store(self, action, *args, secret=None):
        return subprocess.run([sys.executable, str(STORE), action, *args], input=secret,
                              env=self.env, text=True, capture_output=True, timeout=10)

    def shell(self, code, **env):
        return subprocess.run(['/bin/bash', '-c', 'source "$1"\n' + code, 'test', str(COMMON)],
                              env={**self.env, **env}, text=True, capture_output=True, timeout=10)

    def test_locked_updates_preserve_all_concurrent_records(self):
        def save(index):
            return self.store('save', '--id', f'ins-test{index}', secret=f'fixture-{index}')
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(save, range(24)))
        for result in results:
            self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(self.file.read_text())
        self.assertEqual(len(data), 24)
        self.assertEqual(self.file.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.file.parent.stat().st_mode & 0o777, 0o700)

    def test_redaction_and_preserved_connection_fields(self):
        self.assertEqual(self.store('connect', '--id', 'ins-one', '--host', '192.0.2.1', '--region', 'ap-shanghai', '--user', 'ubuntu').returncode, 0)
        self.assertEqual(self.store('save', '--id', 'ins-one', secret='fixture-password').returncode, 0)
        for action, args in [('get', ['--id', 'ins-one']), ('list', [])]:
            result = self.store(action, *args)
            self.assertNotIn('fixture-password', result.stdout + result.stderr)
        result = self.store('get', '--id', 'ins-one')
        self.assertEqual(json.loads(result.stdout)['host'], '192.0.2.1')
        self.assertEqual(json.loads(result.stdout)['user'], 'ubuntu')
        self.assertEqual(self.store('get', '--id', 'ins-one', '--field', 'password').stdout.strip(), 'fixture-password')

    def test_corrupt_store_is_not_overwritten(self):
        self.file.parent.mkdir()
        self.file.write_text('broken record {')
        result = self.store('save', '--id', 'ins-new', secret='fixture-password')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.file.read_text(), 'broken record {')
        self.assertNotIn('fixture-password', result.stderr)

    def test_show_defaults_reports_corrupt_store_failure_without_fake_count(self):
        self.file.parent.mkdir()
        self.file.write_text('broken record {')
        result = subprocess.run(['/bin/bash', str(ROOT / 'scripts/utils/show-defaults.sh')],
                                env=self.env, text=True, capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('已保存:', result.stdout)
        self.assertEqual(self.file.read_text(), 'broken record {')

    def test_show_defaults_rejects_invalid_profile(self):
        result = subprocess.run(['/bin/bash', str(ROOT / 'scripts/utils/show-defaults.sh')],
                                env={**self.env, 'TENCENT_CVM_PROFILE': '../../bad'}, text=True,
                                capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('已保存:', result.stdout)

    def test_symlink_is_not_followed_or_replaced(self):
        target = self.directory / 'target'
        target.write_text('{}')
        self.file.parent.mkdir()
        self.file.symlink_to(target)
        result = self.store('save', '--id', 'ins-new', secret='fixture-password')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.file.is_symlink())
        self.assertEqual(target.read_text(), '{}')

    def test_profile_paths_are_isolated_and_legacy_default_preserved(self):
        for profile, expected in [('default', str(Path(self.env['HOME']) / '.tencent_cvm_passwords')),
                                  ('work', str(Path(self.env['HOME']) / '.tencent-cvm/work/passwords.json'))]:
            result = self.shell('password_file_path', TENCENT_CVM_PASSWORD_FILE='', TENCENT_CVM_PROFILE=profile)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), expected)
        result = self.shell('password_file_path', TENCENT_CVM_PROFILE='../../bad')
        self.assertNotEqual(result.returncode, 0)

    def test_config_does_not_overwrite_loaded_fields_with_defaults(self):
        config = self.directory / 'config.json'
        config.write_text(json.dumps({'Region': 'eu-frankfurt', 'Placement': {'Zone': 'eu-frankfurt-1'}, 'SystemDisk': {'DiskSize': 80}}))
        result = self.shell('load_defaults\nload_config_file "$TEST_CONFIG"\nprintf "%s|%s|%s" "$REGION" "$ZONE" "$DISK_SIZE"', TEST_CONFIG=str(config))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'eu-frankfurt|eu-frankfurt-1|80')

    def test_reveal_requires_explicit_option(self):
        self.store('save', '--id', 'ins-one', secret='fixture-password')
        command = ['/bin/bash', str(ROOT / 'scripts/utils/get-password.sh'), '--instance-id', 'ins-one']
        masked = subprocess.run(command, env=self.env, text=True, capture_output=True)
        self.assertEqual(masked.returncode, 0, masked.stderr)
        self.assertNotIn('fixture-password', masked.stdout + masked.stderr)
        revealed = subprocess.run(command + ['--reveal'], env=self.env, text=True, capture_output=True)
        self.assertEqual(revealed.stdout.strip(), 'fixture-password')

    def test_save_password_does_not_appear_in_output_or_clear_host(self):
        self.store('connect', '--id', 'ins-one', '--host', '192.0.2.1')
        result = self.shell('save_instance_password ins-one fixture-password')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('fixture-password', result.stdout + result.stderr)
        self.assertEqual(json.loads(self.file.read_text())['ins-one']['host'], '192.0.2.1')

    def test_region_support_is_not_a_small_static_list(self):
        for region in ('eu-frankfurt', 'ap-singapore', 'na-siliconvalley', 'ap-guangzhou'):
            result = self.shell('validate_region "$TEST_REGION"', TEST_REGION=region)
            self.assertEqual(result.returncode, 0, result.stderr)
        for region in ('', 'ap-guangzhou;echo pwn', '--bad', '$(whoami)'):
            self.assertNotEqual(self.shell('validate_region "$TEST_REGION"', TEST_REGION=region).returncode, 0)

    def test_ready_instance_records_provider_login_user_and_preserves_custom_user(self):
        binary = self.directory / 'tccli'
        binary.write_text(f'#!{sys.executable}\n' +
                          'import json\nprint(json.dumps({"InstanceSet": [{"InstanceId": "ins-one", '
                          '"InstanceState": "RUNNING", "PrivateIpAddresses": ["192.0.2.1"], '
                          '"DefaultLoginUser": "ubuntu"}]}))\n')
        binary.chmod(0o755)
        command = ['/bin/bash', str(ROOT / 'scripts/lifecycle/wait-instance.sh'),
                   '--instance-id', 'ins-one', '--timeout', '1']
        env = {**self.env, 'PATH': f'{self.directory}:{self.env["PATH"]}'}
        result = subprocess.run(command, env=env, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.file.read_text())['ins-one']['user'], 'ubuntu')
        self.assertEqual(self.store('connect', '--id', 'ins-one', '--user', 'customadmin').returncode, 0)
        result = subprocess.run(command, env=env, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.file.read_text())['ins-one']['user'], 'customadmin')


class TccliSerializationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='tccli-serialization-')
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.home = self.directory / 'home'
        self.home.mkdir()
        self.binary = self.directory / 'tccli'
        self.binary.write_text(f'#!{sys.executable}\n' + r'''
import json, os, pathlib, sys, time
if os.environ.get('TEST_STREAMS'):
    print(json.dumps(sys.argv[1:], ensure_ascii=False), flush=True)
    sys.stdout.write(sys.stdin.read())
    sys.stderr.write('native stderr\n')
    sys.exit(37)
marker = pathlib.Path(os.environ['TEST_MARKER'])
marker.write_text(str(os.getpid()))
if os.environ.get('TEST_GATE'):
    gate = pathlib.Path(os.environ['TEST_GATE'])
    while not gate.exists():
        time.sleep(0.02)
''')
        self.binary.chmod(0o755)
        self.env = {'PATH': f'{self.directory}:{os.environ["PATH"]}', 'HOME': str(self.home),
                    'PYTHONDONTWRITEBYTECODE': '1'}

    def spawn(self, name, *, shell=False, **env):
        marker = self.directory / name
        command = [sys.executable, str(ROOT / 'scripts/tccli_locked.py'), 'fixture', '--profile', name]
        if shell:
            command = ['/bin/bash', '-c', 'source "$1"\nrun_tccli fixture\nexit "$?"', 'test', str(COMMON)]
        process = subprocess.Popen(command, env={**self.env, 'TEST_MARKER': str(marker),
                                                'TENCENT_CVM_PROFILE': name, **env},
                                   stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   start_new_session=True)
        self.addCleanup(self.cleanup_process, process)
        return process, marker

    @staticmethod
    def cleanup_process(process):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate(timeout=5)

    def wait_marker(self, marker):
        deadline = time.monotonic() + 5
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(marker.exists(), f'native command did not start: {marker.name}')

    def test_different_profiles_share_lock_and_preserve_lock_inode(self):
        gate = self.directory / 'release'
        first, entered = self.spawn('first', shell=True, TEST_GATE=str(gate))
        self.wait_marker(entered)
        lock = self.home / '.tccli/.cvm-skill.lock'
        inode = lock.stat().st_ino
        second, waiting = self.spawn('second', shell=True)
        time.sleep(0.2)
        self.assertFalse(waiting.exists())
        gate.touch()
        self.assertEqual(first.wait(timeout=5), 0)
        self.assertEqual(second.wait(timeout=5), 0)
        self.assertTrue(waiting.exists())
        self.assertEqual(lock.stat().st_ino, inode)
        self.assertEqual(lock.stat().st_mode & 0o777, 0o600)
        self.assertEqual(lock.read_bytes(), b'')

    def test_parent_shell_exit_keeps_lock_until_native_process_exits(self):
        gate = self.directory / 'release'
        first, entered = self.spawn('first', shell=True, TEST_GATE=str(gate))
        self.wait_marker(entered)
        native_pid = int(entered.read_text())
        self.assertNotEqual(first.pid, native_pid)
        first.kill()
        first.wait(timeout=5)
        os.kill(native_pid, 0)
        second, waiting = self.spawn('second')
        time.sleep(0.2)
        self.assertFalse(waiting.exists())
        gate.touch()
        self.assertEqual(second.wait(timeout=5), 0)
        self.assertTrue(waiting.exists())

    def test_cancelled_lock_waiter_never_starts_native_command(self):
        gate = self.directory / 'release'
        first, entered = self.spawn('first', TEST_GATE=str(gate))
        self.wait_marker(entered)
        second, waiting = self.spawn('second')
        time.sleep(0.2)
        second.terminate()
        self.assertEqual(second.wait(timeout=5), -signal.SIGTERM)
        gate.touch()
        self.assertEqual(first.wait(timeout=5), 0)
        self.assertFalse(waiting.exists())

    def test_different_homes_do_not_block_each_other(self):
        gate = self.directory / 'release'
        first, entered = self.spawn('first', TEST_GATE=str(gate))
        self.wait_marker(entered)
        other_home = self.directory / 'other-home'
        other_home.mkdir()
        second, independent = self.spawn('second', HOME=str(other_home))
        self.assertEqual(second.wait(timeout=5), 0)
        self.assertTrue(independent.exists())
        self.assertIsNone(first.poll())
        gate.touch()
        self.assertEqual(first.wait(timeout=5), 0)

    def test_run_tccli_preserves_arguments_streams_and_exit_code(self):
        arguments = ['cvm', 'Fixture', '--value', 'spaces $() `literal` 中文']
        result = subprocess.run(['/bin/bash', '-c', 'source "$1"\nshift\nrun_tccli "$@"',
                                 'test', str(COMMON), *arguments],
                                input='native stdin\n', text=True, capture_output=True,
                                env={**self.env, 'TEST_STREAMS': '1', 'TENCENT_CVM_PROFILE': 'selected'}, timeout=5)
        self.assertEqual(result.returncode, 37)
        first_line, content = result.stdout.split('\n', 1)
        self.assertEqual(json.loads(first_line), arguments + ['--output', 'json', '--timeout', '60', '--profile', 'selected'])
        self.assertEqual(content, 'native stdin\n')
        self.assertEqual(result.stderr, 'native stderr\n')

    def test_symlink_lock_is_rejected_without_touching_target_or_running_tccli(self):
        directory = self.home / '.tccli'
        directory.mkdir()
        target = self.directory / 'untouched'
        target.write_text('unchanged')
        target.chmod(0o640)
        (directory / '.cvm-skill.lock').symlink_to(target)
        process, marker = self.spawn('rejected')
        output, errors = process.communicate(timeout=5)
        self.assertEqual(process.returncode, 73)
        self.assertFalse(marker.exists())
        self.assertEqual(target.read_text(), 'unchanged')
        self.assertEqual(target.stat().st_mode & 0o777, 0o640)
        self.assertEqual(output, b'')
        self.assertNotIn(b'Traceback', errors)


class PackagingTests(unittest.TestCase):
    def test_package_is_verified_and_does_not_overwrite_without_force(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'release.zip'
            command = ['/bin/bash', str(ROOT / 'package.sh'), '--output', str(output)]
            result = subprocess.run(command, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            before = output.read_bytes()
            with zipfile.ZipFile(output) as archive:
                self.assertIsNone(archive.testzip())
                names = archive.namelist()
                self.assertIn('tencentcloud-cvm-skill/SKILL.md', names)
                self.assertIn('tencentcloud-cvm-skill/scripts/auth/login.sh', names)
                self.assertFalse(any('/.git/' in name or '__pycache__' in name or 'blog-article' in name for name in names))
            result = subprocess.run(command, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(output.read_bytes(), before)
            result = subprocess.run(command + ['--force'], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_doctor_default_never_runs_tccli_or_reads_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / 'tccli'
            marker = Path(directory) / 'called'
            binary.write_text('#!/bin/sh\ntouch "$TEST_MARKER"\nexit 1\n')
            binary.chmod(0o755)
            result = subprocess.run(['/bin/bash', str(ROOT / 'scripts/utils/doctor.sh'), '--json'],
                                    env={**os.environ, 'HOME': directory, 'PATH': f'{directory}:{os.environ["PATH"]}', 'TEST_MARKER': str(marker)},
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(marker.exists())
            data = json.loads(result.stdout)
            self.assertFalse(data['credentials_checked'])
            self.assertEqual(data['tools']['tccli']['path'], str(binary))

    def test_doctor_api_preserves_environment_auth_and_explicit_profile_override(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / 'tccli'
            call = Path(directory) / 'call.json'
            binary.write_text(f'#!{sys.executable}\n' +
                              'import json,os,sys\n' +
                              'open(os.environ["TEST_CALL"],"w").write(json.dumps(sys.argv[1:]))\n' +
                              'print(json.dumps({"RegionSet": [], "TotalCount": 0}))\n')
            binary.chmod(0o755)
            base_env = {key: os.environ[key] for key in ('LANG', 'TMPDIR') if key in os.environ}
            base_env.update({'HOME': directory, 'PATH': f'{directory}:{os.environ["PATH"]}', 'TEST_CALL': str(call),
                             'TENCENTCLOUD_SECRET_ID': 'dummy-id', 'TENCENTCLOUD_SECRET_KEY': 'dummy-key'})
            for options, additions, expected_profile in [
                ([], {}, None),
                (['--profile', 'explicit'], {}, 'explicit'),
                ([], {'TCCLI_PROFILE': 'native-profile'}, 'native-profile'),
            ]:
                with self.subTest(options=options, additions=additions):
                    result = subprocess.run(['/bin/bash', str(ROOT / 'scripts/utils/doctor.sh'), '--api', '--json', *options],
                                            env={**base_env, **additions}, text=True, capture_output=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertTrue(json.loads(result.stdout)['api_ready'])
                    args = json.loads(call.read_text())
                    if expected_profile is None:
                        self.assertNotIn('--profile', args)
                    else:
                        self.assertEqual(args[args.index('--profile') + 1], expected_profile)
                    self.assertNotIn('dummy-key', result.stdout + result.stderr + call.read_text())


if __name__ == '__main__':
    unittest.main()
