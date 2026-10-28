typedef unsigned int u32;
#ifndef PERF_ARRAY_WORDS
#define PERF_ARRAY_WORDS 8192u
#endif
static volatile u32 data[PERF_ARRAY_WORDS];
int main(void)
{
    u32 i, pass, sum = 0;
    for (i = 0; i < PERF_ARRAY_WORDS; i++) data[i] = i * 3u + 1u;
    for (pass = 0; pass < 2u; pass++)
        for (i = 0; i < PERF_ARRAY_WORDS; i++) sum += data[i];
    return sum == 3u * PERF_ARRAY_WORDS * (PERF_ARRAY_WORDS - 1u) +
                  2u * PERF_ARRAY_WORDS ? 0 : 1;
}
