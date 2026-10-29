#!/usr/bin/env python3
"""Upload a profiled firmware, receive its frozen report, and save JSON/CSV.
Offline decoding (--from-log) works without pyserial or an FPGA.
"""
import argparse
import csv
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import struct
import sys
import time

COUNTERS = ('cycles', 'instructions', 'ic_access', 'ic_miss', 'dc_load',
            'dc_load_miss', 'dc_store', 'dc_store_miss', 'branches',
            'branch_misses', 'frontend_wait', 'memory_wait', 'load_use_wait',
            'multiply_wait', 'divide_wait')
META = ('schema', 'status', 'return', 'core_hz', 'ic_bytes', 'dc_bytes', 'l2_bytes')
OPTIONAL_META = ('features',)


def parse_return(text):
    value = int(text, 0)
    if not -(1 << 31) <= value < (1 << 32):
        raise argparse.ArgumentTypeError('expected a signed/unsigned 32-bit return value')
    return value & 0xffffffff


def parse_report(text):
    frames = re.findall(r'\[PERF_BEGIN\]\r?\n(.*?)\[PERF_END\]', text, re.S)
    if len(frames) != 1:
        raise ValueError('expected exactly one complete PERF frame')
    fields = {}
    for line in frames[0].splitlines():
        key, sep, value = line.partition('=')
        if not sep or key not in META + OPTIONAL_META + COUNTERS or key in fields:
            raise ValueError(f'invalid or duplicate PERF field: {line!r}')
        width = 16 if key in COUNTERS else 8
        if not re.fullmatch(r'[0-9a-fA-F]{' + str(width) + '}', value):
            raise ValueError(f'invalid hexadecimal field: {line!r}')
        fields[key] = int(value, 16)
    if not set(META + COUNTERS).issubset(fields):
        raise ValueError('incomplete PERF fields')
    if fields['schema'] != 1 or fields['status'] != 4:
        raise ValueError('unsupported schema or main did not complete normally')
    if fields['core_hz'] <= 0 or fields['instructions'] <= 0 or fields['cycles'] <= 0:
        raise ValueError('invalid frequency, cycle count, or instruction count')
    for miss, access in [('ic_miss', 'ic_access'), ('dc_load_miss', 'dc_load'),
                         ('dc_store_miss', 'dc_store'), ('branch_misses', 'branches')]:
        if fields[miss] > fields[access]:
            raise ValueError(f'{miss} exceeds {access}')
    def percent(a, b):
        return fields[a] * 100.0 / fields[b] if fields[b] else None
    metrics = {
        'seconds': fields['cycles'] / fields['core_hz'],
        'cpi': fields['cycles'] / fields['instructions'],
        'ipc': fields['instructions'] / fields['cycles'],
        'ic_miss_percent': percent('ic_miss', 'ic_access'),
        'dc_load_miss_percent': percent('dc_load_miss', 'dc_load'),
        'dc_store_miss_percent': percent('dc_store_miss', 'dc_store'),
        'branch_miss_percent': percent('branch_misses', 'branches'),
    }
    report = {'metadata': {k: fields[k] for k in META + OPTIONAL_META if k in fields},
              'counters': {k: fields[k] for k in COUNTERS}, 'metrics': metrics}
    if '[COREMARK_BEGIN]' in text:
        report['benchmark'] = parse_coremark(text, fields['core_hz'])
    return report


def parse_coremark(text, core_hz):
    frames = re.findall(r'\[COREMARK_BEGIN\]\r?\n(.*?)\[COREMARK_END\]', text, re.S)
    if len(frames) != 1:
        raise ValueError('expected one complete CoreMark frame')
    names = {'iterations', 'ticks_us', 'data_size', 'run_kind', 'crc_list',
             'crc_matrix', 'crc_state', 'crc_final', 'crc_ok', 'time_valid'}
    cm = {}
    for line in frames[0].splitlines():
        key, sep, value = line.partition('=')
        if not sep or key not in names or key in cm or not re.fullmatch('[0-9a-fA-F]{8}', value):
            raise ValueError('invalid CoreMark field: ' + line)
        cm[key] = int(value, 16)
    if set(cm) != names or cm['run_kind'] not in (0, 1) or cm['data_size'] != 2000:
        raise ValueError('incomplete/unsupported CoreMark configuration')
    expected = (0xe714, 0x1fd7, 0x8e3a) if cm['run_kind'] == 0 else (0xe3c1, 0x0747, 0x8d84)
    crc_ok = tuple(cm[key] for key in ('crc_list', 'crc_matrix', 'crc_state')) == expected
    if bool(cm['crc_ok']) != crc_ok or bool(cm['time_valid']) != (cm['ticks_us'] >= 10_000_000):
        raise ValueError('CoreMark CRC/time flags inconsistent with result')
    cm['name'] = 'CoreMark'
    cm['crc_pass'] = crc_ok
    cm['kernel_seconds'] = cm['ticks_us'] / 1e6
    cm['timing_qualified'] = crc_ok and cm['ticks_us'] >= 10_000_000 and cm['iterations'] > 0
    # Short RTL validations deliberately have no published benchmark score.
    cm['iterations_per_second'] = (cm['iterations'] / cm['kernel_seconds']) if cm['timing_qualified'] else None
    cm['per_mhz'] = cm['iterations_per_second'] / (core_hz / 1e6) if cm['timing_qualified'] else None
    return cm


def display(report):
    m, c, v = report['metadata'], report['counters'], report['metrics']
    print(f"Program: {report.get('program', 'unknown')}\nStatus: COMPLETED")
    print(f"Main return: 0x{m['return']:08x}   Validation: {report.get('validation', 'not checked')}")
    print(f"Core: {m['core_hz']:,} Hz   I/D/L2: {m['ic_bytes']}/{m['dc_bytes']}/{m['l2_bytes']} bytes")
    if 'features' in m:
        print(f"Fetch overlap: {'ON' if m['features'] & 1 else 'OFF'} (hardware-reported)")
        if m['features'] & 2:
            print('Fetch queue: 3 ordered slots; I-cache/L2 hit-under-miss')
    print(f"Cycles: {c['cycles']:,}   Retired instructions: {c['instructions']:,}")
    print(f"Time: {v['seconds']:.9f} s   CPI: {v['cpi']:.6f}   IPC: {v['ipc']:.6f}")
    for label, miss, access, metric in [
        ('I-cache miss', 'ic_miss', 'ic_access', 'ic_miss_percent'),
        ('D-load miss', 'dc_load_miss', 'dc_load', 'dc_load_miss_percent'),
        ('D-store miss', 'dc_store_miss', 'dc_store', 'dc_store_miss_percent'),
        ('Branch direction miss', 'branch_misses', 'branches', 'branch_miss_percent')]:
        rate = 'N/A' if v[metric] is None else f'{v[metric]:.3f}%'
        print(f"{label}: {c[miss]:,} / {c[access]:,} ({rate})")
    print('Wait cycles (may overlap): ' + ', '.join(f'{k}={c[k]}' for k in COUNTERS[10:]))
    if 'benchmark' in report:
        cm = report['benchmark']
        print(f"CoreMark kernel: {cm['kernel_seconds']:.6f} s, {cm['iterations']} iterations; CRC: {'PASS' if cm['crc_pass'] else 'FAIL'}")
        if cm['timing_qualified']:
            print(f"Kernel throughput: {cm['iterations_per_second']:.6f} iterations/s; per MHz: {cm['per_mhz']:.6f}")
            print('Conforming reporting also requires both official seed runs and disclosure of build/memory configuration.')
        else:
            print('Score: N/A (short run or CRC failure; timing results require >=10 seconds)')


def save_report(report, prefix):
    prefix = Path(prefix)
    prefix.parent.mkdir(parents=True, exist_ok=True)
    Path(str(prefix) + '.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    row = {k: report[k] for k in ('program', 'validation') if k in report}
    for key in ('mem_sha256', 'source', 'compiler_flags', 'seed', 'hardware_variant'):
        if key in report:
            row[key] = report[key]
    if 'build' in report:
        row['source'] = report['build'].get('source', '')
        row['compiler_flags'] = report['build'].get('cflags', '')
    if 'benchmark' in report:
        row.update({'benchmark_' + k: v for k, v in report['benchmark'].items()})
    for group in ('metadata', 'counters', 'metrics'):
        row.update(report[group])
    with Path(str(prefix) + '.csv').open('w', newline='', encoding='utf-8') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(row))
        writer.writeheader()
        writer.writerow(row)


def receive_live(args, raw_path):
    # Import the existing uploader only for live operation; preserve its pacing.
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    import uart_send_mem as uploader
    import serial
    payload = uploader.load_mem(args.mem)
    raw = bytearray()
    with serial.Serial(baudrate=args.baud, timeout=0.1, write_timeout=10) as ser:
        ser.dtr = False
        ser.rts = False
        ser.port = args.port
        ser.open()
        ser.reset_input_buffer()
        time.sleep(args.delay)
        uploader.write_all(ser, b'\x55' * 4096, 'preamble')
        ser.flush()
        time.sleep(0.05)
        uploader.write_all(ser, struct.pack('<II', uploader.SYNC_WORD, len(payload)), 'header')
        uploader.write_chunks(ser, payload, 256, 0.001)
        ser.flush()
        print('Upload sent; waiting for main to return...', file=sys.stderr)
        deadline = time.monotonic() + args.timeout
        try:
            while time.monotonic() < deadline:
                raw.extend(ser.read(4096))
                if b'[PERF_END]\n' in raw or b'[PERF_END]\r\n' in raw:
                    return raw.decode('ascii', errors='replace')
            raise TimeoutError('no complete report; check reset/boot, firmware return, and UART clock')
        finally:
            raw_path.write_bytes(raw)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    source = ap.add_mutually_exclusive_group(required=True)
    source.add_argument('--mem', type=Path, help='profiled firmware image; also requires --port')
    source.add_argument('--from-log', type=Path, help='decode a captured UART report offline')
    ap.add_argument('--port')
    ap.add_argument('--baud', type=int, default=115200)
    ap.add_argument('--delay', type=float, default=1.0)
    ap.add_argument('--timeout', type=float, default=120.0)
    ap.add_argument('--expect-return', type=parse_return)
    ap.add_argument('--out-dir', type=Path, default=Path('build_perf/results'))
    args = ap.parse_args()
    if args.mem and not args.port:
        ap.error('--mem requires --port')
    if args.timeout <= 0 or args.delay < 0 or args.baud <= 0:
        ap.error('timeout/baud must be positive and delay must not be negative')
    program = (args.mem or args.from_log).stem
    args.out_dir.mkdir(parents=True, exist_ok=True)
    prefix = args.out_dir / (program + '_' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ'))
    try:
        text = args.from_log.read_text(encoding='ascii') if args.from_log else receive_live(args, Path(str(prefix) + '.uart.txt'))
        report = parse_report(text)
        report['program'] = program
        report['validation'] = 'not checked' if args.expect_return is None else (
            'PASS' if report['metadata']['return'] == args.expect_return else 'FAIL')
        if 'benchmark' in report and not report['benchmark']['crc_pass']:
            report['validation'] = 'FAIL'
        report['captured_at_utc'] = datetime.now(timezone.utc).isoformat()
        if args.mem:
            report['mem_sha256'] = hashlib.sha256(args.mem.read_bytes()).hexdigest()
            manifest = Path(str(args.mem) + '.json')
            if manifest.exists():
                report['build'] = json.loads(manifest.read_text(encoding='utf-8'))
                if report['build'].get('mem_sha256') != report['mem_sha256']:
                    raise ValueError('build manifest does not match firmware image; rebuild it')
        save_report(report, prefix)
        display(report)
        print(f'Saved: {prefix}.json and .csv')
        return 1 if report['validation'] == 'FAIL' else 0
    except (OSError, ValueError, TimeoutError, ImportError) as exc:
        print(f'PERF ERROR: {exc}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
