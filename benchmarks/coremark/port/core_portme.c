/* Timer/seed/I/O adaptation only. Official core_*.c and coremark.h are unchanged. */
#include "coremark.h"
#define PMU(off) (*(volatile ee_u32 *)(0x40010000u + (off)))
#if VALIDATION_RUN
volatile ee_s32 seed1_volatile=0x3415, seed2_volatile=0x3415;
#else
volatile ee_s32 seed1_volatile=0, seed2_volatile=0;
#endif
volatile ee_s32 seed3_volatile=0x66, seed4_volatile=ITERATIONS, seed5_volatile=0;
ee_u32 default_num_contexts=1;
static CORE_TICKS begin_tick, end_tick;
static ee_u32 ticks_per_us;

static CORE_TICKS clock_us(void)
{
    ee_u32 hi, lo, again;
    // PMU remains RUNNING for all of main. Retry avoids a torn 64-bit read.
    do { hi=PMU(0x104); lo=PMU(0x100); again=PMU(0x104); } while(hi != again);
    return (CORE_TICKS)((((ee_u64)hi << 32) | lo) / ticks_per_us);
}
void start_time(void) { begin_tick=clock_us(); }
void stop_time(void) { end_tick=clock_us(); }
CORE_TICKS get_time(void) { return end_tick-begin_tick; }
secs_ret time_in_secs(CORE_TICKS ticks) { return ticks/1000000u; }

void portable_init(core_portable *p, int *argc, char *argv[])
{
    (void)argc; (void)argv;
    ticks_per_us=PMU(0x14)/1000000u;
    if(ticks_per_us == 0 || sizeof(ee_u32) != 4 || sizeof(ee_ptr_int) != sizeof(void *))
        for(;;) { }
    p->portable_id=1;
}

void portable_fini(core_portable *p)
{
    core_results *r=(core_results *)((ee_u8 *)p - offsetof(core_results,port));
#if VALIDATION_RUN
    ee_u32 kind=1;
    ee_u32 ok=r->crclist==0xe3c1 && r->crcmatrix==0x0747 && r->crcstate==0x8d84;
#else
    ee_u32 kind=0;
    ee_u32 ok=r->crclist==0xe714 && r->crcmatrix==0x1fd7 && r->crcstate==0x8e3a;
#endif
    // Main's upstream return value is always zero, even on CRC/time errors.
    // Export explicit CRC validity and precise microsecond kernel time for host validation.
    ee_printf("[COREMARK_BEGIN]\n");
    ee_printf("iterations=%08x\nticks_us=%08x\ndata_size=%08x\nrun_kind=%08x\n",
              r->iterations,get_time(),(ee_u32)TOTAL_DATA_SIZE,kind);
    ee_printf("crc_list=%08x\ncrc_matrix=%08x\ncrc_state=%08x\ncrc_final=%08x\n",
              (ee_u32)r->crclist,(ee_u32)r->crcmatrix,(ee_u32)r->crcstate,(ee_u32)r->crc);
    ee_printf("crc_ok=%08x\ntime_valid=%08x\n[COREMARK_END]\n",
              ok && r->err==0,(ee_u32)(get_time()>=10000000u));
    p->portable_id=0;
}
