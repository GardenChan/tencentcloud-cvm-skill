#!/usr/bin/env python3
"""Explain an InquiryPriceRunInstances quote without inventing a bill or currency.

Read flat or Response-wrapped API JSON on stdin. --budget means the budget for
--hours of POSTPAID usage (default 720 hours, explicitly 30 continuous days), or
the average monthly fixed cost for PREPAID with an explicit --period. Variable
traffic never becomes a spending cap. Decimal arithmetic follows ItemPrice's
0–96 / 96–360 / >360 hour tiers. Source verified 2026-11-08:
https://cloud.tencent.com/document/product/213/15753 (ItemPrice and Price)
https://cloud.tencent.com/document/product/213/15726 (InquiryPriceRunInstances)
"""
import argparse
from decimal import Decimal, InvalidOperation
import json
import re
import sys

ZERO = Decimal(0)
SOURCE = 'https://cloud.tencent.com/document/product/213/15753'


def number(value, label, *, positive=False):
    if isinstance(value, bool) or value is None:
        raise ValueError(f'{label} must be a finite non-negative number')
    try:
        result = Decimal(str(value))
    except InvalidOperation:
        raise ValueError(f'{label} must be numeric') from None
    if not result.is_finite() or result < 0 or (positive and result <= 0):
        raise ValueError(f'{label} must be a finite {"positive" if positive else "non-negative"} number')
    return result


def choose(item, discounted, original):
    for field in (discounted, original):
        if item.get(field) is not None:
            return number(item[field], field), field
    raise ValueError(f'missing {discounted} / {original}')


def unknown(name, reason, item=None):
    return {'Name': name, 'Status': 'Unknown', 'Amount': None, 'Reason': reason,
            'BillingUnit': item.get('ChargeUnit') if isinstance(item, dict) else None}


def hourly(name, item, hours):
    if not isinstance(item, dict):
        return unknown(name, 'Price component was not returned')
    if item.get('ChargeUnit') != 'HOUR':
        return unknown(name, 'An explicit HOUR unit is required for an hourly estimate', item)
    fields = [('UnitPriceDiscount', 'UnitPrice'),
              ('UnitPriceDiscountSecondStep', 'UnitPriceSecondStep'),
              ('UnitPriceDiscountThirdStep', 'UnitPriceThirdStep')]
    tiered = any(item.get(field) is not None for pair in fields[1:] for field in pair)
    portions = [min(hours, Decimal(96)), max(ZERO, min(hours, Decimal(360)) - 96), max(ZERO, hours - 360)] if tiered else [hours]
    segments = []
    try:
        for index, duration in enumerate(portions):
            if duration == 0:
                continue
            rate, field = choose(item, *fields[index])
            segments.append({'Hours': duration, 'UnitPrice': rate, 'RateField': field, 'Amount': duration * rate})
    except ValueError as error:
        return unknown(name, f'Cannot price the requested duration: {error}', item)
    amount = sum((segment['Amount'] for segment in segments), ZERO)
    return {'Name': name, 'Status': 'Estimated', 'Amount': amount,
            'BillingUnit': 'HOUR', 'Hours': hours, 'Segments': segments}


def prepaid(name, item, period):
    if period is None:
        return unknown(name, 'PREPAID needs the quoted purchase --period in months', item)
    if not isinstance(item, dict):
        return unknown(name, 'Price component was not returned')
    try:
        rate, field = choose(item, 'DiscountPrice', 'OriginalPrice')
    except ValueError as error:
        return unknown(name, str(error), item)
    return {'Name': name, 'Status': 'Estimated', 'Amount': rate,
            'BillingUnit': 'PURCHASE_PERIOD', 'PeriodMonths': period, 'RateField': field,
            'MonthlyAverage': rate / period}


def traffic(item, gigabytes):
    if not isinstance(item, dict):
        return unknown('Network', 'BandwidthPrice was not returned')
    if item.get('ChargeUnit') != 'GB':
        return unknown('Network', 'Traffic billing requires GB; quote unit conflicts with the requested billing mode', item)
    if gigabytes is None:
        return unknown('Network', 'Traffic volume is unknown; provide --traffic-gb for a scenario estimate', item)
    # Time tier fields in a GB quote are not hourly discounts. Nonzero tiers are
    # ambiguous without a vendor rule defining how GB and duration interact.
    if any(item.get(k) is not None and number(item[k], k) != 0 for k in
           ('UnitPriceSecondStep','UnitPriceDiscountSecondStep','UnitPriceThirdStep','UnitPriceDiscountThirdStep')):
        return unknown('Network', 'Nonzero time tiers on a GB quote need provider clarification', item)
    try:
        rate, field = choose(item, 'UnitPriceDiscount', 'UnitPrice')
    except ValueError as error:
        return unknown('Network', str(error), item)
    return {'Name':'Network', 'Status':'Estimated', 'Amount':rate * gigabytes,
            'BillingUnit':'GB', 'AssumedTrafficGB':gigabytes, 'UnitPrice':rate,
            'RateField':field, 'UsageDependent':True}


def estimate(payload, *, charge_type, hours=Decimal(720), period=None,
             internet_charge_type=None, traffic_gb=None, currency=None,
             budget=None, budget_currency=None):
    if not isinstance(payload, dict):
        raise ValueError('Expected an API response object')
    payload = payload.get('Response', payload)
    if not isinstance(payload, dict) or payload.get('Error'):
        raise ValueError('Cannot estimate an API error response')
    price = payload.get('Price')
    if not isinstance(price, dict):
        raise ValueError('Response must contain a Price object')
    hours = number(hours, 'hours', positive=True)
    if period is not None:
        period = number(period, 'period', positive=True)
        if period != period.to_integral_value():
            raise ValueError('period must be an integer month count')
    if traffic_gb is not None:
        traffic_gb = number(traffic_gb, 'traffic-gb')
    if budget is not None:
        budget = number(budget, 'budget')
    for label, value in [('currency',currency),('budget-currency',budget_currency)]:
        if value is not None and not re.fullmatch('[A-Z]{3}',value):
            raise ValueError(f'{label} must be an explicit three-letter currency code')
    instance = (prepaid('Instance', price.get('InstancePrice'), period) if charge_type == 'PREPAID'
                else hourly('Instance', price.get('InstancePrice'), hours))
    if internet_charge_type == 'NONE':
        network = {'Name':'Network','Status':'Excluded','Amount':ZERO,'Reason':'Caller explicitly specified no public network in the quoted configuration'}
    elif internet_charge_type == 'TRAFFIC_POSTPAID_BY_HOUR':
        network = traffic(price.get('BandwidthPrice'), traffic_gb)
    elif internet_charge_type == 'BANDWIDTH_POSTPAID_BY_HOUR':
        network = hourly('Network', price.get('BandwidthPrice'), hours)
    elif internet_charge_type == 'BANDWIDTH_PREPAID':
        network = prepaid('Network', price.get('BandwidthPrice'), period)
    else:
        network = unknown('Network','The configured InternetChargeType is unknown; do not infer it from a sample response',price.get('BandwidthPrice'))
    # Up-front period fees cannot be added to a 720h/GB scenario as if they all
    # covered one month. Preserve the variable estimate separately instead.
    if charge_type == 'PREPAID' and internet_charge_type in ('TRAFFIC_POSTPAID_BY_HOUR','BANDWIDTH_POSTPAID_BY_HOUR'):
        scenario = network
        network = unknown('Network','PREPAID fixed fees and usage charges cover different periods; usage is shown separately',price.get('BandwidthPrice'))
        network['UsageScenario'] = scenario
    if charge_type == 'POSTPAID_BY_HOUR' and internet_charge_type == 'BANDWIDTH_PREPAID':
        period_quote = network
        network = unknown('Network','Hourly instance costs and prepaid network fees cover different periods',price.get('BandwidthPrice'))
        network['PeriodQuote'] = period_quote
    components = [instance, network]
    known = [c['Amount'] for c in components if c['Amount'] is not None]
    subtotal = sum(known, ZERO) if known else None
    complete = all(c['Status'] != 'Unknown' for c in components)
    total = subtotal if complete else None
    average = total / period if charge_type == 'PREPAID' and period and total is not None else None
    comparable_amount = average if charge_type == 'PREPAID' else total
    known_comparable = subtotal / period if charge_type == 'PREPAID' and period and subtotal is not None else subtotal if charge_type != 'PREPAID' else None
    budget_currency = budget_currency or currency
    budget_result = {'Amount':budget,'Currency':budget_currency,
                     'Basis':'monthly_average_fixed_cost' if charge_type == 'PREPAID' else 'requested_hours',
                     'Status':'NotProvided','Comparable':False,'GuaranteedCap':False}
    if budget is not None:
        if not currency or not budget_currency:
            budget_result.update(Status='Unknown',Reason='Quote currency is not confirmed; no currency is assumed')
        elif currency != budget_currency:
            budget_result.update(Status='Unknown',Reason='Quote and budget currencies differ; no exchange rate is assumed')
        elif known_comparable is not None and known_comparable > budget:
            budget_result.update(Status='Exceeds',Comparable=True,ComparedAmount=known_comparable,
                                 Reason='Already exceeds budget using known components only')
        elif comparable_amount is not None:
            budget_result.update(Status='WithinEstimate',Comparable=True,ComparedAmount=comparable_amount,
                                 Reason='Within the supplied usage assumptions; this is not a spending cap')
        else:
            budget_result.update(Status='Unknown',Reason='One or more price or usage components cannot be estimated')
    omitted = ['Resources and services absent from this exact quote',
               'Future configuration changes, renewal prices, credits and promotions not represented in the quote']
    if not complete:
        omitted.extend(c['Name']+': '+c['Reason'] for c in components if c['Status']=='Unknown')
    return {'Status':'Estimated' if complete else 'Partial' if known else 'Unknown',
            'Currency':currency,'CurrencySource':'caller-confirmed' if currency else 'unconfirmed',
            'ChargeType':charge_type,'Hours':hours,'PrepaidPeriodMonths':period,
            'Components':components,'KnownSubtotal':subtotal,'EstimatedTotal':total,
            'MonthlyAverage':average,'Budget':budget_result,'GuaranteedCap':False,
            'Assumptions':['Hours represent continuous unchanged use; 720 hours means 30 days, not every calendar month',
                           'The API quote already covers its requested instance quantity; no second quantity multiplication',
                           'Configured disks and image are represented only to the extent included in InstancePrice; no separate disk price is invented',
                           'A returned zero price is not a guarantee of free service'],
            'NotIncludedOrUnknown':omitted,'Source':SOURCE,'RequestId':payload.get('RequestId')}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--charge-type',required=True,choices=['POSTPAID_BY_HOUR','PREPAID'])
    parser.add_argument('--hours',default='720')
    parser.add_argument('--period',help='Quoted PREPAID purchase months, required for PREPAID estimates')
    parser.add_argument('--internet-charge-type',choices=['NONE','TRAFFIC_POSTPAID_BY_HOUR','BANDWIDTH_POSTPAID_BY_HOUR','BANDWIDTH_PREPAID'])
    parser.add_argument('--traffic-gb',help='Scenario outbound GB for the --hours window; not a cap')
    parser.add_argument('--currency',help='Confirmed account quote currency; never inferred from region')
    parser.add_argument('--budget',help='Budget for --hours, or PREPAID monthly average')
    parser.add_argument('--budget-currency',help='Defaults to --currency if it is supplied')
    args = parser.parse_args()
    try:
        payload=json.load(sys.stdin,parse_float=Decimal,parse_constant=lambda value: (_ for _ in ()).throw(ValueError('Non-finite JSON number')))
        result=estimate(payload,**vars(args))
        print(json.dumps(result,ensure_ascii=False,allow_nan=False,default=lambda value:float(value) if isinstance(value,Decimal) else value))
    except (ValueError,TypeError,KeyError) as error:
        parser.exit(2,f'价格估算输入错误: {error}\n')


if __name__ == '__main__':
    main()
