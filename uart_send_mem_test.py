import tempfile
import unittest
from pathlib import Path

import serial

import uart_send_mem


class FakeSerial:
    def __init__(self, max_write=None, zero_after=None):
        self.max_write = max_write
        self.zero_after = zero_after
        self.data = bytearray()
        self.flush_count = 0

    def write(self, data):
        if self.zero_after is not None and len(self.data) >= self.zero_after:
            return 0
        count = len(data) if self.max_write is None else min(len(data), self.max_write)
        self.data.extend(bytes(data[:count]))
        return count

    def flush(self):
        self.flush_count += 1


class UartSendMemTests(unittest.TestCase):
    def make_mem(self, text):
        tmp = tempfile.NamedTemporaryFile("w", encoding="ascii", delete=False)
        self.addCleanup(lambda: Path(tmp.name).unlink(missing_ok=True))
        with tmp:
            tmp.write(text)
        return tmp.name

    def test_load_mem_converts_words_to_little_endian(self):
        path = self.make_mem("12345678\nAABBCCDD // trailing comment\n\n")
        self.assertEqual(
            uart_send_mem.load_mem(path),
            bytes.fromhex("78 56 34 12 DD CC BB AA"),
        )

    def test_load_mem_reports_line_number_for_invalid_word(self):
        path = self.make_mem("00000000\nnot_hex\n")
        with self.assertRaisesRegex(ValueError, r":2: expected one 32-bit"):
            uart_send_mem.load_mem(path)

    def test_load_mem_rejects_values_wider_than_32_bits(self):
        path = self.make_mem("100000000\n")
        with self.assertRaisesRegex(ValueError, "does not fit in 32 bits"):
            uart_send_mem.load_mem(path)

    def test_write_all_recovers_from_short_writes(self):
        fake = FakeSerial(max_write=3)
        count = uart_send_mem.write_all(fake, b"abcdefgh", "test")
        self.assertEqual(count, 8)
        self.assertEqual(fake.data, b"abcdefgh")

    def test_write_all_rejects_zero_progress(self):
        fake = FakeSerial(max_write=3, zero_after=3)
        with self.assertRaises(serial.SerialTimeoutException):
            uart_send_mem.write_all(fake, b"abcdefgh", "test")

    def test_chunk_pacing_flushes_and_sleeps_between_chunks(self):
        fake = FakeSerial()
        sleeps = []
        uart_send_mem.write_chunks(fake, b"abcdefghij", 4, 0.25, sleeps.append)
        self.assertEqual(fake.data, b"abcdefghij")
        self.assertEqual(fake.flush_count, 2)
        self.assertEqual(sleeps, [0.25, 0.25])


if __name__ == "__main__":
    unittest.main()
