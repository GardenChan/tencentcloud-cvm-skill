"""Pure quote arithmetic and recommendation tests; no cloud API calls."""
from decimal import Decimal
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT/'scripts/lifecycle/price_estimate.py'
spec = importlib.util.spec_from_file_location('price_estimate',HELPER)
pricing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pricing)


def quote(instance, network=None):
    result={'Price':{'InstancePrice':instance},'RequestId':'req-test'}
    if network is not None: result['Price']['BandwidthPrice']=network
    return result


def hourly(rate='1', **kwargs):
    return {'ChargeUnit':'HOUR','UnitPrice':rate, **kwargs}


class PriceEstimateTests(unittest.TestCase):
    def estimate(self, value, **kwargs):
        return pricing.estimate(value,charge_type='POSTPAID_BY_HOUR',internet_charge_type='NONE',**kwargs)

    def test_flat_and_tiered_hours_use_decimal_arithmetic(self):
        flat=self.estimate(quote(hourly('0.1')))
        self.assertEqual(flat['EstimatedTotal'],Decimal('72'))
        tiered=hourly('0.2',UnitPriceDiscount='0.08',UnitPriceSecondStep='0.12',UnitPriceDiscountSecondStep='0.06',UnitPriceThirdStep='0.1',UnitPriceDiscountThirdStep='0.06')
        result=self.estimate(quote(tiered))
        self.assertEqual(result['EstimatedTotal'],Decimal('45.12'))
        self.assertEqual([s['Hours'] for s in result['Components'][0]['Segments']],[96,264,360])

    def test_boundaries_do_not_require_unused_tiers(self):
        item=hourly('2',UnitPriceSecondStep='1')
        self.assertEqual(self.estimate(quote(item),hours='96')['EstimatedTotal'],192)
        self.assertEqual(self.estimate(quote(item),hours='360')['EstimatedTotal'],456)
        self.assertEqual(self.estimate(quote(item),hours='361')['Components'][0]['Status'],'Unknown')

    def test_missing_middle_tier_is_unknown_not_extrapolated(self):
        result=self.estimate(quote(hourly('2',UnitPriceThirdStep='0.5')))
        self.assertIsNone(result['EstimatedTotal'])
        self.assertIn('SecondStep',result['Components'][0]['Reason'])

    def test_explicit_zero_discount_is_not_replaced_by_original(self):
        result=self.estimate(quote(hourly('1',UnitPriceDiscount=0)))
        self.assertEqual(result['EstimatedTotal'],0)
        self.assertFalse(result['GuaranteedCap'])

    def test_currency_unknown_or_mismatched_never_meets_budget(self):
        value=quote(hourly('0.1'))
        unknown=self.estimate(value,budget=100)
        self.assertIsNone(unknown['Currency'])
        self.assertEqual(unknown['Budget']['Status'],'Unknown')
        mismatched=self.estimate(value,budget=100,currency='USD',budget_currency='CNY')
        self.assertFalse(mismatched['Budget']['Comparable'])
        matching=self.estimate(value,budget=100,currency='CNY')
        self.assertEqual(matching['Budget']['Status'],'WithinEstimate')
        self.assertEqual(matching['Budget']['ComparedAmount'],72)

    def test_traffic_requires_volume_and_correct_unit(self):
        value=quote(hourly('.1'),{'ChargeUnit':'GB','UnitPrice':'.8'})
        unknown=pricing.estimate(value,charge_type='POSTPAID_BY_HOUR',internet_charge_type='TRAFFIC_POSTPAID_BY_HOUR',currency='CNY',budget=100)
        self.assertEqual(unknown['Budget']['Status'],'Unknown')
        known=pricing.estimate(value,charge_type='POSTPAID_BY_HOUR',internet_charge_type='TRAFFIC_POSTPAID_BY_HOUR',traffic_gb=10,currency='CNY',budget=100)
        self.assertEqual(known['EstimatedTotal'],80)
        self.assertEqual(known['Budget']['Status'],'WithinEstimate')
        self.assertFalse(known['Budget']['GuaranteedCap'])
        conflict=pricing.estimate(quote(hourly('.1'),hourly('.8')),charge_type='POSTPAID_BY_HOUR',internet_charge_type='TRAFFIC_POSTPAID_BY_HOUR',traffic_gb=10)
        self.assertIsNone(conflict['EstimatedTotal'])
        self.assertIn('conflicts',conflict['Components'][1]['Reason'])

    def test_known_components_can_already_exceed_budget(self):
        result=pricing.estimate(quote(hourly('1')),charge_type='POSTPAID_BY_HOUR',budget=100,currency='CNY')
        self.assertIsNone(result['EstimatedTotal'])
        self.assertEqual(result['Budget']['Status'],'Exceeds')
        self.assertEqual(result['Budget']['ComparedAmount'],720)

    def test_prepaid_requires_period_and_compares_monthly_average(self):
        value=quote({'DiscountPrice':1200,'OriginalPrice':2400})
        missing=pricing.estimate(value,charge_type='PREPAID',internet_charge_type='NONE')
        self.assertIsNone(missing['EstimatedTotal'])
        result=pricing.estimate(value,charge_type='PREPAID',period=12,internet_charge_type='NONE',currency='CNY',budget=100)
        self.assertEqual(result['EstimatedTotal'],1200)
        self.assertEqual(result['MonthlyAverage'],100)
        self.assertEqual(result['Budget']['Status'],'WithinEstimate')
        self.assertEqual(result['Budget']['Basis'],'monthly_average_fixed_cost')

    def test_prepaid_traffic_not_added_to_incompatible_period(self):
        result=pricing.estimate(quote({'DiscountPrice':1200},{'ChargeUnit':'GB','UnitPrice':1}),charge_type='PREPAID',period=12,internet_charge_type='TRAFFIC_POSTPAID_BY_HOUR',traffic_gb=10,currency='CNY',budget=100)
        self.assertEqual(result['KnownSubtotal'],1200)
        self.assertIsNone(result['EstimatedTotal'])
        self.assertEqual(result['Components'][1]['UsageScenario']['Amount'],10)
        self.assertEqual(result['Budget']['Status'],'Unknown')

    def test_prepaid_network_not_added_to_hourly_window(self):
        result=pricing.estimate(quote(hourly('.1'),{'DiscountPrice':120}),charge_type='POSTPAID_BY_HOUR',period=12,internet_charge_type='BANDWIDTH_PREPAID',currency='CNY',budget=100)
        self.assertEqual(result['KnownSubtotal'],72)
        self.assertIsNone(result['EstimatedTotal'])
        self.assertEqual(result['Components'][1]['PeriodQuote']['Amount'],120)
        self.assertEqual(result['Budget']['Status'],'Unknown')

    def test_unknown_unit_and_invalid_rate_are_not_guessed(self):
        for item in [{'UnitPrice':1},{'ChargeUnit':'DAY','UnitPrice':1},hourly('-1'),hourly('NaN')]:
            result=self.estimate(quote(item))
            self.assertIsNone(result['EstimatedTotal'])

    def test_response_wrapper_and_cli_are_supported(self):
        result=subprocess.run([sys.executable,str(HELPER),'--charge-type','POSTPAID_BY_HOUR','--internet-charge-type','NONE','--currency','CNY','--budget','100'],input=json.dumps({'Response':quote(hourly('.1'))}),text=True,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)
        data=json.loads(result.stdout)
        self.assertEqual(data['EstimatedTotal'],72)
        self.assertEqual(data['Currency'],'CNY')
        self.assertFalse(data['GuaranteedCap'])

    def test_invalid_input_is_nonzero(self):
        for data in ['{"Error":{"Code":"AuthFailure"}}','{"Price":{"InstancePrice":{"UnitPrice":NaN}}}','[]']:
            result=subprocess.run([sys.executable,str(HELPER),'--charge-type','POSTPAID_BY_HOUR'],input=data,text=True,capture_output=True)
            self.assertNotEqual(result.returncode,0)
            self.assertEqual(result.stdout,'')


FAKE_RECOMMEND = r'''
import json, os, sys
args=sys.argv[1:]
with open(os.environ['TEST_CALLS'],'a') as stream: stream.write(json.dumps(args)+'\n')
action=args[1]
def quote_request():
    value=args[args.index('--cli-input-json')+1]
    assert value.startswith('file://'), 'tccli requires a file:// request'
    path=value[7:]
    assert os.stat(path).st_mode & 0o077 == 0, 'request file must be private'
    with open(path) as stream: return json.load(stream)
if action==os.environ.get('TEST_FAILURE_ACTION'):
    instance_type=args[args.index('--InstanceType')+1] if action=='DescribeImages' else quote_request()['InstanceType']
    if instance_type==os.environ.get('TEST_FAILURE_TYPE','A1.SMALL2'):
        if os.environ.get('TEST_FAILURE_FORMAT')=='stderr':
            print(os.environ.get('TEST_FAILURE_CODE','connection timeout'),file=sys.stderr)
        else:
            error={'Error':{'Code':os.environ.get('TEST_FAILURE_CODE','ResourcesSoldOut.SpecifiedInstanceType'),'Message':'fixture error'},'RequestId':'req-failed-candidate'}
            print(json.dumps({'Response':error} if os.environ.get('TEST_FAILURE_FORMAT')=='wrapped' else error))
        raise SystemExit(int(os.environ.get('TEST_FAILURE_EXIT','0')))
if action=='DescribeZones':
    response={'ZoneSet':[{'Zone':'ap-guangzhou-1','ZoneState':'AVAILABLE'},{'Zone':'ap-guangzhou-2','ZoneState':'AVAILABLE'}]}
elif action=='DescribeZoneInstanceConfigInfos':
    filters=json.loads(args[args.index('--Filters')+1])
    charge=next(f['Values'][0] for f in filters if f['Name']=='instance-charge-type')
    response={'InstanceTypeQuotaSet':[
      {'Zone':'ap-guangzhou-1','InstanceType':'A1.SMALL2','Cpu':1,'Memory':2,'Status':'SELL','Gpu':0},
      {'Zone':'ap-guangzhou-2','InstanceType':'B1.MEDIUM4','Cpu':2,'Memory':4,'Status':'SELL','Gpu':0},
      {'Zone':'ap-guangzhou-2','InstanceType':'G1.MEDIUM4','Cpu':4,'Memory':8,'Status':'SELL','Gpu':0,'GpuCount':0.5}]}
    for item in response['InstanceTypeQuotaSet']: item['InstanceChargeType']=charge
    if os.environ.get('TEST_MIXED_BILLING_STOCK'):
        other='PREPAID' if charge=='POSTPAID_BY_HOUR' else 'POSTPAID_BY_HOUR'
        response['InstanceTypeQuotaSet'].append({'Zone':'ap-guangzhou-1','InstanceType':'A0.WRONG2','Cpu':1,'Memory':2,'Status':'SELL','Gpu':0,'InstanceChargeType':other})
elif action=='DescribeImages':
    instance_type=args[args.index('--InstanceType')+1]
    empty=os.environ.get('TEST_NO_IMAGE')=='all' or (os.environ.get('TEST_NO_IMAGE')=='first' and instance_type=='A1.SMALL2')
    response={'ImageSet':[] if empty else [{'ImageId':'img-'+instance_type.split('.')[0],'ImageState':'NORMAL','CreatedTime':'2026-01-01','ImageSize':50}]}
    if 'TEST_IMAGES' in os.environ:
        response={'ImageSet':json.loads(os.environ['TEST_IMAGES'])}
elif action=='InquiryPriceRunInstances':
    request=quote_request()
    with open(os.environ['TEST_REQUESTS'],'a') as stream: stream.write(json.dumps(request)+'\n')
    rate=0.2 if request['InstanceType']=='A1.SMALL2' else 0.01
    response={'Price':{'InstancePrice':{'ChargeUnit':'HOUR','UnitPrice':rate}},'RequestId':'req-quote'}
    period=request.get('InstanceChargePrepaid',{}).get('Period')
    if request['InstanceChargeType']=='PREPAID':
        amount=(60 if request['InstanceType']=='A1.SMALL2' else 50)*period
        response['Price']['InstancePrice']={'OriginalPrice':amount*2,'DiscountPrice':amount}
    internet=request['InternetAccessible']
    if internet['PublicIpAssigned']:
        mode=internet['InternetChargeType']
        if mode=='TRAFFIC_POSTPAID_BY_HOUR': network={'ChargeUnit':'GB','UnitPrice':0.8}
        elif mode=='BANDWIDTH_POSTPAID_BY_HOUR':
            network_rate=internet['InternetMaxBandwidthOut']*0.01
            if os.environ.get('TEST_NETWORK_PRICE_BY_TYPE'):
                network_rate=0.001 if request['InstanceType']=='A1.SMALL2' else 0.3
            network={'ChargeUnit':'HOUR','UnitPrice':network_rate}
        elif mode=='BANDWIDTH_PREPAID': network={'DiscountPrice':internet['InternetMaxBandwidthOut']*10*period}
        else: raise SystemExit('Unexpected network mode: '+mode)
        response['Price']['BandwidthPrice']=network
else:
    raise SystemExit('Unexpected cloud mutation: '+action)
print(json.dumps(response))
'''


class RecommendationPricingTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path=Path(self.temp.name)
        self.bin=self.path/'bin'; self.bin.mkdir()
        fake=self.bin/'tccli'
        fake.write_text('#!'+sys.executable+'\n'+FAKE_RECOMMEND); fake.chmod(0o755)
        self.calls=self.path/'calls'
        self.requests=self.path/'requests'
        self.env={'PATH':str(self.bin)+os.pathsep+os.environ['PATH'],'HOME':str(self.path),
                  'TEST_CALLS':str(self.calls),'TEST_REQUESTS':str(self.requests),'TENCENT_CVM_PROFILE':'test'}

    def recommend(self,*args,**env):
        return subprocess.run(['/bin/bash',str(ROOT/'scripts/lifecycle/recommend-instance.sh'),
            '--scene','blog-small','--json',*args],env={**self.env,**env},capture_output=True,text=True,timeout=20)

    def test_cheapest_actual_quote_beats_smallest_cpu_and_meets_known_budget(self):
        result=self.recommend('--budget','100','--currency','CNY')
        self.assertEqual(result.returncode,0,result.stderr)
        plans=json.loads(result.stdout)['Plans']
        self.assertTrue(all(p['Config']['InstanceType']=='B1.MEDIUM4' for p in plans))
        self.assertTrue(all(p['CostEstimate']['Budget']['Status']=='WithinEstimate' for p in plans))
        self.assertTrue(all(p['Config']['Placement']['Zone']=='ap-guangzhou-2' for p in plans))
        self.assertTrue(all(p['Config']['SystemDisk']['DiskSize']>=50 for p in plans))
        calls=[json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertTrue(all(c[1].startswith(('Describe','Inquiry')) for c in calls))
        self.assertFalse(any('G1.MEDIUM4' in c for c in calls))

    def test_budget_without_confirmed_currency_remains_unknown(self):
        result=self.recommend('--budget','100')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertTrue(all(p['CostEstimate']['Budget']['Status']=='Unknown' for p in json.loads(result.stdout)['Plans']))

    def test_prepaid_fixed_bandwidth_quotes_whole_period_and_monthly_cost(self):
        result=self.recommend('--charge-type','PREPAID','--period','3','--public-ip','--bandwidth','2',
                              '--internet-charge-type','BANDWIDTH_PREPAID','--budget','100','--currency','CNY',
                              TEST_MIXED_BILLING_STOCK='1')
        self.assertEqual(result.returncode,0,result.stderr)
        data=json.loads(result.stdout)
        self.assertEqual((data['ChargeType'],data['PeriodMonths']),('PREPAID',3))
        for plan in data['Plans']:
            self.assertEqual(plan['Config']['InstanceChargePrepaid'],{'Period':3,'RenewFlag':'NOTIFY_AND_MANUAL_RENEW'})
            self.assertEqual(plan['Config']['InternetAccessible'],{'PublicIpAssigned':True,'InternetMaxBandwidthOut':2,'InternetChargeType':'BANDWIDTH_PREPAID'})
            self.assertEqual(plan['CostEstimate']['EstimatedTotal'],210)
            self.assertEqual(plan['CostEstimate']['MonthlyAverage'],70)
            self.assertEqual(plan['CostEstimate']['Budget']['Status'],'WithinEstimate')
        calls=[json.loads(line) for line in self.calls.read_text().splitlines()]
        stock_call=next(c for c in calls if c[1]=='DescribeZoneInstanceConfigInfos')
        self.assertIn({'Name':'instance-charge-type','Values':['PREPAID']},json.loads(stock_call[stock_call.index('--Filters')+1]))
        self.assertFalse(any('A0.WRONG2' in c for c in calls))
        requests=[json.loads(line) for line in self.requests.read_text().splitlines()]
        self.assertTrue(all(r['InstanceChargeType']=='PREPAID' and r['InstanceChargePrepaid']['Period']==3 for r in requests))
        self.assertTrue(all(r['InternetAccessible']['InternetChargeType']=='BANDWIDTH_PREPAID' for r in requests))
        self.assertTrue(all(c[1].startswith(('Describe','Inquiry')) for c in calls))

    def test_hourly_fixed_bandwidth_is_included_without_traffic_assumption(self):
        result=self.recommend('--public-ip','--internet-charge-type','BANDWIDTH_POSTPAID_BY_HOUR',
                              '--hours','744','--budget','100','--currency','CNY')
        self.assertEqual(result.returncode,0,result.stderr)
        for plan in json.loads(result.stdout)['Plans']:
            self.assertEqual(plan['Config']['InstanceChargeType'],'POSTPAID_BY_HOUR')
            self.assertNotIn('InstanceChargePrepaid',plan['Config'])
            self.assertEqual(plan['Config']['InternetAccessible']['InternetMaxBandwidthOut'],5)
            self.assertEqual(plan['CostEstimate']['EstimatedTotal'],44.64)
            self.assertEqual(plan['CostEstimate']['Budget']['Status'],'WithinEstimate')

    def test_network_quote_can_change_the_selected_candidate(self):
        result=self.recommend('--public-ip','--internet-charge-type','BANDWIDTH_POSTPAID_BY_HOUR',
                              TEST_NETWORK_PRICE_BY_TYPE='1')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(json.loads(result.stdout)['Plans'][0]['Config']['InstanceType'],'A1.SMALL2')

    def test_public_traffic_without_usage_is_unknown_and_explicit_usage_is_estimated(self):
        args=('--public-ip','--budget','1000','--currency','CNY')
        missing=self.recommend(*args)
        self.assertEqual(missing.returncode,0,missing.stderr)
        for plan in json.loads(missing.stdout)['Plans']:
            self.assertEqual(plan['CostEstimate']['Budget']['Status'],'Unknown')
            self.assertIsNone(plan['CostEstimate']['EstimatedTotal'])
        known=self.recommend(*args,'--traffic-gb','10')
        self.assertEqual(known.returncode,0,known.stderr)
        for plan in json.loads(known.stdout)['Plans']:
            self.assertEqual(plan['CostEstimate']['EstimatedTotal'],15.2)
            self.assertEqual(plan['CostEstimate']['Budget']['Status'],'WithinEstimate')

    def test_invalid_billing_configuration_stops_before_cloud_queries(self):
        cases=[('--charge-type','PREPAID'),('--period','1'),('--charge-type','SPOTPAID'),
               ('--charge-type','PREPAID','--period','13'),('--charge-type','PREPAID','--period','0'),
               ('--public-ip','--internet-charge-type','BANDWIDTH_PREPAID'),
               ('--charge-type','PREPAID','--period','1','--public-ip','--internet-charge-type','BANDWIDTH_POSTPAID_BY_HOUR'),
               ('--public-ip','--internet-charge-type','BANDWIDTH_PACKAGE'),
               ('--internet-charge-type','BANDWIDTH_POSTPAID_BY_HOUR'),('--bandwidth','1'),('--traffic-gb','10'),
               ('--public-ip','--bandwidth','0'),('--public-ip','--bandwidth','5.5')]
        for args in cases:
            with self.subTest(args=args):
                result=self.recommend(*args)
                self.assertNotEqual(result.returncode,0)
                self.assertEqual(result.stdout,'')
                self.assertFalse(self.calls.exists())

    def test_candidate_without_compatible_image_does_not_hide_usable_candidate(self):
        result=self.recommend(TEST_NO_IMAGE='first')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertTrue(all(p['Config']['InstanceType']=='B1.MEDIUM4' for p in json.loads(result.stdout)['Plans']))

    def test_unknown_image_creation_times_preserve_api_order(self):
        cases=[(None,None),('missing','missing'),(None,'2026-03-01T00:00:00Z'),
               ('2026-01-01T00:00:00Z','not-a-date')]
        for first,second in cases:
            with self.subTest(times=(first,second)):
                images=[{'ImageId':'img-first','ImageState':'NORMAL','ImageSize':50},
                        {'ImageId':'img-second','ImageState':'NORMAL','ImageSize':50}]
                for image,created in zip(images,(first,second)):
                    if created!='missing': image['CreatedTime']=created
                result=self.recommend('--candidate-limit','1',TEST_IMAGES=json.dumps(images))
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertTrue(all(p['Config']['ImageId']=='img-first' for p in json.loads(result.stdout)['Plans']))

    def test_comparable_image_creation_times_select_newest_with_stable_ties(self):
        images=[{'ImageId':'img-old','ImageState':'NORMAL','CreatedTime':'2025-01-01T00:00:00Z','ImageSize':50},
                {'ImageId':'img-new-first','ImageState':'NORMAL','CreatedTime':'2026-01-01T00:00:00Z','ImageSize':50},
                {'ImageId':'img-new-second','ImageState':'NORMAL','CreatedTime':'2026-01-01T00:00:00Z','ImageSize':50},
                {'ImageId':'img-deprecated','ImageState':'NORMAL','CreatedTime':'2027-01-01T00:00:00Z','ImageDeprecated':True},
                {'ImageId':'img-not-ready','ImageState':'CREATING','CreatedTime':None}]
        result=self.recommend('--candidate-limit','1',TEST_IMAGES=json.dumps(images))
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertTrue(all(p['Config']['ImageId']=='img-new-first' for p in json.loads(result.stdout)['Plans']))
        requests=[json.loads(line) for line in self.requests.read_text().splitlines()]
        self.assertTrue(all(request['ImageId']=='img-new-first' for request in requests))

    def test_explicit_image_id_cannot_be_replaced_by_a_newer_returned_image(self):
        images=[{'ImageId':'img-other','ImageState':'NORMAL','CreatedTime':'2026-01-01T00:00:00Z','ImageSize':50},
                {'ImageId':'img-requested','ImageState':'NORMAL','CreatedTime':'2025-01-01T00:00:00Z','ImageSize':50}]
        result=self.recommend('--candidate-limit','1','--image-id','img-requested',TEST_IMAGES=json.dumps(images))
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertTrue(all(p['Config']['ImageId']=='img-requested' for p in json.loads(result.stdout)['Plans']))
        image_calls=[json.loads(line) for line in self.calls.read_text().splitlines() if json.loads(line)[1]=='DescribeImages']
        self.assertTrue(image_calls)
        for call in image_calls:
            self.assertEqual(json.loads(call[call.index('--ImageIds')+1]),['img-requested'])
            self.assertNotIn('--Filters',call)
        self.calls.unlink()
        self.requests.unlink()
        missing=self.recommend('--candidate-limit','1','--image-id','img-requested',TEST_IMAGES=json.dumps(images[:1]))
        self.assertNotEqual(missing.returncode,0)
        self.assertFalse(self.requests.exists())

    def test_structured_candidate_price_failure_is_recorded_and_skipped(self):
        result=self.recommend(TEST_FAILURE_ACTION='InquiryPriceRunInstances',TEST_FAILURE_EXIT='1',TEST_FAILURE_FORMAT='wrapped')
        self.assertEqual(result.returncode,0,result.stderr)
        data=json.loads(result.stdout)
        self.assertTrue(all(p['Config']['InstanceType']=='B1.MEDIUM4' for p in data['Plans']))
        self.assertTrue(data['CandidateErrors'])
        self.assertTrue(all(e['Code']=='ResourcesSoldOut.SpecifiedInstanceType' and e['RequestId']=='req-failed-candidate' and e['Action']=='InquiryPriceRunInstances' for e in data['CandidateErrors']))

    def test_structured_candidate_image_failure_is_skipped(self):
        result=self.recommend(TEST_FAILURE_ACTION='DescribeImages',TEST_FAILURE_CODE='InvalidParameterValue.InstanceTypeNotFound')
        self.assertEqual(result.returncode,0,result.stderr)
        data=json.loads(result.stdout)
        self.assertTrue(all(p['Config']['InstanceType']=='B1.MEDIUM4' for p in data['Plans']))
        self.assertTrue(all(e['Action']=='DescribeImages' for e in data['CandidateErrors']))

    def test_auth_permission_and_unknown_parameter_errors_stop_all_candidates(self):
        for code in ['AuthFailure.TokenFailure','UnauthorizedOperation.PermissionDenied','InvalidParameterCombination','UnsupportedOperation']:
            with self.subTest(code=code):
                self.calls.unlink(missing_ok=True)
                result=self.recommend(TEST_FAILURE_ACTION='DescribeImages',TEST_FAILURE_CODE=code)
                self.assertNotEqual(result.returncode,0)
                self.assertEqual(result.stdout,'')
                calls=[json.loads(line) for line in self.calls.read_text().splitlines()]
                self.assertEqual(sum(c[1]=='DescribeImages' for c in calls),1)
                self.assertFalse(any(c[1]=='InquiryPriceRunInstances' for c in calls))

    def test_unstructured_error_text_is_not_treated_as_candidate_error(self):
        result=self.recommend(TEST_FAILURE_ACTION='DescribeImages',TEST_FAILURE_FORMAT='stderr',TEST_FAILURE_CODE='ResourcesSoldOut.SpecifiedInstanceType',TEST_FAILURE_EXIT='7')
        self.assertEqual(result.returncode,7,result.stderr)
        self.assertEqual(result.stdout,'')
        calls=[json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertEqual(sum(c[1]=='DescribeImages' for c in calls),1)

    def test_candidate_pool_and_invalid_hours_are_bounded(self):
        result=self.recommend('--candidate-limit','21')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(self.calls.exists())
        result=self.recommend('--hours','NaN')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(self.calls.exists())


if __name__=='__main__':
    unittest.main()
