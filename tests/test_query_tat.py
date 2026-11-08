"""Offline query pagination and TAT batch regression tests. Never contacts cloud APIs."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FAKE = r'''
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['TEST_CALLS'], 'a') as f:
    f.write(json.dumps(args) + '\n')
config = json.loads(Path(os.environ['TEST_FIXTURE']).read_text())
action = args[1]
def value(key, default=None):
    return args[args.index(key)+1] if key in args else default
if config.get('fail_action') == action:
    print('UnauthorizedOperation', file=sys.stderr)
    sys.exit(37)
if action == 'RunCommand':
    print(json.dumps({'InvocationId':'inv-test', 'RequestId':'req-submit'})); sys.exit()
if action == 'DescribeSecurityGroupPolicies':
    print(json.dumps({'SecurityGroupPolicySet':{'Version':'1','Ingress':[{'Action':'DROP','Port':'22','CidrBlock':'0.0.0.0/0'}],'Egress':[]},'RequestId':'req-sg'})); sys.exit()
if action == 'DescribeInvocations':
    expected = config.get('expected', ['ins-a','ins-b'])
    print(json.dumps({'InvocationSet':[{'InvocationId':'inv-test','InvocationStatus':'RUNNING','InvocationTaskBasicInfoSet':[{'InstanceId':i} for i in expected]}], 'TotalCount':1, 'RequestId':'req-overview'})); sys.exit()
keys = {'DescribeInstances':'InstanceSet','DescribeInstancesStatus':'InstanceStatusSet','DescribeImages':'ImageSet','DescribeVpcs':'VpcSet','DescribeSubnets':'SubnetSet','DescribeSecurityGroups':'SecurityGroupSet','DescribeKeyPairs':'KeyPairSet','DescribeAutomationAgentStatus':'AutomationAgentSet','DescribeRegions':'RegionSet','DescribeZones':'ZoneSet','DescribeInstanceTypeConfigs':'InstanceTypeConfigSet','DescribeInvocationTasks':'InvocationTaskSet'}
key=keys[action]
offset=int(value('--Offset','0')); limit=int(value('--Limit','100'))
if action == 'DescribeInvocationTasks':
    state_path=Path(os.environ['TEST_STATE'])
    cycle=int(state_path.read_text()) if state_path.exists() else -1
    if offset == 0:
        cycle+=1; state_path.write_text(str(cycle))
    cycles=config['task_cycles']
    items=cycles[min(cycle,len(cycles)-1)]
else:
    items=config.get('items',[])
if config.get('repeat_page'): offset=0
page=items[offset:offset+limit]
if config.get('empty_second_page') and offset>0: page=[]
response={key:page, 'TotalCount':config.get('total',len(items)), 'RequestId':'req-'+str(offset)}
print(json.dumps(response))
'''


class QueryTatTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name)
        self.bin = self.path / 'bin'
        self.bin.mkdir()
        fake = self.bin / 'tccli'
        fake.write_text('#!' + sys.executable + '\n' + FAKE)
        fake.chmod(0o755)
        sleep = self.bin / 'sleep'
        sleep.write_text('#!/bin/sh\nexit 0\n')
        sleep.chmod(0o755)
        self.calls = self.path / 'calls'
        self.fixture = self.path / 'fixture.json'
        self.env = {
            'PATH': str(self.bin) + os.pathsep + os.environ['PATH'],
            'HOME': str(self.path),
            'LANG': 'C.UTF-8',
            'TENCENT_CVM_PROFILE': 'test',
            'TEST_CALLS': str(self.calls),
            'TEST_FIXTURE': str(self.fixture),
            'TEST_STATE': str(self.path / 'state'),
            'TENCENT_CVM_PASSWORD_FILE': str(self.path / 'unused-passwords'),
        }
        self.fixture.write_text('{}')

    def tearDown(self):
        self.temp.cleanup()

    def run_script(self, script, *args, fixture=None):
        if fixture is not None:
            self.fixture.write_text(json.dumps(fixture))
        return subprocess.run(['/bin/bash', str(ROOT / 'scripts' / script), *args],
                              env=self.env, text=True, capture_output=True, timeout=15)

    def logged(self):
        return [json.loads(x) for x in self.calls.read_text().splitlines()] if self.calls.exists() else []

    @staticmethod
    def task(instance, state='SUCCESS', code=0, dropped=0):
        return {'InstanceId':instance, 'TaskStatus':state,
                'InvocationTaskId':'invt-'+instance[4:], 'InvocationId':'inv-test',
                'TaskResult':{'ExitCode':code, 'Output':'b2s=', 'Dropped':dropped,
                              'OutputUrl':'https://example.invalid/output' if dropped else ''}}

    def test_all_queries_merge_pages_and_report_complete(self):
        items = [{'InstanceId':f'ins-{i}', 'InstanceName':str(i)} for i in range(5)]
        result = self.run_script('query/describe-instances.sh','--all','--limit','2','--json', fixture={'items':items})
        self.assertEqual(result.returncode,0,result.stderr)
        data=json.loads(result.stdout)
        self.assertEqual(data['InstanceSet'],items)
        self.assertTrue(data['_Pagination']['Complete'])
        self.assertEqual([a[a.index('--Offset')+1] for a in self.logged()], ['0','2','4'])
        self.assertEqual(len(data['_Pagination']['RequestIds']),3)

    def test_default_page_is_explicitly_incomplete(self):
        result=self.run_script('query/describe-vpcs.sh','--limit','2','--json',fixture={'items':[{'VpcId':f'vpc-{i}'} for i in range(3)]})
        self.assertEqual(result.returncode,0,result.stderr)
        data=json.loads(result.stdout)
        self.assertFalse(data['_Pagination']['Complete'])
        self.assertEqual(data['_Pagination']['ReturnedCount'],2)
        self.assertEqual(data['_Pagination']['TotalCount'],3)

    def test_empty_or_repeated_page_fails_without_partial_json(self):
        for mode in ['repeat_page','empty_second_page']:
            with self.subTest(mode=mode):
                result=self.run_script('query/describe-instances.sh','--all','--limit','1','--json',fixture={'items':[{'InstanceId':'ins-a'},{'InstanceId':'ins-b'}],mode:True})
                self.assertNotEqual(result.returncode,0)
                self.assertEqual(result.stdout,'')

    def test_filter_name_is_data_not_shell(self):
        marker=self.path/'should-not-exist'
        name="demo'$(touch " + str(marker) + ");$(whoami)"
        result=self.run_script('query/describe-instances.sh','--name',name,'--json',fixture={'items':[]})
        self.assertEqual(result.returncode,0,result.stderr)
        args=self.logged()[0]
        filters=json.loads(args[args.index('--Filters')+1])
        self.assertEqual(filters[0]['Values'],[name])
        self.assertFalse(marker.exists())

    def test_invalid_pagination_and_conflicting_filters_do_not_call_api(self):
        cases=[('--limit',),('--limit','0'),('--limit','101'),('--offset','-1'),('--all','--offset','2'),('--instance-id','ins-a','--name','x'),('--instance-id','ins-a,ins-a')]
        for args in cases:
            with self.subTest(args=args):
                result=self.run_script('query/describe-instances.sh',*args)
                self.assertNotEqual(result.returncode,0)
        self.assertEqual(self.logged(),[])

    def test_json_support_and_arguments_across_query_entrypoints(self):
        cases=[('describe-images.sh','--image-id','img-test'),('describe-instance-status.sh','--instance-id','ins-test'),('describe-subnets.sh','--subnet-id','subnet-test'),('describe-security-groups.sh','--sg-id','sg-test'),('describe-key-pairs.sh','--key-id','skey-test'),('describe-zones.sh',),('describe-instance-types.sh',),('describe-regions.sh',)]
        for args in cases:
            with self.subTest(args=args):
                result=self.run_script('query/'+args[0],*args[1:],'--json',fixture={'items':[]})
                self.assertEqual(result.returncode,0,result.stderr)
                json.loads(result.stdout)
        image_args=self.logged()[0]
        self.assertIn('--ImageIds',image_args)
        self.assertNotIn('--Filters',image_args)

    def test_security_group_policy_inspection_is_read_only(self):
        result=self.run_script('query/describe-security-group-policies.sh','--sg-id','sg-test','--json')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(json.loads(result.stdout)['SecurityGroupPolicySet']['Ingress'][0]['Port'],'22')
        self.assertEqual(self.logged()[0][1],'DescribeSecurityGroupPolicies')

    def test_available_regions_filter_also_applies_to_json(self):
        result=self.run_script('query/describe-regions.sh','--available','--json',fixture={'items':[{'Region':'ap-guangzhou','RegionState':'AVAILABLE'},{'Region':'eu-test','RegionState':'UNAVAILABLE'}]})
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(len(json.loads(result.stdout)['RegionSet']),1)

    def test_tat_waits_for_every_target(self):
        fixture={'task_cycles':[[self.task('ins-a'),self.task('ins-b','RUNNING',None)],[self.task('ins-a'),self.task('ins-b')]]}
        result=self.run_script('tat/tat-run-command.sh','--instance-id','ins-a,ins-b','--cmd','df -h','--wait','--json',fixture=fixture)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(json.loads(result.stdout)['Summary']['Status'],'SUCCESS')
        self.assertEqual(sum(a[1]=='DescribeInvocationTasks' for a in self.logged()),2)
        self.assertEqual(sum(a[1]=='RunCommand' for a in self.logged()),1)

    def test_tat_failure_does_not_hide_other_pending_targets(self):
        fixture={'task_cycles':[[self.task('ins-a','START_FAILED',None),self.task('ins-b','RUNNING',None)],[self.task('ins-a','START_FAILED',None),self.task('ins-b')]]}
        result=self.run_script('tat/tat-run-command.sh','--instance-id','ins-a,ins-b','--cmd','uptime','--wait','--json',fixture=fixture)
        self.assertEqual(result.returncode,1,result.stderr)
        self.assertEqual(json.loads(result.stdout)['Summary']['FailedCount'],1)
        self.assertEqual(sum(a[1]=='DescribeInvocationTasks' for a in self.logged()),2)

    def test_tat_waits_for_missing_targets_then_times_out(self):
        result=self.run_script('tat/tat-run-command.sh','--instance-id','ins-a,ins-b','--cmd','uptime','--wait','--wait-timeout','1','--json',fixture={'task_cycles':[[self.task('ins-a')]]})
        self.assertEqual(result.returncode,124,result.stderr)
        data=json.loads(result.stdout)
        self.assertEqual(data['InvocationId'],'inv-test')
        self.assertEqual(data['Summary']['MissingInstanceIds'],['ins-b'])
        self.assertEqual(data['Summary']['Status'],'WAIT_TIMEOUT')

    def test_tat_success_with_nonzero_exit_is_failure(self):
        result=self.run_script('tat/tat-run-command.sh','--instance-id','ins-a','--cmd','uptime','--wait','--json',fixture={'task_cycles':[[self.task('ins-a',code=9)]]})
        self.assertEqual(result.returncode,1,result.stderr)
        self.assertEqual(json.loads(result.stdout)['Summary']['Status'],'FAILED')

    def test_tat_fetches_all_task_pages_and_exposes_truncation(self):
        ids=[f'ins-{i}' for i in range(101)]
        tasks=[self.task(i,dropped=500 if i=='ins-0' else 0) for i in ids]
        result=self.run_script('tat/tat-run-command.sh','--instance-id',','.join(ids),'--cmd','uptime','--wait','--json',fixture={'task_cycles':[tasks]})
        self.assertEqual(result.returncode,0,result.stderr)
        data=json.loads(result.stdout)
        self.assertEqual(len(data['InvocationTaskSet']),101)
        self.assertEqual(data['Summary']['DroppedBytes'],500)
        calls=[a for a in self.logged() if a[1]=='DescribeInvocationTasks']
        self.assertEqual([a[a.index('--Offset')+1] for a in calls],['0','100'])

    def test_tat_rejects_shell_bypasses_before_submit(self):
        for command in ['env sh -c id','uptime;id','uptime\nid','date -s 2027-01-01']:
            with self.subTest(command=command):
                result=self.run_script('tat/tat-run-command.sh','--instance-id','ins-a','--cmd',command)
                self.assertNotEqual(result.returncode,0)
        self.assertEqual(self.logged(),[])

    def test_describe_invocation_reports_actual_failures_and_all_tasks(self):
        fixture={'expected':['ins-a','ins-b'],'task_cycles':[[self.task('ins-a'),self.task('ins-b','TASK_TIMEOUT',None)]]}
        result=self.run_script('tat/tat-describe-invocation.sh','--invocation-id','inv-test','--show-output','--json',fixture=fixture)
        self.assertEqual(result.returncode,0,result.stderr)
        data=json.loads(result.stdout)
        self.assertEqual(data['Summary']['Status'],'FAILED')
        self.assertEqual(len(data['InvocationTaskSet']),2)
        self.assertEqual(data['InvocationTaskSet'][0]['TaskResult']['Output'],'b2s=')


if __name__ == '__main__':
    unittest.main()
