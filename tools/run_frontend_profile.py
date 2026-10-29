#!/usr/bin/env python3
"""Observe baseline CoreMark frontend waits in TB; never modify CPU/cache RTL."""
import argparse
import csv
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import re
import subprocess

from run_perf import parse_report, save_report
from run_perf_verification import ROOT, run

CATEGORIES = ('hit_lookup_handoff', 'miss', 'backend', 'redirect')
POLICY = ('backend > redirect > miss > hit. Redirect includes cancelled-request work '
          'and recovery until the latest target response is accepted; miss is the '
          'eventual confirmed outcome, including its initial lookup cycles.')


def category_for_mask(mask, redirect_first=False):
    if redirect_first and mask & 2:
        return 'redirect'
    if mask & 1:
        return 'backend'
    if mask & 2:
        return 'redirect'
    return 'miss' if mask & 4 else 'hit_lookup_handoff'


def parse_profile(text):
    result = {'scopes': {}, 'clean_request_gap_histogram': {}, 'hit_availability_histogram': {}}
    seen = set()
    for line in text.splitlines():
        words = line.split()
        if not words:
            continue
        tag, *values = words
        values = [int(x) for x in values]
        keyed = tag in ('scope', 'category', 'joint', 'backend', 'redirects', 'gap', 'hit_latency')
        key = (tag, *values[:2 if tag in ('category', 'joint') else 1]) if keyed else (tag,)
        if key in seen or any(x < 0 for x in values):
            raise ValueError('duplicate/negative profile record: ' + line)
        seen.add(key)
        if tag in ('schema', 'iterations'):
            result[tag], = values
        elif tag == 'scope':
            s, cycles, instructions, frontend = values
            result['scopes'].setdefault(s, {}).update(cycles=cycles, instructions=instructions, frontend=frontend)
        elif tag in ('category', 'joint'):
            s, k, count = values
            scope = result['scopes'].setdefault(s, {})
            scope.setdefault(tag, {})[k] = count
        elif tag in ('backend', 'redirects'):
            s, *counts = values
            result['scopes'].setdefault(s, {})[tag] = counts
        elif tag == 'gap':
            k, count = values
            result['clean_request_gap_histogram'][k] = count
        elif tag == 'hit_latency':
            k, count = values
            result['hit_availability_histogram'][k] = count
        elif tag in ('requests', 'latencies'):
            result[tag] = values
        else:
            raise ValueError('unknown profile record: ' + line)
    if result.get('schema') != 1 or not result.get('iterations'):
        raise ValueError('unsupported/incomplete profile')
    n = result['iterations']
    if set(result['scopes']) != set(range(n + 2)):
        raise ValueError('missing scopes')
    for s, scope in result['scopes'].items():
        if set(scope.get('joint', {})) != set(range(16)) or set(scope.get('category', {})) != set(range(4)):
            raise ValueError('incomplete histogram')
        computed = {k: 0 for k in CATEGORIES}
        alternate = {k: 0 for k in CATEGORIES}
        for mask, count in scope['joint'].items():
            if mask > 15:
                raise ValueError('invalid mask')
            computed[category_for_mask(mask)] += count
            alternate[category_for_mask(mask, True)] += count
        supplied = dict(zip(CATEGORIES, (scope['category'][i] for i in range(4))))
        if computed != supplied or sum(computed.values()) != scope['frontend']:
            raise ValueError('exclusive categories do not exactly partition frontend_wait')
        if not 0 < scope['instructions'] <= scope['cycles'] or scope['frontend'] > scope['cycles']:
            raise ValueError('invalid scope counters')
        scope['name'] = 'main' if s == 0 else 'iterate_function' if s == 1 else f'iteration_{s-1}'
        scope['counts'] = computed
        scope['frontend_percent_of_cycles'] = 100 * scope['frontend'] / scope['cycles']
        scope['percent_of_frontend'] = {k: 100*v/scope['frontend'] if scope['frontend'] else 0 for k, v in computed.items()}
        scope['percent_of_cycles'] = {k: 100*v/scope['cycles'] for k, v in computed.items()}
        scope['redirect_first_counts'] = alternate
        scope['overlaps'] = {label: sum(count for mask,count in scope['joint'].items() if mask & bits == bits)
                             for label,bits in [('backend_any',1),('redirect_any',2),('miss_any',4),
                                               ('backend_and_redirect',3),('backend_and_miss',5),
                                               ('redirect_and_miss',6),('all_three',7),
                                               ('backend_with_available_response',9)]}
        scope['hit_without_response'] = scope['joint'][0]
        scope['hit_ready_handoff'] = scope['joint'][8]
        scope['cpi'] = scope['cycles']/scope['instructions']
    scopes = result['scopes']
    for key in ('cycles','instructions','frontend'):
        if scopes[1][key] > scopes[0][key] or sum(scopes[s][key] for s in range(2,n+2)) > scopes[1][key]:
            raise ValueError('nested scope counters exceed their parent')
    if (set(result['clean_request_gap_histogram']) != set(range(65)) or
        set(result['hit_availability_histogram']) != set(range(65)) or
        len(result.get('requests',[])) != 4 or len(result.get('latencies',[])) != 3):
        raise ValueError('incomplete request/latency records')
    return result


def rtl_hashes():
    return {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
            for p in ROOT.glob('*.v') if not p.stem.endswith('_tb')}


def toolchain_binary(name):
    config = subprocess.check_output(['make', '-s', 'print-config'], cwd=ROOT, text=True)
    folder = next(line.strip().strip('"').split('=',1)[1] for line in config.splitlines()
                  if line.strip().strip('"').startswith('TOOLCHAIN_BIN='))
    return str(Path(folder)/('riscv-none-elf-'+name))


def markers(elf):
    symbols = subprocess.check_output([toolchain_binary('nm'), '-n', str(elf)], text=True)
    kernel = next(int(words[0],16) for line in symbols.splitlines()
                  if len(words:=line.split())==3 and words[2]=='iterate')
    dis = subprocess.check_output([toolchain_binary('objdump'), '-d', '--disassemble=iterate', str(elf)], text=True)
    calls = re.findall(r'^\s*([0-9a-f]+):[^\n]*\b(?:jal|jalr)\b[^\n]*<core_bench_list>', dis, re.M)
    if len(calls) != 2:
        raise ValueError('expected two list calls in iterate; review disassembly before profiling')
    return kernel, int(calls[0],16), dis


def write_category_csv(profile, path):
    with path.open('w',newline='') as stream:
        writer=csv.writer(stream)
        writer.writerow(['kind','scope','category','cycles','percent_frontend','percent_scope_cycles'])
        for scope in profile['scopes'].values():
            for category in CATEGORIES:
                writer.writerow([profile['kind'],scope['name'],category,scope['counts'][category],
                                 scope['percent_of_frontend'][category],scope['percent_of_cycles'][category]])


def check_saved_configuration(summary, multiplier, iterations):
    if summary.get('multiplier') != multiplier:
        raise ValueError('output directory contains another multiplier configuration; use its matching --multiplier-ref or another --out-dir')
    if any(r['iterations'] != iterations for r in summary.get('runs', [])):
        raise ValueError('output directory contains another iteration count; use another --out-dir')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--iterations',type=int,default=3)
    ap.add_argument('--kind',choices=['performance','validation','both'],default='both')
    ap.add_argument('--seeds',type=int,default=0,help='random-backpressure seeds in addition to deterministic')
    ap.add_argument('--jobs',type=int,default=2)
    ap.add_argument('--skip-build',action='store_true')
    ap.add_argument('--analyze-only',action='store_true',help='re-read existing raw profiles/UART without simulation')
    ap.add_argument('--multiplier-ref',help='optional Git ref for isolated historical booth_multiplier.v; worktree is untouched')
    ap.add_argument('--timeout',type=int,default=1800)
    ap.add_argument('--out-dir',type=Path,default=ROOT/'build_perf/frontend_profile')
    args = ap.parse_args()
    if not 2 <= args.iterations <= 8 or args.jobs<1 or args.seeds<0 or args.timeout<=0:
        ap.error('use 2..8 iterations and positive jobs/timeout')
    out = args.out_dir.resolve();out.mkdir(parents=True,exist_ok=True)
    before = rtl_hashes()
    manifest = out/'rtl_sha256.json'
    if args.analyze_only:
        if json.loads(manifest.read_text()) != before:
            raise RuntimeError('current RTL differs from the recorded profiling RTL')
    else:
        manifest.write_text(json.dumps(before,indent=2)+'\n')
    sources=sorted(ROOT.glob('*.v'))
    multiplier={'variant':'current_worktree','sha256':before['booth_multiplier.v']}
    if args.multiplier_ref:
        commit=subprocess.check_output(['git','rev-parse',args.multiplier_ref],cwd=ROOT,text=True).strip()
        data=subprocess.check_output(['git','show',commit+':booth_multiplier.v'],cwd=ROOT)
        isolated=out/'historical_booth_multiplier.v'
        if args.analyze_only:
            if isolated.read_bytes()!=data:
                raise ValueError('historical source differs from the recorded isolated copy')
        else:
            isolated.write_bytes(data)
        sources=[p for p in sources if p.name!='booth_multiplier.v']+[isolated]
        multiplier={'variant':'historical_reference','git_commit':commit,'sha256':hashlib.sha256(data).hexdigest()}
    saved_summary=out/'summary.json'
    if saved_summary.exists():
        check_saved_configuration(json.loads(saved_summary.read_text()),multiplier,args.iterations)
    tb_files = ROOT/'tools/tb'
    if not args.analyze_only:
        run(['iverilog','-g2005-sv','-s','frontend_profile_monitor_tb','-o',out/'unit.out',
             tb_files/'frontend_profile_monitor.v',tb_files/'frontend_profile_monitor_tb.v'],out/'unit_compile.log')
        run(['vvp',out/'unit.out',f'+FRONTEND_PROFILE={out}/unit.profile.txt'],out/'unit.log',
            'PASS: frontend_profile_monitor_tb')
        print('PASS observer unit: independent hit/miss/overlap/redirect/boundary scenarios',flush=True)
    kinds = ['performance','validation'] if args.kind=='both' else [args.kind]
    images = {}
    for kind in kinds:
        image = ROOT/f'build_perf/coremark_{kind}_{args.iterations}.mem'
        if not args.skip_build and not args.analyze_only:
            with (out/f'build_{kind}.log').open('w') as log:
                # Builder retains originals; keep verbose make output in its log.
                subprocess.run(['python','tools/build_coremark.py','--kind',kind,'--iterations',str(args.iterations)],
                               cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,check=True)
        elf = ROOT/f'build_perf/coremark_{kind}_{args.iterations}/coremark_{kind}_{args.iterations}.elf'
        kernel, loop, dis = markers(elf)
        (out/f'iterate_{kind}.dis').write_text(dis)
        images[kind] = (image,kernel,loop)
    sim = out/'system.out'
    if not args.analyze_only:
        run(['iverilog','-g2005-sv','-DSYNTHESIS','-DFAST_SIM','-i','-s','coremark_frontend_tb',
             '-P',f'coremark_frontend_tb.ITERATIONS={args.iterations}','-o',sim,
             *sources,tb_files/'frontend_profile_monitor.v',tb_files/'coremark_frontend_tb.v'],
            out/'system_compile.log')
    def execute(job):
        kind,seed = job
        image,kernel,loop = images[kind]
        prefix = out/f'{kind}_s{seed}'
        image_digest=hashlib.sha256(image.read_bytes()).hexdigest()
        if args.analyze_only:
            previous=json.loads(Path(str(prefix)+'.profile.json').read_text())
            if previous['firmware_sha256'] != image_digest:
                raise ValueError('firmware no longer matches the captured profile')
        if not args.analyze_only:
            run(['vvp',sim,'+TEST=0',f'+MEMFILE={image.relative_to(ROOT).as_posix()}',
             '+ASSERT_EN=1',f'+MAXCYCLES={5_000_000+3_000_000*args.iterations}',
             f'+RAND_MEM={int(seed!=0)}',f'+SEED={seed}','+RAND_BP_PCT=20','+RAND_I_MAX=9','+RAND_D_MAX=9',
             f'+PERF_TRACE={prefix}.trace',f'+PERF_UART={prefix}.uart.txt',
             f'+KERNEL_PC={kernel:08x}',f'+LOOP_PC={loop:08x}',f'+FRONTEND_PROFILE={prefix}.profile.txt'],
                Path(str(prefix)+'.log'),'PASS: performance_system_tb',timeout=args.timeout)
        raw = Path(str(prefix)+'.profile.txt').read_text()
        profile = parse_profile(raw)
        report = parse_report(Path(str(prefix)+'.uart.txt').read_text(encoding='ascii'))
        cm = report['benchmark']
        if image_digest != hashlib.sha256(image.read_bytes()).hexdigest():
            raise ValueError('firmware changed during simulation')
        assert cm['crc_pass'] and cm['iterations']==args.iterations
        assert report['metadata']['features']==0 and report['metadata']['return']==0
        for field,pmu in [('cycles','cycles'),('instructions','instructions'),('frontend','frontend_wait')]:
            assert profile['scopes'][0][field]==report['counters'][pmu]
        profile.update(kind=kind,random_seed=seed,policy=POLICY,
                       multiplier=multiplier,
                       firmware_sha256=image_digest,
                       markers={'iterate_pc':hex(kernel),'first_list_call_pc':hex(loop)},
                       crc_pass=True,official_score=False,
                       note='Short RTL profiling; 100 MHz/2 Mbaud TB, modeled MIG, overlap OFF. No extrapolation to board 400 iterations.')
        Path(str(prefix)+'.profile.json').write_text(json.dumps(profile,indent=2)+'\n')
        write_category_csv(profile,Path(str(prefix)+'.profile.csv'))
        report.update(program=f'CoreMark {kind}',validation='CRC PASS (short TB profile)',
                      mem_sha256=profile['firmware_sha256'])
        save_report(report,prefix)
        print(f'PASS {kind} seed={seed}: CRC, exact frontend partition; multiplier={multiplier["variant"]}',flush=True)
        for scope in list(profile['scopes'].values())[:2]:
            print(f'  {scope["name"]}: frontend={scope["frontend"]}/{scope["cycles"]} ({scope["frontend_percent_of_cycles"]:.3f}%)',flush=True)
            for category in CATEGORIES:
                print(f'    {category}: {scope["counts"][category]} cycles; {scope["percent_of_frontend"][category]:.4f}% of frontend; '
                      f'{scope["percent_of_cycles"][category]:.4f}% of all scope cycles',flush=True)
        return profile
    jobs = [(kind,seed) for kind in kinds for seed in range(args.seeds+1)]
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        profiles = list(pool.map(execute,jobs))
    if before != rtl_hashes():
        raise RuntimeError('CPU/cache RTL changed during observation')
    summary = {'rtl_unchanged':True,'multiplier':multiplier,'policy':POLICY,'runs':profiles}
    (out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    print(f'PASS: {len(profiles)} CoreMark frontend profiles; CPU/cache RTL SHA256 unchanged; {out}',flush=True)
    return 0


if __name__=='__main__':
    raise SystemExit(main())
