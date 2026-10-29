#!/usr/bin/env python3
"""Compare baseline/overlap CoreMark reports with identical images and platform settings."""
import argparse
import json
from pathlib import Path

def compare(base, opt, allow_short=False):
    for report in (base,opt):
        cm=report.get('benchmark',{})
        if cm.get('name')!='CoreMark' or not cm.get('crc_pass'):
            raise ValueError('both inputs must have passing CoreMark CRCs')
        if not allow_short and not cm.get('timing_qualified'):
            raise ValueError('run each benchmark for >=10 seconds; short RTL runs are not scores')
        if not cm.get('iterations') or not cm.get('ticks_us'):
            raise ValueError('invalid benchmark duration or iteration count')
        if report['metadata']['status']!=4 or report['metadata']['return']!=0:
            raise ValueError('main did not complete successfully')
    if not base.get('mem_sha256') or base['mem_sha256']!=opt.get('mem_sha256'):
        raise ValueError('use the same firmware image for baseline and modified hardware')
    for key in ('core_hz','ic_bytes','dc_bytes','l2_bytes'):
        if base['metadata'][key]!=opt['metadata'][key]:
            raise ValueError('platform configuration differs: '+key)
    a,b=base['metadata'].get('features'),opt['metadata'].get('features')
    if a is None or b is None or a&3 or not b&1 or a^b not in (1,3):
        raise ValueError('hardware flags must differ only in fetch configuration: OFF -> overlap/three slots')
    aa,bb=base['benchmark'],opt['benchmark']
    if (aa['data_size'],aa['run_kind']) != (bb['data_size'],bb['run_kind']):
        raise ValueError('CoreMark seed/data configurations differ')
    a_us=aa['ticks_us']/aa['iterations']
    b_us=bb['ticks_us']/bb['iterations']
    return {'timing_qualified':aa['timing_qualified'] and bb['timing_qualified'],
            'baseline_us_per_iteration':a_us,'overlap_us_per_iteration':b_us,
            'kernel_speedup':a_us/b_us,
            'time_reduction_percent':100*(1-b_us/a_us),
            'baseline_main_cpi':base['metrics']['cpi'],'overlap_main_cpi':opt['metrics']['cpi'],
            'image_sha256':base['mem_sha256'],
            'note':'Iterations are normalized because automatic calibration may choose different counts. Main includes calibration and UART; benchmark score uses only its timed kernel.'}

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('baseline',type=Path);ap.add_argument('overlap',type=Path)
    ap.add_argument('--allow-short',action='store_true',help='analysis only, never an official score')
    ap.add_argument('--output',type=Path)
    args=ap.parse_args()
    result=compare(json.loads(args.baseline.read_text()),json.loads(args.overlap.read_text()),args.allow_short)
    text=json.dumps(result,indent=2)+'\n'
    print(text,end='')
    if args.output:args.output.write_text(text)
    return 0

if __name__=='__main__':
    try:raise SystemExit(main())
    except (OSError,ValueError,KeyError) as exc:raise SystemExit('COREMARK COMPARE ERROR: '+str(exc))
