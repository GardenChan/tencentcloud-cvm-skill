"""Offline network planning/provisioning tests with a stateful fake tccli."""
import json
import os
from pathlib import Path
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
ENTRY = ROOT / "scripts/network/ensure-network.sh"

FAKE = r'''
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
service, action = args[:2]
params = {}
for i in range(2, len(args), 2):
    value = args[i + 1]
    try:
        value = json.loads(value)
    except ValueError:
        pass
    params[args[i][2:]] = value
with open(os.environ['NETWORK_LOG'], 'a') as stream:
    stream.write(json.dumps({'Action': action, 'Params': params}) + '\n')
db_file = Path(os.environ['NETWORK_DB'])
db = json.loads(db_file.read_text())
if action == 'DescribeZones':
    result = {'ZoneSet': [{'Zone': 'ap-guangzhou-3', 'ZoneState': 'AVAILABLE'}]}
elif action == 'DescribeVpcs':
    result = {'VpcSet': [db['vpcs'][i] for i in params['VpcIds'] if i in db['vpcs']]}
elif action == 'DescribeSubnets':
    if 'SubnetIds' in params:
        items = [db['subnets'][i] for i in params['SubnetIds'] if i in db['subnets']]
    else:
        items = [item for item in db['subnets'].values() if item['VpcId'] == params['Filters'][0]['Values'][0]]
    offset, limit = int(params.get('Offset', 0)), int(params.get('Limit', 100))
    result = {'SubnetSet': items[offset:offset+limit], 'TotalCount': len(items)}
elif action == 'DescribeSecurityGroups':
    result = {'SecurityGroupSet': [db['groups'][i] for i in params['SecurityGroupIds'] if i in db['groups']]}
elif action == 'DescribeSecurityGroupPolicies':
    result = {'SecurityGroupPolicySet': db['policies'][params['SecurityGroupId']]}
elif action == 'CreateVpc':
    obj = {'VpcId': 'vpc-created', 'VpcName': params['VpcName'], 'CidrBlock': params['CidrBlock']}
    db['vpcs']['vpc-created'] = obj
    result = {'Vpc': obj}
elif action == 'CreateSubnet':
    obj = {'SubnetId': 'subnet-created', **{k: params[k] for k in ('SubnetName', 'VpcId', 'CidrBlock', 'Zone')}}
    db['subnets']['subnet-created'] = obj
    result = {'Subnet': obj}
elif action == 'CreateSecurityGroupWithPolicies':
    obj = {'SecurityGroupId': 'sg-created', 'SecurityGroupName': params['GroupName']}
    db['groups']['sg-created'] = obj
    db['policies']['sg-created'] = params['SecurityGroupPolicySet']
    result = {'SecurityGroup': obj}
else:
    print('Unexpected API', action, file=sys.stderr)
    raise SystemExit(99)
db_file.write_text(json.dumps(db))
if os.environ.get('NETWORK_FAIL_ACTION') == action:
    print('simulated lost response', file=sys.stderr)
    raise SystemExit(19)
print(json.dumps({**result, 'RequestId': 'req-simulated'}))
'''


class NetworkTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='cvm-network-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        for name in ('python3', 'dirname', 'jq'):
            (self.bin / name).symlink_to(shutil.which(name))
        (self.bin / 'tccli').write_text(f'#!{sys.executable}\n' + FAKE)
        (self.bin / 'tccli').chmod(0o755)
        self.log = self.root / 'calls.jsonl'
        self.db = self.root / 'cloud.json'
        self.state = self.root / 'network.json'
        self.home = self.root / 'home'
        self.home.mkdir()
        self.db.write_text(json.dumps({'vpcs': {}, 'subnets': {}, 'groups': {}, 'policies': {}}))
        self.env = {key: os.environ[key] for key in ('LANG', 'TMPDIR') if key in os.environ}
        self.env.update(PATH=str(self.bin), HOME=str(self.home), NETWORK_DB=str(self.db), NETWORK_LOG=str(self.log))
        self.base = ['--region', 'ap-guangzhou', '--zone', 'ap-guangzhou-3', '--state-file', str(self.state)]

    def run_network(self, *args, extra_env=None):
        return subprocess.run(['/bin/bash', str(ENTRY), *self.base, *args], input='', text=True,
                              capture_output=True, env={**self.env, **(extra_env or {})}, timeout=20)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def writes(self):
        return [call for call in self.calls() if call['Action'].startswith(('Create', 'Modify', 'Delete'))]

    def seed(self):
        db = {'vpcs': {'vpc-existing': {'VpcId': 'vpc-existing', 'VpcName': 'existing', 'CidrBlock': '10.20.0.0/16'}},
              'subnets': {'subnet-existing': {'SubnetId': 'subnet-existing', 'VpcId': 'vpc-existing', 'SubnetName': 'existing', 'Zone': 'ap-guangzhou-3', 'CidrBlock': '10.20.0.0/24'}},
              'groups': {'sg-existing': {'SecurityGroupId': 'sg-existing', 'SecurityGroupName': 'existing'}},
              'policies': {'sg-existing': {'Ingress': [], 'Egress': []}}}
        self.db.write_text(json.dumps(db))
        return db

    def test_default_plan_is_read_only_and_emits_concrete_execute_command(self):
        result = self.run_network('--create')
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data['Status'], 'planned')
        self.assertEqual(data['Plan']['Vpc']['CidrBlock'], '10.0.0.0/16')
        self.assertEqual(data['Plan']['Subnet']['CidrBlock'], '10.0.0.0/24')
        self.assertEqual(data['Plan']['SecurityGroup']['Policies']['Ingress'], [])
        self.assertNotIn('Port', data['Plan']['SecurityGroup']['Policies']['Egress'][0])
        command = shlex.split(data['ExecuteCommand'])
        self.assertIn('--yes', command)
        self.assertIn('--subnet-cidr', command)
        self.assertFalse(self.state.exists())
        self.assertEqual(self.writes(), [])

    def test_explicit_execution_creates_three_resources_with_private_checkpoint(self):
        result = self.run_network('--create', '--yes', '--allow-web', '--ssh-cidr', '198.51.100.4/32')
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data['VirtualPrivateCloud'], {'VpcId': 'vpc-created', 'SubnetId': 'subnet-created'})
        self.assertEqual(data['SecurityGroupIds'], ['sg-created'])
        self.assertEqual([call['Action'] for call in self.writes()], ['CreateVpc', 'CreateSubnet', 'CreateSecurityGroupWithPolicies'])
        policies = self.writes()[-1]['Params']['SecurityGroupPolicySet']
        self.assertEqual([rule['Port'] for rule in policies['Ingress']], ['80', '443', '22'])
        self.assertEqual(policies['Ingress'][-1]['CidrBlock'], '198.51.100.4/32')
        self.assertEqual(stat.S_IMODE(self.state.stat().st_mode), 0o600)
        self.assertIsNone(json.loads(self.state.read_text())['PendingOperation'])
        self.log.unlink()
        repeat = self.run_network('--create', '--yes', '--allow-web', '--ssh-cidr', '198.51.100.4/32')
        self.assertEqual(repeat.returncode, 0, repeat.stderr)
        self.assertEqual(self.writes(), [])

    def test_reuse_validates_explicit_ids_and_preserves_group_rules(self):
        self.seed()
        result = self.run_network('--vpc-id', 'vpc-existing', '--subnet-id', 'subnet-existing', '--sg-id', 'sg-existing', '--yes')
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data['Plan']['SecurityGroup']['Policies'], {'Ingress': [], 'Egress': []})
        self.assertEqual(self.writes(), [])
        self.assertIn('DescribeSecurityGroupPolicies', [call['Action'] for call in self.calls()])

    def test_resume_accepts_provider_empty_template_objects_without_rewriting_rules(self):
        result = self.run_network('--create', '--yes', '--allow-web')
        self.assertEqual(result.returncode, 0, result.stderr)
        original = self.db.read_text()
        returned_templates = [
            {'ServiceTemplate': {'ServiceId': '', 'ServiceGroupId': ''},
             'AddressTemplate': {'AddressId': '', 'AddressGroupId': ''}},
            {'ServiceTemplate': {'ServiceId': None, 'ServiceGroupId': '', 'Nested': {'Id': ''}},
             'AddressTemplate': {'AddressId': '', 'AddressGroupId': None, 'Nested': {'Child': {}}}},
        ]
        for templates in returned_templates:
            with self.subTest(templates=templates):
                db = json.loads(original)
                for rules in db['policies']['sg-created'].values():
                    for rule in rules:
                        rule.update(templates)
                self.db.write_text(json.dumps(db))
                self.log.unlink()
                resumed = self.run_network('--create', '--yes', '--allow-web')
                self.assertEqual(resumed.returncode, 0, resumed.stderr)
                self.assertEqual(json.loads(resumed.stdout)['Status'], 'ready')
                self.assertEqual(self.writes(), [])
                self.assertEqual(json.loads(self.db.read_text())['policies'], db['policies'])

    def test_resume_rejects_real_template_ids_even_when_other_fields_are_empty(self):
        result = self.run_network('--create', '--yes', '--allow-web')
        self.assertEqual(result.returncode, 0, result.stderr)
        original = self.db.read_text()
        templates = [
            ('ServiceTemplate', {'ServiceId': 'ppm-real', 'ServiceGroupId': ''}),
            ('ServiceTemplate', {'ServiceId': '', 'ServiceGroupId': 'ppmg-real'}),
            ('AddressTemplate', {'AddressId': 'ipm-real', 'AddressGroupId': ''}),
            ('AddressTemplate', {'AddressId': '', 'AddressGroupId': 'ipmg-real'}),
            ('AddressTemplate', {'AddressId': '', 'Nested': {'AddressId': 'ipm-real', 'Empty': ''}}),
        ]
        for name, template in templates:
            with self.subTest(template=template):
                db = json.loads(original)
                db['policies']['sg-created']['Ingress'][0][name] = template
                self.db.write_text(json.dumps(db))
                self.log.unlink()
                resumed = self.run_network('--create', '--yes', '--allow-web')
                self.assertNotEqual(resumed.returncode, 0)
                self.assertIn('规则与原计划不一致', json.loads(resumed.stdout)['Error'])
                self.assertEqual(self.writes(), [])

    def test_no_implicit_resource_selection_or_creation(self):
        self.seed()
        result = self.run_network('--yes')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.writes(), [])
        self.assertIn('--create', json.loads(result.stdout)['Error'])

    def test_wrong_subnet_zone_or_vpc_stops_before_writes(self):
        for field, value in [('Zone', 'ap-guangzhou-4'), ('VpcId', 'vpc-other')]:
            with self.subTest(field=field):
                db = self.seed()
                db['subnets']['subnet-existing'][field] = value
                self.db.write_text(json.dumps(db))
                result = self.run_network('--vpc-id', 'vpc-existing', '--subnet-id', 'subnet-existing', '--sg-id', 'sg-existing', '--yes')
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.writes(), [])

    def test_ssh_world_open_and_non_private_or_overlapping_cidr_rejected(self):
        for args in [('--ssh-cidr', '0.0.0.0/0'), ('--vpc-cidr', '8.8.0.0/16'), ('--subnet-cidr', '10.2.0.0/24')]:
            with self.subTest(args=args):
                result = self.run_network('--create', '--yes', *args)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.writes(), [])

    def test_existing_subnets_are_checked_and_default_avoids_overlap(self):
        self.seed()
        result = self.run_network('--create', '--vpc-id', 'vpc-existing', '--sg-id', 'sg-existing')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['Plan']['Subnet']['CidrBlock'], '10.20.1.0/24')
        result = self.run_network('--create', '--vpc-id', 'vpc-existing', '--sg-id', 'sg-existing', '--subnet-cidr', '10.20.0.0/24', '--yes')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.writes(), [])

    def test_unknown_creation_result_blocks_replay_and_explicit_id_recovers(self):
        result = self.run_network('--create', '--yes', extra_env={'NETWORK_FAIL_ACTION': 'CreateSubnet'})
        self.assertNotEqual(result.returncode, 0)
        data = json.loads(result.stdout)
        self.assertEqual(data['VpcId'], 'vpc-created')
        self.assertEqual(data['PendingOperation']['Action'], 'CreateSubnet')
        self.assertNotIn('CreateSecurityGroupWithPolicies', [call['Action'] for call in self.calls()])
        self.log.unlink()
        retry = self.run_network('--create', '--yes')
        self.assertNotEqual(retry.returncode, 0)
        self.assertEqual(self.calls(), [])
        recovered = self.run_network('--create', '--yes', '--subnet-id', 'subnet-created')
        self.assertEqual(recovered.returncode, 0, recovered.stderr)
        self.assertEqual([call['Action'] for call in self.writes()], ['CreateSecurityGroupWithPolicies'])
        self.assertEqual(json.loads(recovered.stdout)['Status'], 'ready')

    def test_profile_checkpoint_mismatch_never_creates(self):
        result = self.run_network('--create', '--yes', '--profile', 'work')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.log.unlink()
        other = self.run_network('--create', '--yes', '--profile', 'other')
        self.assertNotEqual(other.returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_environment_auth_is_preserved_and_source_changes_are_blocked(self):
        env = {'TENCENTCLOUD_SECRET_ID': 'dummy-id', 'TENCENTCLOUD_SECRET_KEY': 'dummy-key'}
        result = self.run_network('--create', '--yes', extra_env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data['AuthSource'], 'environment')
        self.assertNotIn('--profile', shlex.split(data['ResumeCommand']))
        self.assertTrue(all('profile' not in call['Params'] for call in self.calls()))
        self.assertNotIn('dummy-key', self.state.read_text())
        self.log.unlink()
        switched = self.run_network('--create', '--yes')
        self.assertNotEqual(switched.returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_reused_security_group_is_never_modified_by_web_flag(self):
        self.seed()
        result = self.run_network('--vpc-id', 'vpc-existing', '--subnet-id', 'subnet-existing', '--sg-id', 'sg-existing', '--allow-web', '--yes')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.writes(), [])


if __name__ == '__main__':
    unittest.main()
