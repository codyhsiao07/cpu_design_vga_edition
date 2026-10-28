typedef unsigned int u32;
static volatile u32 seed = 0x13579bdfu;
// volatile effects retain the branches even when compiling with -O2.
static volatile u32 sink;
static __attribute__((noinline)) u32 classify(u32 x)
{
    if (x & 1u) { sink = x; return x + 7u; }
    sink = x ^ 0x1234u;
    return x ^ 0xa5a5u;
}
int main(void)
{
    u32 x = seed, hash = 0, i;
    for (i = 0; i < 256u; i++) {
        x ^= x << 13; x ^= x >> 17; x ^= x << 5;
        hash ^= classify(x);
    }
    return hash == 0x711b70d8u ? 0 : 1;
}
