// test29: independently calibrated full-system stress for RV32IM pipeline/cache.
// Covers function-pointer JALR, RV32M ops, signed loads, byte/half/word stores,
// cache-line boundary traffic, branches, and dependent load-use/writeback paths.

#define PASS_SIG     0x2900C0DEu
#define FAIL_SIG     0xDEAD29FFu
#define EXPECT_HASH  0x694CBA60u

#define W_COUNT 128u
#define H_COUNT 256u
#define B_COUNT 512u
#define ROUNDS  72u

typedef unsigned int   u32;
typedef unsigned short u16;
typedef unsigned char  u8;
typedef signed short   i16;
typedef signed char    i8;

static __attribute__((noinline)) u32 rotl32(u32 x, u32 n)
{
  n &= 31u;
  if (n == 0u) {
    return x;
  }
  return (x << n) | (x >> (32u - n));
}

static __attribute__((noinline)) u32 rotr32(u32 x, u32 n)
{
  n &= 31u;
  if (n == 0u) {
    return x;
  }
  return (x >> n) | (x << (32u - n));
}

static __attribute__((noinline)) u32 kernel_a(u32 a, u32 b, u32 i)
{
  u32 x = a ^ rotl32(b + 0x9E3779B9u, (i & 7u) + 1u);

  if ((int)(x ^ (i << 24)) < 0) {
    x += 0x7F4A7C15u ^ i;
  } else {
    x ^= 0x01010101u * ((i & 15u) + 1u);
  }

  if (a < b) {
    x ^= rotl32(a + b, 5u);
  } else {
    x += rotr32(a ^ b, 3u);
  }

  return x ^ (x >> 16);
}

static __attribute__((noinline)) u32 kernel_b(u32 a, u32 b, u32 i)
{
  u32 x = (a + 0x13579BDFu) ^
          rotr32(b ^ (i * 0x10201u), ((i >> 1) & 7u) + 1u);

  if ((i & 3u) == 0u) {
    x += (x << 5);
  } else if ((i & 3u) == 1u) {
    x ^= (x >> 7);
  } else if ((i & 3u) == 2u) {
    x += rotl32(a, 11u);
  } else {
    x ^= rotr32(b, 9u);
  }

  if ((int)(a ^ x) >= (int)(b | 1u)) {
    x += 0x2468ACE1u;
  } else {
    x ^= 0x89ABCDEFu;
  }

  return x + (x >> 13);
}

static u32 (*const kernels[2])(u32, u32, u32) = {
  kernel_a,
  kernel_b
};

static __attribute__((noinline)) u32 mext_mix(u32 a, u32 b, u32 i)
{
  u32 r_mul;
  u32 r_mulh;
  u32 r_mulhsu;
  u32 r_mulhu;
  u32 r_div;
  u32 r_divu;
  u32 r_rem;
  u32 r_remu;
  u32 ub = b | 1u;
  int sa = (int)(a ^ 0x80001234u);
  int sb = (int)((b & 0x00000FFFu) + 1u);
  u32 udiv = (i & 0x3FFu) + 1u;
  u32 x;

  asm volatile("mul %0, %1, %2" : "=r"(r_mul) : "r"(a), "r"(ub));
  asm volatile("mulh %0, %1, %2" : "=r"(r_mulh) : "r"(a), "r"(ub));
  asm volatile("mulhsu %0, %1, %2" : "=r"(r_mulhsu) : "r"(sa), "r"(ub));
  asm volatile("mulhu %0, %1, %2" : "=r"(r_mulhu) : "r"(a), "r"(b));
  asm volatile("div %0, %1, %2" : "=r"(r_div) : "r"(sa), "r"(sb));
  asm volatile("rem %0, %1, %2" : "=r"(r_rem) : "r"(sa), "r"(sb));
  asm volatile("divu %0, %1, %2" : "=r"(r_divu) : "r"(b), "r"(udiv));
  asm volatile("remu %0, %1, %2" : "=r"(r_remu) : "r"(b), "r"(udiv));

  x = r_mul ^ rotl32(r_mulh, 3u);
  x += rotr32(r_mulhsu, 5u);
  x ^= r_mulhu;
  x += rotl32(r_div, 7u);
  x ^= rotr32(r_divu, 11u);
  x += r_rem;
  x ^= rotl32(r_remu, 17u);
  return x;
}

int main(void)
{
  volatile u32 *m32 = (volatile u32 *)0x80008000u;
  volatile u16 *m16 = (volatile u16 *)0x80008800u;
  volatile u8  *m8  = (volatile u8  *)0x80008C00u;
  u32 i;
  u32 acc = 0x6D2B79F5u;
  u32 s = 0x12345678u;
  u32 t = 0xFEDCBA98u;
  u32 result;

  for (i = 0u; i < W_COUNT; i++) {
    m32[i] = ((0x01020408u * i) ^ 0xA5A5A5A5u) + rotl32(i, i & 7u);
  }
  for (i = 0u; i < H_COUNT; i++) {
    m16[i] = (u16)((i * 257u) ^ (0x5A5Au + (i << 3)));
  }
  for (i = 0u; i < B_COUNT; i++) {
    m8[i] = (u8)((i * 37u) ^ (i >> 1) ^ 0xC3u);
  }

  m8[63] = 0x80u;
  m8[64] = 0x7Fu;
  m8[65] = 0x01u;
  m16[31] = 0x8001u;
  m16[32] = 0x7FFEu;
  m32[15] = 0xCAFEBABEu;
  m32[16] = 0x10203040u;

  acc ^= (u32)(i8)m8[63];
  acc += (u32)m8[64];
  acc ^= (u32)(i16)m16[31];
  acc += (u32)m16[32];
  acc ^= m32[15] + rotl32(m32[16], 9u);

  for (i = 0u; i < ROUNDS; i++) {
    u32 u = kernels[i & 1u](s, t, i);
    u32 v = mext_mix(u ^ acc, t + (i * 0x10201u), i);
    u32 wi = (i * 17u + (v & 31u)) & (W_COUNT - 1u);
    u32 hi = (i * 11u + (u >> 5)) & (H_COUNT - 1u);
    u32 bi = (i * 19u + (acc >> 7)) & (B_COUNT - 1u);
    u32 oldw = m32[wi];
    u32 oldh = m16[hi];
    u32 oldb = m8[bi];
    int sb;
    u32 ub;
    int sh;
    u32 uh;

    m32[(wi + 3u) & (W_COUNT - 1u)] = oldw ^ u ^ v;
    m16[(hi + 5u) & (H_COUNT - 1u)] = (u16)(oldh + (v >> 16) + i);
    m8[(bi + 7u) & (B_COUNT - 1u)] = (u8)(oldb ^ u ^ (v >> 8));

    sb = (int)(i8)m8[(bi + 9u) & (B_COUNT - 1u)];
    ub = (u32)m8[(bi + 13u) & (B_COUNT - 1u)];
    sh = (int)(i16)m16[(hi + 17u) & (H_COUNT - 1u)];
    uh = (u32)m16[(hi + 19u) & (H_COUNT - 1u)];

    acc ^= oldw + (oldh << 16) + oldb;
    acc += ((u32)sb ^ (ub << 8) ^ (u32)sh ^ (uh << 16));

    if ((int)(acc ^ u) < (int)(v | 1u)) {
      s = rotl32(s + u + acc, (i & 7u) + 1u);
      acc ^= m32[(wi ^ 0x2Du) & (W_COUNT - 1u)];
    } else {
      s = rotr32(s ^ v ^ acc, (i & 7u) + 1u);
      acc += m32[(wi + 0x31u) & (W_COUNT - 1u)];
    }

    if (t < acc) {
      t ^= v + i;
    } else {
      t += u ^ (i * 0x01010101u);
    }

    if ((i & 7u) == 3u) {
      m32[wi] = acc;
      m16[hi] = (u16)(acc >> 8);
      m8[bi] = (u8)(acc >> 16);
    }
  }

  for (i = 0u; i < W_COUNT; i += 3u) {
    acc ^= m32[i];
    acc += rotl32(m32[(i + 11u) & (W_COUNT - 1u)], (i & 7u) + 1u);
    acc ^= (acc >> 13);
  }
  for (i = 1u; i < H_COUNT; i += 5u) {
    acc += (u32)m16[i];
    acc ^= (u32)(i16)m16[(i + 3u) & (H_COUNT - 1u)];
    acc += (acc << 3);
    acc ^= (acc >> 7);
  }
  for (i = 2u; i < B_COUNT; i += 7u) {
    acc ^= (u32)m8[i];
    acc += (u32)(i8)m8[(i + 5u) & (B_COUNT - 1u)];
    acc += (acc << 1);
    acc ^= (acc >> 9);
  }

  acc ^= s ^ rotl32(t, 3u);
  acc += (acc << 5);
  acc ^= (acc >> 11);
  acc += (acc << 9);
  acc ^= (acc >> 15);

  if (acc == EXPECT_HASH) {
    result = PASS_SIG;
  } else {
    result = FAIL_SIG;
  }

  asm volatile("mv a0, %0" :: "r"(result) : "a0");
  for (;;) { }
}
