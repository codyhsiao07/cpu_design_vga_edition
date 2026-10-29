#!/usr/bin/env python3
"""Directed three-slot cache/L2 tests; optional full CPU and CoreMark regressions."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
from run_perf_verification import ROOT, CASES, run


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--full',action='store_true',help='also run all CPU traces and CoreMark A/B CRC tests')
    ap.add_argument('--seeds',type=int,default=8)
    ap.add_argument('--out-dir',type=Path,default=ROOT/'build_perf/fetch_slots/regression')
    args=ap.parse_args()
    if args.seeds<1: ap.error('seeds must be positive')
    out=args.out_dir.resolve(); out.mkdir(parents=True,exist_ok=True)
    sources=[p.name for p in sorted(ROOT.glob('*.v')) if not p.stem.endswith('_tb')]
    sources.append('performance_system_tb.v')
    hashes={p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in sources}
    sim=out/'directed.out'
    run(['iverilog','-g2005-sv','-DFAST_SIM','-s','fetch_slots_tb','-o',sim,
         'tools/tb/fetch_slots_tb.v','icache.v','I_D_arbitration.v','L2_cache.v'],out/'compile.log')
    for seed in range(1,args.seeds+1):
        run(['vvp',sim,f'+SEED={seed}'],out/f'directed_s{seed}.log','PASS: fetch_slots_tb')
        print(f'PASS directed fetch/cache/L2 seed={seed}',flush=True)
    if args.full:
        run([sys.executable,'tools/run_perf_verification.py','--fetch-overlap','--seeds','2',
             '--out-dir',out/'cpu'],out/'cpu.log',f'PASS: {len(CASES)*3} full-system runs',timeout=7200)
        run([sys.executable,'tools/run_coremark_verification.py','--seeds','1','--out-dir',out/'coremark'],
            out/'coremark.log','PASS: 8 CoreMark',timeout=7200)
    if any(hashlib.sha256((ROOT/p).read_bytes()).hexdigest()!=h for p,h in hashes.items()):
        raise RuntimeError('RTL changed while verification was running')
    (out/'manifest.json').write_text(json.dumps({'rtl_sha256':hashes,'seeds':args.seeds,'full':args.full,
        'features':3,'slots':3},indent=2)+'\n',encoding='utf-8')
    return 0


if __name__=='__main__':
    raise SystemExit(main())
