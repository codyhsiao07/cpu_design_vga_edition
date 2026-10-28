import csv
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from run_perf import COUNTERS, META, parse_report, parse_return, receive_live, save_report
from check_perf_trace import RV32IM
from compare_coremark import compare


def frame():
    fields = dict(schema=1, status=4, **{'return': 17}, core_hz=50_000_000,
                  ic_bytes=8192, dc_bytes=8192, l2_bytes=16384)
    fields.update({key: 0 for key in COUNTERS})
    fields.update(cycles=(1 << 32) + 50, instructions=100, ic_access=20, ic_miss=2)
    return '[PERF_BEGIN]\n' + ''.join(
        f'{key}={fields[key]:0{16 if key in COUNTERS else 8}x}\n'
        for key in META + COUNTERS) + '[PERF_END]\n'


class ReportTests(unittest.TestCase):
    def test_optional_hardware_features_and_fair_comparison(self):
        base=parse_report(frame().replace('schema=00000001\n','schema=00000001\nfeatures=00000000\n'))
        opt=parse_report(frame().replace('schema=00000001\n','schema=00000001\nfeatures=00000001\n'))
        self.assertEqual(opt['metadata']['features'],1)
        for report in (base,opt):
            report['mem_sha256']='a'*64
            report['metadata']['return']=0
            report['benchmark']=dict(name='CoreMark',crc_pass=True,timing_qualified=True,
                                     iterations=1000,ticks_us=12_000_000,data_size=2000,run_kind=0)
        # Different automatic iteration counts must be normalized, not raw total times.
        opt['benchmark'].update(iterations=2000,ticks_us=20_000_000)
        result=compare(base,opt)
        self.assertAlmostEqual(result['kernel_speedup'],1.2)
        opt['metadata']['features']=0
        with self.assertRaises(ValueError):compare(base,opt)
        opt['metadata']['features']=1
        opt['mem_sha256']='b'*64
        with self.assertRaises(ValueError):compare(base,opt)

    def test_coremark_short_crc_and_qualified_timer(self):
        def cm_frame(ticks, crc=0xe714):
            values=dict(iterations=1000,ticks_us=ticks,data_size=2000,run_kind=0,
                        crc_list=crc,crc_matrix=0x1fd7,crc_state=0x8e3a,crc_final=0x1234,
                        crc_ok=int(crc==0xe714),time_valid=int(ticks>=10_000_000))
            return '[COREMARK_BEGIN]\n'+''.join(f'{k}={v:08x}\n' for k,v in values.items())+'[COREMARK_END]\n'
        short=parse_report(cm_frame(10000)+frame())['benchmark']
        self.assertTrue(short['crc_pass'])
        self.assertFalse(short['timing_qualified'])
        self.assertIsNone(short['iterations_per_second'])
        full=parse_report(cm_frame(12_000_000)+frame())['benchmark']
        self.assertTrue(full['timing_qualified'])
        self.assertAlmostEqual(full['iterations_per_second'],1000/12)
        self.assertAlmostEqual(full['per_mhz'],(1000/12)/50)
        bad=parse_report(cm_frame(12_000_000,0)+frame())['benchmark']
        self.assertFalse(bad['crc_pass'])
        self.assertIsNone(bad['iterations_per_second'])
        with self.assertRaises(ValueError):
            parse_report(cm_frame(10000).replace('time_valid=00000000','time_valid=00000001')+frame())

    def test_signed_return(self):
        self.assertEqual(parse_return('-1'), 0xffffffff)
        self.assertEqual(parse_return('0x80000000'), 0x80000000)

    def test_64bit_and_zero_denominators(self):
        report = parse_report('application text\r\n' + frame().replace('\n', '\r\n'))
        self.assertEqual(report['counters']['cycles'], (1 << 32) + 50)
        self.assertEqual(report['metrics']['ic_miss_percent'], 10)
        self.assertIsNone(report['metrics']['branch_miss_percent'])
        self.assertAlmostEqual(report['metrics']['seconds'], ((1 << 32) + 50) / 50_000_000)

    def test_incomplete_duplicate_and_bad_frames_rejected(self):
        for invalid in [frame().replace('[PERF_END]', ''), frame() + frame(),
                        frame().replace('status=00000004', 'status=00000008'),
                        frame().replace('schema=00000001', 'schema=00000002'),
                        frame().replace('core_hz=02faf080', 'core_hz=00000000'),
                        frame().replace('return=00000011\n', ''),
                        frame().replace('return=00000011\n', 'return=00000011\nreturn=00000011\n'),
                        frame().replace('ic_miss=0000000000000002', 'ic_miss=0000000000000020')]:
            with self.subTest(invalid=invalid):
                with self.assertRaises(ValueError):
                    parse_report(invalid)

    def test_json_csv_and_cli_return_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = parse_report(frame())
            report.update(program='example', validation='PASS')
            save_report(report, root / 'report')
            self.assertEqual(json.loads((root / 'report.json').read_text())['counters']['instructions'], 100)
            with (root / 'report.csv').open(newline='') as stream:
                self.assertEqual(next(csv.DictReader(stream))['cycles'], str((1 << 32) + 50))
            log = root / 'uart.txt'
            log.write_text(frame())
            script = Path(__file__).with_name('run_perf.py')
            for expected, exit_code in [('17', 0), ('0', 1)]:
                result = subprocess.run([sys.executable, str(script), '--from-log', str(log),
                                         '--expect-return', expected, '--out-dir', str(root)],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, exit_code, result.stderr)


class MultiplyDivideOracleTests(unittest.TestCase):
    def execute(self, op, a, b):
        mem = bytearray(1 << 20)
        instruction = (1 << 25) | (2 << 20) | (1 << 15) | (op << 12) | (3 << 7) | 0x33
        mem[:4] = instruction.to_bytes(4, 'little')
        cpu = RV32IM(mem)
        cpu.x[1], cpu.x[2] = a, b
        cpu.step()
        return cpu.x[3]

    def test_rv32m_boundaries(self):
        cases = [(0, 0xffffffff, 2, 0xfffffffe), (1, 0xffffffff, 2, 0xffffffff),
                 (2, 0xffffffff, 0xffffffff, 0xffffffff), (3, 0xffffffff, 0xffffffff, 0xfffffffe),
                 (4, 0xfffffff9, 3, 0xfffffffe), (6, 0xfffffff9, 3, 0xffffffff),
                 (4, 0x80000000, 0xffffffff, 0x80000000), (6, 0x80000000, 0xffffffff, 0),
                 (4, 7, 0, 0xffffffff), (6, 7, 0, 7),
                 (5, 7, 0, 0xffffffff), (7, 7, 0, 7)]
        for op, a, b, result in cases:
            self.assertEqual(self.execute(op, a, b), result)


class SerialTransportTests(unittest.TestCase):
    def transport(self, chunks, timeout=False):
        calls = []
        class SerialPort:
            def __init__(self, **kwargs):
                self.dtr = self.rts = True
            def __enter__(self):
                return self
            def __exit__(self, *args):
                pass
            def open(self):
                self.assert_inactive = not self.dtr and not self.rts
                calls.append(('open', self.assert_inactive))
            def reset_input_buffer(self):
                pass
            def flush(self):
                pass
            def read(self, count):
                return chunks.pop(0) if chunks else b''
        uploader = SimpleNamespace(
            load_mem=lambda path: b'\x01\x02\x03\x04', SYNC_WORD=0xc0de5a5a,
            write_all=lambda port, data, label: calls.append((label, bytes(data))),
            write_chunks=lambda port, data, size, delay: calls.append(('payload', bytes(data))))
        args = SimpleNamespace(mem='unused.mem', port='COM_TEST', baud=115200, delay=0, timeout=1)
        with tempfile.TemporaryDirectory() as directory:
            raw_path = Path(directory) / 'raw.txt'
            with patch.dict(sys.modules, {'uart_send_mem': uploader, 'serial': SimpleNamespace(Serial=SerialPort)}), \
                 patch('run_perf.time.sleep'), \
                 patch('run_perf.time.monotonic', side_effect=[0, 0, 2] if timeout else [0, 0, 0, 0, 0]):
                if timeout:
                    with self.assertRaises(TimeoutError):
                        receive_live(args, raw_path)
                    self.assertEqual(raw_path.read_bytes(), b'partial')
                else:
                    self.assertEqual(receive_live(args, raw_path), frame())
                    self.assertEqual(raw_path.read_bytes(), frame().encode())
        self.assertEqual(calls[0], ('open', True))
        self.assertIn(('header', bytes.fromhex('5a5adec004000000')), calls)
        self.assertIn(('payload', b'\x01\x02\x03\x04'), calls)

    def test_split_uart_frame_and_upload_header(self):
        data = frame().encode()
        self.transport([data[:31], data[31:-5], data[-5:]])

    def test_timeout_keeps_partial_uart_log(self):
        self.transport([b'partial'], timeout=True)


if __name__ == '__main__':
    unittest.main()
