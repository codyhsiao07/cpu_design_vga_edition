// Freestanding report transport: hex only, no libc or 64-bit arithmetic helpers.
typedef unsigned int u32;
#define REG(off) (*(volatile u32 *)(0x40010000u + (off)))
#define TX_DATA (*(volatile u32 *)0x40000000u)
#define TX_STATUS (*(volatile u32 *)0x40000004u)

static void putc_uart(char c)
{
    while (!(TX_STATUS & 1u)) { }
    TX_DATA = (unsigned char)c;
}
static void puts_uart(const char *s)
{
    while (*s) putc_uart(*s++);
}
static void hex32(u32 value)
{
    static const char digits[] = "0123456789abcdef";
    int shift;
    for (shift = 28; shift >= 0; shift -= 4)
        putc_uart(digits[(value >> (unsigned)shift) & 15u]);
}
static void field(const char *key, u32 value)
{
    puts_uart(key); putc_uart('='); hex32(value); putc_uart('\n');
}
u32 perf_report(u32 result)
{
    static const char *const names[] = {
        "cycles", "instructions", "ic_access", "ic_miss",
        "dc_load", "dc_load_miss", "dc_store", "dc_store_miss",
        "branches", "branch_misses", "frontend_wait", "memory_wait",
        "load_use_wait", "multiply_wait", "divide_wait"
    };
    unsigned i;
    puts_uart("\n[PERF_BEGIN]\n");
    field("schema", REG(0x24));
    field("features", REG(0x10));
    field("status", REG(4));
    field("return", result);
    field("core_hz", REG(0x14));
    field("ic_bytes", REG(0x18));
    field("dc_bytes", REG(0x1c));
    field("l2_bytes", REG(0x20));
    for (i = 0; i < 15u; i++) {
        puts_uart(names[i]); putc_uart('=');
        hex32(REG(0x104u + i * 8u));
        hex32(REG(0x100u + i * 8u));
        putc_uart('\n');
    }
    puts_uart("[PERF_END]\n");
    return result;
}
