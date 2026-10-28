typedef unsigned int u32;
static volatile u32 input = 0x12345678u;
int main(void)
{
    u32 x = input, i;
    for (i = 0; i < 512u; i++) {
        x ^= x << 13; x ^= x >> 17; x ^= x << 5;
        x += i ^ 0x9e3779b9u;
    }
    // Check against an independently calculated deterministic reference.
    return x == 0x75af6034u ? 0 : 1;
}
