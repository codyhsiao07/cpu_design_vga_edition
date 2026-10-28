// Self-checking RV32IM/DDR/cache stress firmware.
//
// STRESS_SIM builds one bounded pass and reports 0x3100C0DE in x10.
// Board builds run forever, reporting each completed round over UART.

typedef unsigned int   u32;
typedef unsigned short u16;
typedef unsigned char  u8;

#define PASS_SIG 0x3100C0DEu
#define FAIL_SIG 0xDEAD3100u

#define SCRATCH_BASE   0x80010000u
#define THRASH_STRIDE  0x00020000u
#define UART_TX_DATA   (*(volatile u32 *)0x40000000u)
#define UART_TX_STATUS (*(volatile u32 *)0x40000004u)

#ifdef STRESS_SIM
#define WORD_COUNT   1024u
#define BYTE_COUNT   2048u
#define HALF_COUNT   1024u
#define THRASH_LINES 8u
#else
#define WORD_COUNT   16384u
#define BYTE_COUNT   16384u
#define HALF_COUNT   8192u
#define THRASH_LINES 64u
#endif

static inline u32 rotl32(u32 x, u32 n)
{
  n &= 31u;
  return n ? ((x << n) | (x >> (32u - n))) : x;
}

static inline u32 rotr32(u32 x, u32 n)
{
  n &= 31u;
  return n ? ((x >> n) | (x << (32u - n))) : x;
}

#ifdef STRESS_SIM
static void uart_putc(char ch) { (void)ch; }
#else
static void uart_putc(char ch)
{
  u32 timeout = 10000000u;
  while (((UART_TX_STATUS & 1u) == 0u) && timeout)
    timeout--;
  if (timeout)
    UART_TX_DATA = (u32)(u8)ch;
}
#endif

static void uart_puts(const char *s)
{
  while (*s)
    uart_putc(*s++);
}

static void uart_hex(u32 value)
{
  static const char digits[] = "0123456789ABCDEF";
  int shift;
  for (shift = 28; shift >= 0; shift -= 4)
    uart_putc(digits[(value >> (u32)shift) & 15u]);
}

__attribute__((noreturn, noinline))
static void stop_with_signature(u32 signature)
{
  asm volatile(
      "mv x10, %0\n"
      "1: jal x0, 1b\n"
      : : "r"(signature) : "x10");
  __builtin_unreachable();
}

__attribute__((noreturn, noinline))
static void fail(u32 phase, u32 index, u32 got, u32 expected)
{
  uart_puts("\r\nFAIL phase=");
  uart_hex(phase);
  uart_puts(" index=");
  uart_hex(index);
  uart_puts(" got=");
  uart_hex(got);
  uart_puts(" expected=");
  uart_hex(expected);
  uart_puts("\r\n");
  stop_with_signature(FAIL_SIG | (phase & 0xFFu));
}

static u32 memory_pattern(u32 index, u32 round)
{
  u32 x = (index * 0x10204081u) ^ 0xA5A55A5Au ^ (round * 0x9E3779B9u);
  return rotl32(x, (index & 15u) + 1u);
}

static void phase_words(u32 round)
{
  volatile u32 *mem = (volatile u32 *)SCRATCH_BASE;
  u32 i;
  for (i = 0; i < WORD_COUNT; i++)
    mem[i] = memory_pattern(i, round);
  for (i = WORD_COUNT; i != 0u; i--) {
    u32 index = i - 1u;
    u32 expected = memory_pattern(index, round);
    u32 got = mem[index];
    if (got != expected)
      fail(1u, index, got, expected);
  }
}

static void phase_bytes_and_halves(u32 round)
{
  volatile u8 *mem8 = (volatile u8 *)SCRATCH_BASE;
  volatile u16 *mem16 = (volatile u16 *)(SCRATCH_BASE + 0x00008000u);
  u32 i;

  for (i = 0; i < BYTE_COUNT; i++)
    mem8[i] = (u8)((i * 37u) ^ (i >> 3) ^ round ^ 0xC3u);
  for (i = 0; i < BYTE_COUNT; i++) {
    u32 expected = (u8)((i * 37u) ^ (i >> 3) ^ round ^ 0xC3u);
    u32 got = mem8[i];
    if (got != expected)
      fail(2u, i, got, expected);
  }

  for (i = 0; i < HALF_COUNT; i++)
    mem16[i] = (u16)((i * 257u) ^ (round * 17u) ^ 0x8001u);
  for (i = HALF_COUNT; i != 0u; i--) {
    u32 index = i - 1u;
    u32 expected = (u16)((index * 257u) ^ (round * 17u) ^ 0x8001u);
    u32 got = mem16[index];
    if (got != expected)
      fail(3u, index, got, expected);
  }

  // Explicit signed loads at the last byte/halfword of a 64-byte line.
  mem8[63] = 0x80u;
  if ((u32)(int)(signed char)mem8[63] != 0xFFFFFF80u)
    fail(4u, 63u, (u32)(int)(signed char)mem8[63], 0xFFFFFF80u);
  mem16[31] = 0x8001u;
  if ((u32)(int)(signed short)mem16[31] != 0xFFFF8001u)
    fail(4u, 31u, (u32)(int)(signed short)mem16[31], 0xFFFF8001u);
}

static void phase_cache_thrash(u32 round)
{
  u32 line;
  u32 slot;

  // THRASH_STRIDE aliases both the production D-cache and L2 set indexes.
  // Load-before-store allocates the line, then the store makes it dirty.
  for (line = 0; line < THRASH_LINES; line++) {
    for (slot = 0; slot < 4u; slot++) {
      volatile u32 *p = (volatile u32 *)(SCRATCH_BASE +
          slot * THRASH_STRIDE + line * 64u);
      u32 expected = 0xC0010000u ^ (round << 8) ^ (slot << 20) ^ line;
      u32 old = *p;
      asm volatile("" : : "r"(old));
      *p = expected;
    }
  }

  for (line = 0; line < THRASH_LINES; line++) {
    for (slot = 0; slot < 4u; slot++) {
      u32 reordered = (slot * 3u + line) & 3u;
      volatile u32 *p = (volatile u32 *)(SCRATCH_BASE +
          reordered * THRASH_STRIDE + line * 64u);
      u32 expected = 0xC0010000u ^ (round << 8) ^
                     (reordered << 20) ^ line;
      u32 got = *p;
      if (got != expected)
        fail(5u, (line << 2) | reordered, got, expected);
    }
  }
}

static void phase_rv32m(void)
{
  u32 got;
  u32 a = 0x12345678u;
  u32 b = 0x9ABCDEF0u;
  int sa;
  int sb;

  asm volatile("mul %0, %1, %2" : "=r"(got) : "r"(a), "r"(b));
  if (got != 0x242D2080u) fail(6u, 0u, got, 0x242D2080u);
  asm volatile("mulhu %0, %1, %2" : "=r"(got) : "r"(a), "r"(b));
  if (got != 0x0B00EA4Eu) fail(6u, 1u, got, 0x0B00EA4Eu);
  asm volatile("mulh %0, %1, %2" : "=r"(got) : "r"(a), "r"(b));
  if (got != 0xF8CC93D6u) fail(6u, 2u, got, 0xF8CC93D6u);

  sa = -2;
  asm volatile("mulhsu %0, %1, %2" : "=r"(got) : "r"(sa), "r"(0xFFFFFFFFu));
  if (got != 0xFFFFFFFEu) fail(6u, 3u, got, 0xFFFFFFFEu);

  sa = -123456789;
  sb = 12345;
  asm volatile("div %0, %1, %2" : "=r"(got) : "r"(sa), "r"(sb));
  if (got != (u32)-10000) fail(6u, 4u, got, (u32)-10000);
  asm volatile("rem %0, %1, %2" : "=r"(got) : "r"(sa), "r"(sb));
  if (got != (u32)-6789) fail(6u, 5u, got, (u32)-6789);
  asm volatile("divu %0, %1, %2" : "=r"(got) : "r"(0xFEDCBA98u), "r"(0x12345u));
  if (got != 0x0000E000u) fail(6u, 6u, got, 0x0000E000u);
  asm volatile("remu %0, %1, %2" : "=r"(got) : "r"(0xFEDCBA98u), "r"(0x12345u));
  if (got != 0x00005A98u) fail(6u, 7u, got, 0x00005A98u);

  // Architectural divide corner cases.
  asm volatile("div %0, %1, %2" : "=r"(got) : "r"(-7), "r"(0));
  if (got != 0xFFFFFFFFu) fail(6u, 8u, got, 0xFFFFFFFFu);
  asm volatile("rem %0, %1, %2" : "=r"(got) : "r"(-7), "r"(0));
  if (got != (u32)-7) fail(6u, 9u, got, (u32)-7);
  asm volatile("div %0, %1, %2" : "=r"(got) : "r"(0x80000000u), "r"(-1));
  if (got != 0x80000000u) fail(6u, 10u, got, 0x80000000u);
  asm volatile("rem %0, %1, %2" : "=r"(got) : "r"(0x80000000u), "r"(-1));
  if (got != 0u) fail(6u, 11u, got, 0u);
}

__attribute__((noinline)) static u32 jalr_mix_a(u32 a, u32 b)
{
  return rotl32(a ^ 0x13579BDFu, 5u) + b * 3u;
}

__attribute__((noinline)) static u32 jalr_mix_b(u32 a, u32 b)
{
  return rotr32(a + 0x2468ACE1u, 7u) ^ (b * 0x10201u);
}

static void phase_alu_branch_jalr(void)
{
  typedef u32 (*mix_fn)(u32, u32);
  static mix_fn const functions[2] = {jalr_mix_a, jalr_mix_b};
  u32 state = 0x6D2B79F5u;
  u32 x = 0x12345678u;
  u32 i;

  asm volatile("" : "+r"(state), "+r"(x));
  for (i = 0; i < 128u; i++) {
    mix_fn fn = functions[i & 1u];
    u32 result = fn(state, i);
    state = rotl32(state ^ result, (i & 7u) + 1u) + 0x9E3779B9u;
  }
  if (state != 0x61FF325Au)
    fail(7u, 0u, state, 0x61FF325Au);

  for (i = 0; i < 1000u; i++) {
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    x += i * 0x9E3779B9u;
    x = rotl32(x, (i & 15u) + 1u);
  }
  if (x != 0x4FD00A3Au)
    fail(7u, 1u, x, 0x4FD00A3Au);
}

static void run_round(u32 round)
{
  phase_alu_branch_jalr();
  phase_rv32m();
  phase_words(round);
  phase_bytes_and_halves(round);
  phase_cache_thrash(round);
}

int main(void)
{
  u32 round = 0;
  uart_puts("\r\nRV32IM DDR/cache stress starting\r\n");

#ifdef STRESS_SIM
  (void)round;
  run_round(0u);
#ifdef STRESS_PERF
  return (int)PASS_SIG;
#else
  stop_with_signature(PASS_SIG);
#endif
#else
  for (;;) {
    run_round(round);
    uart_puts("PASS round=");
    uart_hex(round);
    uart_puts("\r\n");
    round++;
  }
#endif
}
