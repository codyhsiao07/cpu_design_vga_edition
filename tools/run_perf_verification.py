#!/usr/bin/env python3
"""Build profiling firmware and verify PMU, complete CPU traces, and UART frames."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
from check_perf_trace import check_trace
from run_perf import parse_report, save_report

ROOT = Path(__file__).resolve().parents[1]
CASES = [
    ('smoke', 'OS/main.c', '', 17, 2),
    ('count', 'TEST_FILES/prog_perf_count.S', '', 42, 35),
    ('tail', 'TEST_FILES/prog_perf_tail.S', '', 43, 3),
    ('fetch_dependencies', 'TEST_FILES/prog_perf_fetch_dependencies.S', '', 0x5f07c0de, None),
    ('alu', 'TEST_FILES/prog_perf_alu.c', '', 0, None),
    ('branch', 'TEST_FILES/prog_perf_branch.c', '', 0, None),
    ('array_small', 'TEST_FILES/prog_perf_array.c', '-DPERF_ARRAY_WORDS=128', 0, None),
    ('array_large', 'TEST_FILES/prog_perf_array.c', '-DPERF_ARRAY_WORDS=8192', 0, None),
    ('muldiv', 'TEST_FILES/prog_test28_muldiv_smoke.c', '', 0x2800c0de, None),
    ('stress', 'TEST_FILES/prog_perf_stress.c', '', 0x3100c0de, None),
]


def run(command, log, require=None, timeout=300):
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open('w', encoding='utf-8') as stream:
        result = subprocess.run([str(x) for x in command], cwd=ROOT, stdout=stream,
                                stderr=subprocess.STDOUT, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f'command failed ({result.returncode}); see {log}')
    if require and require not in log.read_text(encoding='utf-8', errors='replace'):
        raise RuntimeError(f'missing {require!r}; see {log}')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--build-only', action='store_true')
    ap.add_argument('--skip-build', action='store_true')
    ap.add_argument('--cases', default=','.join(row[0] for row in CASES))
    ap.add_argument('--seeds', type=int, default=2, help='random-backpressure runs per case, plus deterministic')
    ap.add_argument('--production', action='store_true', help='use production cache geometry in simulation')
    ap.add_argument('--fetch-overlap', action='store_true', help='enable three ordered fetch slots and hit-under-miss')
    ap.add_argument('--out-dir', type=Path, default=ROOT / 'build_perf/verification')
    ap.add_argument('--iverilog', default='iverilog')
    ap.add_argument('--vvp', default='vvp')
    args = ap.parse_args()
    selected = args.cases.split(',')
    if args.seeds < 0 or set(selected) - {row[0] for row in CASES}:
        ap.error('invalid cases or seed count')
    out = args.out_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)
    results = []
    try:
        if not args.skip_build:
            for name, source, defines, expected, count in CASES:
                if name not in selected:
                    continue
                print(f'BUILD {name}', flush=True)
                run(['make', 'mem', 'PERF=1', f'SRC={source}', f'OUT_NAME=perf_{name}',
                     f'MEM_OUT=build_perf/perf_{name}.mem', f'APP_DEFINES={defines}'], out / f'build_{name}.log')
        if args.build_only:
            print('PASS: profiling firmware built in build_perf/perf_*.mem')
            return 0
        run([args.iverilog, '-g2005-sv', '-s', 'performance_monitor_tb', '-o', out / 'unit.out',
             'performance_monitor.v', 'performance_monitor_tb.v'], out / 'compile_unit.log')
        run([args.vvp, out / 'unit.out'], out / 'unit.log', 'PASS: performance_monitor_tb')
        print('PASS PMU unit TB', flush=True)
        sim = out / 'system.out'
        defines = ['-DPRODUCTION_BUILD'] if args.production else ['-DFAST_SIM']
        if args.fetch_overlap:
            defines.append('-DPERF_FETCH_OVERLAP')
        run([args.iverilog, '-g2005-sv', '-DSYNTHESIS', *defines, '-i', '-s',
             'performance_system_tb', '-o', sim, *sorted(ROOT.glob('*.v'))], out / 'compile_system.log')
        make_config = subprocess.check_output(['make', '-s', 'print-config'], cwd=ROOT, text=True)
        config_lines = [line.strip().strip('"') for line in make_config.splitlines()]
        toolchain = next(line.split('=', 1)[1] for line in config_lines if line.startswith('TOOLCHAIN_BIN='))
        nm = Path(toolchain) / 'riscv-none-elf-nm'
        if not nm.with_suffix('.exe').exists() and not nm.exists():
            nm = shutil.which('riscv-none-elf-nm') or str(nm)
        for name, source, defines, expected, exact_count in CASES:
            if name not in selected:
                continue
            image = ROOT / f'build_perf/perf_{name}.mem'
            elf = ROOT / f'build_perf/perf_{name}/perf_{name}.elf'
            symbol_text = subprocess.check_output([str(nm), '-n', str(elf)], text=True)
            symbols = {cols[2]: int(cols[0], 16) for line in symbol_text.splitlines()
                       if len(cols := line.split()) == 3 and cols[1].lower() != 'u'}
            for seed in range(args.seeds + 1):
                prefix = out / f'{name}_seed{seed}'
                trace = Path(str(prefix) + '.trace')
                uart = Path(str(prefix) + '.uart.txt')
                # Use short relative MEMFILE: the legacy TB string is 64 bytes.
                run([args.vvp, sim, '+TEST=0', f'+MEMFILE=build_perf/perf_{name}.mem',
                     '+ASSERT_EN=1', '+MAXCYCLES=12000000', f'+RAND_MEM={int(seed != 0)}',
                     f'+PERF_HOLD_MEM={int(name == "count")}',
                     f'+SEED={seed}', '+RAND_BP_PCT=20', '+RAND_I_MAX=9', '+RAND_D_MAX=9',
                     f'+PERF_TRACE={trace}', f'+PERF_UART={uart}'],
                    Path(str(prefix) + '.log'), 'PASS: performance_system_tb')
                instruction_count, branches = check_trace(image, symbols, trace, expected)
                report = parse_report(uart.read_text(encoding='ascii'))
                counters, metadata = report['counters'], report['metadata']
                # --skip-build also validates older report firmware, which had
                # no optional features field. When present it must match RTL.
                if 'features' in metadata:
                    assert metadata['features'] == (3 if args.fetch_overlap else 0), name
                assert counters['instructions'] == instruction_count, name
                assert counters['branches'] == branches, name
                assert metadata['return'] == expected, name
                if exact_count is not None:
                    assert instruction_count == exact_count, (name, instruction_count, exact_count)
                if name in ('count', 'muldiv'):
                    assert counters['multiply_wait'] > 0 and counters['divide_wait'] > 0
                if name == 'count':
                    assert counters['dc_load'] == 4 and counters['dc_store'] == 4, counters
                    prefix_text = uart.read_text(encoding='ascii').split('[PERF_BEGIN]')[0]
                    assert prefix_text.count('H') == 1, 'MMIO store replayed under long EX hold'
                if name.startswith('array'):
                    assert counters['dc_load'] > 0 and counters['dc_store'] > 0
                report.update(program=name, validation='PASS', seed=seed,
                              hardware_variant='fetch_overlap' if args.fetch_overlap else 'baseline',
                              source=source, app_defines=defines,
                              compiler_flags='rv32im ilp32 -O2 -mno-relax -msmall-data-limit=0')
                save_report(report, prefix)
                results.append({'case': name, 'seed': seed, **counters})
                print(f'PASS {name} seed={seed}: {instruction_count} instructions, {counters["cycles"]} cycles; exact PC/write trace and UART verified', flush=True)
        (out / 'summary.json').write_text(json.dumps(results, indent=2) + '\n')
        print(f'PASS: {len(results)} full-system runs; outputs: {out}')
        return 0
    except (OSError, ValueError, AssertionError, RuntimeError, subprocess.SubprocessError) as exc:
        print(f'PERF VERIFICATION FAILED: {exc}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
