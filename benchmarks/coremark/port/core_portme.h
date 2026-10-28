/* RV32IM bare-metal port of EEMBC CoreMark. Kernels remain upstream originals. */
#ifndef CORE_PORTME_H
#define CORE_PORTME_H
#include <stddef.h>
#include "coremark_build.h"
#define HAS_FLOAT 0
#define HAS_TIME_H 0
#define USE_CLOCK 0
#define HAS_STDIO 0
#define HAS_PRINTF 0
#define COMPILER_VERSION "GCC " __VERSION__
#define MEM_LOCATION "Static DDR2; I/D/L2 caches; see PMU metadata"
typedef signed short ee_s16;
typedef unsigned short ee_u16;
typedef signed int ee_s32;
typedef unsigned char ee_u8;
typedef unsigned int ee_u32;
typedef unsigned long long ee_u64;
typedef ee_u32 ee_ptr_int;
typedef size_t ee_size_t;
#define align_mem(x) (void *)(4 + (((ee_ptr_int)(x)-1) & ~3u))
#define CORETIMETYPE ee_u32
typedef ee_u32 CORE_TICKS; /* microseconds; wraps after ~71 minutes */
#define SEED_METHOD SEED_VOLATILE
#define MEM_METHOD MEM_STATIC
#define MULTITHREAD 1
#define MAIN_HAS_NOARGC 1
#define MAIN_HAS_NORETURN 0
extern ee_u32 default_num_contexts;
typedef struct CORE_PORTABLE_S { ee_u8 portable_id; } core_portable;
void portable_init(core_portable *p, int *argc, char *argv[]);
void portable_fini(core_portable *p);
int ee_printf(const char *fmt, ...);
#endif
