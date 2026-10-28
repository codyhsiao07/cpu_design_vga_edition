#!/usr/bin/env python3
"""A/B full-SoC CRC validation of official CoreMark (short runs, no official score)."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import subprocess
import sys
from build_coremark import build
from run_perf import parse_report, save_report
from run_perf_verification import run, ROOT

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--skip-build',action='store_true')
    ap.add_argument('--seeds',type=int,default=1)
    ap.add_argument('--jobs',type=int,default=2)
    ap.add_argument('--kind',choices=['performance','validation','both'],default='both')
    ap.add_argument('--out-dir',type=Path,default=ROOT/'build_perf/coremark_ab')
    args=ap.parse_args()
    if args.seeds<0 or args.jobs<1: ap.error('invalid seeds/jobs')
    out=args.out_dir.resolve();out.mkdir(parents=True,exist_ok=True)
    kinds=['performance','validation'] if args.kind=='both' else [args.kind]
    if not args.skip_build:
        for kind in kinds:build(kind,1)
    sources=sorted(ROOT.glob('*.v'))
    for variant in ['baseline','fetch_overlap']:
        definitions=['-DSYNTHESIS','-DFAST_SIM']
        if variant=='fetch_overlap':definitions+=['-DPERF_FETCH_OVERLAP']
        run(['iverilog','-g2005-sv',*definitions,'-i','-s','performance_system_tb',
             '-o',out/f'{variant}.out',*sources],out/f'compile_{variant}.log')
    def execute(job):
        kind,variant,seed=job
        prefix=out/f'{kind}_{variant}_s{seed}'
        image=ROOT/f'build_perf/coremark_{kind}_1.mem'
        run(['vvp',out/f'{variant}.out','+TEST=0',f'+MEMFILE=build_perf/coremark_{kind}_1.mem',
             '+ASSERT_EN=1','+MAXCYCLES=20000000',f'+RAND_MEM={int(seed!=0)}',f'+SEED={seed}',
             '+RAND_BP_PCT=20','+RAND_I_MAX=9','+RAND_D_MAX=9',
             f'+PERF_TRACE={prefix}.trace',f'+PERF_UART={prefix}.uart.txt'],
             Path(str(prefix)+'.log'),'PASS: performance_system_tb',timeout=900)
        report=parse_report(Path(str(prefix)+'.uart.txt').read_text(encoding='ascii'))
        cm=report.get('benchmark',{})
        assert report['metadata']['return']==0 and cm.get('crc_pass'),prefix
        assert report['metadata'].get('features')==int(variant=='fetch_overlap'),prefix
        assert cm['run_kind']==int(kind=='validation') and cm['iterations']==1,prefix
        assert not cm['timing_qualified'] and cm['iterations_per_second'] is None,prefix
        report.update(program='CoreMark '+kind,hardware_variant=variant,validation='CRC PASS (short run)',
                      seed=seed,mem_sha256=hashlib.sha256(image.read_bytes()).hexdigest())
        save_report(report,prefix)
        print(f"PASS {kind} {variant} seed={seed}: CRCs correct, kernel={cm['ticks_us']} us, main={report['counters']['cycles']} cycles",flush=True)
        return {'kind':kind,'variant':variant,'seed':seed,'kernel_us':cm['ticks_us'],
                'cycles':report['counters']['cycles'],'instructions':report['counters']['instructions'],
                'image_sha256':report['mem_sha256']}
    jobs=[(kind,variant,seed) for kind in kinds
          for seed in range(args.seeds+1) for variant in ['baseline','fetch_overlap']]
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        rows=list(pool.map(execute,jobs))
    comparisons=[]
    for kind in kinds:
        for seed in range(args.seeds+1):
            base=next(row for row in rows if row['kind']==kind and row['seed']==seed and row['variant']=='baseline')
            opt=next(row for row in rows if row['kind']==kind and row['seed']==seed and row['variant']=='fetch_overlap')
            assert base['image_sha256']==opt['image_sha256']
            comparisons.append({'kind':kind,'seed':seed,'baseline_us':base['kernel_us'],
                                'overlap_us':opt['kernel_us'],
                                'kernel_speedup':base['kernel_us']/opt['kernel_us'],
                                'kernel_time_reduction_percent':100*(1-opt['kernel_us']/base['kernel_us'])})
    summary={'short_validation_only':True,'runs':rows,'comparisons':comparisons}
    (out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    for row in comparisons:print('A/B '+json.dumps(row),flush=True)
    print(f'PASS: {len(rows)} CoreMark full-system CRC runs; {out}',flush=True)
    return 0

if __name__=='__main__':
    try:raise SystemExit(main())
    except (OSError,ValueError,AssertionError,subprocess.SubprocessError,RuntimeError) as exc:
        print(f'COREMARK VERIFICATION FAILED: {exc}',file=sys.stderr);raise SystemExit(1)
