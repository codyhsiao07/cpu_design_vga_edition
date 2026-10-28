"""Independent RV32IM execution oracle for the measured dynamic instruction trace.

Uses the existing RV32I interpreter and adds only M arithmetic. It executes the
startup to establish register/BSS state, then compares every PC and register write
from the instruction after __perf_main_call through the outer return, inclusive.
No duplicate squashing or RTL-derived instruction count is used.
"""
from pathlib import Path
from gen_ref_trace_rv32i import RV32I, parse_mem, s32, u32


class RV32IM(RV32I):
    def step(self):
        inst = self.load_u32(self.pc)
        if inst & 0x7f != 0x33 or inst >> 25 != 1:
            return super().step()
        rd, rs1, rs2 = (inst >> 7) & 31, (inst >> 15) & 31, (inst >> 20) & 31
        a, b = self.x[rs1], self.x[rs2]
        op = (inst >> 12) & 7
        if op == 0:
            value = a * b
        elif op == 1:
            value = (s32(a) * s32(b)) >> 32
        elif op == 2:
            value = (s32(a) * b) >> 32
        elif op == 3:
            value = (a * b) >> 32
        elif op in (4, 6):
            aa, bb = s32(a), s32(b)
            quotient = (abs(aa) // abs(bb)) * (-1 if (aa < 0) != (bb < 0) else 1) if bb else -1
            value = quotient if op == 4 else (aa - quotient * bb if bb else aa)
        else:
            quotient = a // b if b else 0xffffffff
            value = quotient if op == 5 else (a % b if b else a)
        self.write_rd(rd, u32(value))
        self.pc = u32(self.pc + 4)


def check_trace(mem_path, symbols, trace_path, expected_return):
    cpu = RV32IM(parse_mem(mem_path))
    call_pc, return_pc = symbols['__perf_main_call'], symbols['__perf_main_return']
    for _ in range(1_000_000):
        before = cpu.pc
        cpu.step()
        if before == call_pc:
            break
    else:
        raise AssertionError('reference never reached main call')
    actual = Path(trace_path).read_text(encoding='ascii').splitlines()
    branches = 0
    for index, row in enumerate(actual):
        pc_hex, writes, rd, value = row.split()
        if int(pc_hex, 16) != cpu.pc:
            raise AssertionError(f'instruction {index}: DUT PC={pc_hex}, reference={cpu.pc:08x}')
        if cpu.load_u32(cpu.pc) & 0x7f == 0x63:
            branches += 1
        before_writes = len(cpu.trace)
        cpu.step()
        expected_write = cpu.trace[-1][1:] if len(cpu.trace) != before_writes else None
        observed_write = (int(rd), int(value, 16)) if int(writes) else None
        if observed_write != expected_write:
            raise AssertionError(f'instruction {index}: write {observed_write}, expected {expected_write}')
        if cpu.pc == return_pc:
            if index != len(actual) - 1:
                raise AssertionError('DUT counted instructions after outer return')
            break
    else:
        raise AssertionError('DUT trace ended before outer return')
    if cpu.x[10] != expected_return:
        raise AssertionError(f'reference result {cpu.x[10]:08x}, expected {expected_return:08x}')
    return len(actual), branches
