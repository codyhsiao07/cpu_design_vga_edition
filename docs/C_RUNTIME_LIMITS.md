# C Runtime Limits

本文件說明本專案目前的 C 程式執行環境限制。重點是：這不是一般 Windows/Linux 上的 C runtime，而是執行在自製 RV32IM SoC 上的 bare-metal/freestanding 程式。

如果程式會用到 UART 或 VGA，API 使用方式請搭配閱讀 `docs/API_UART_VGA.md`。

## Summary

目前 C 程式的使用原則如下：

| 類型 | 目前狀態 | 說明 |
| --- | --- | --- |
| `int main(void)` | 支援 | 由 `tools/crt0.S` 呼叫，`main` 回傳後 CPU 會停在無限迴圈。 |
| 一般 C 控制流程 | 支援 | `if`、`for`、`while`、function call、struct、array、pointer 可以使用。 |
| 全域變數 / static 變數 | 支援 | `.data` 與 `.bss` 由 linker script 配置在 DDR 空間。 |
| stack local variable | 支援，但容量有限 | stack 放在目前 512 KiB DDR linker 區域頂端，過大的 local array 可能覆蓋程式或資料。 |
| MMIO | 支援 | 需使用 `volatile` pointer 或專案提供的 UART/VGA helper。 |
| `printf` / `scanf` | 目前不支援完整標準函式庫版本 | 因為沒有 OS syscall、stdin/stdout、libc initialization。請改用專案 helper 或自行實作小型 I/O。 |
| `malloc` / `free` | 不支援 | 目前沒有 heap manager。 |
| file I/O | 不支援 | 沒有 file system，也沒有 OS syscall。 |
| thread/process | 不支援 | 目前是單一 bare-metal firmware/application。 |
| interrupt/trap/OS privileged flow | 不支援完整 OS runtime | 目前不應假設有 Linux/RTOS 需要的 privileged CSR、trap handler、timer interrupt、context switch。 |
| floating point | 不建議使用 | 目前預設 `rv32im`，沒有 `F/D` extension。`float/double` 可能需要軟體 helper library，現有 link flow 不保證支援。 |
| 64-bit 複雜運算 | 不建議使用 | RV32 上的 64-bit division/multiply 可能產生 libgcc helper call，現有 `-nostdlib` link flow 不保證支援。 |

## Current Runtime Model

目前 Makefile 預設使用：

```text
-march=rv32im -mabi=ilp32 -ffreestanding -nostdlib -O2 -Wall -Wextra
```

這代表：

- 程式是 freestanding C，不是 hosted C。
- 不使用系統預設 startup file。
- 不連結一般標準 C library。
- 程式入口不是由 OS loader 建立，而是由本專案的 `tools/crt0.S` 提供。
- linker script 使用 `tools/link_ddr.ld`。

目前 `tools/crt0.S` 做的事情很少，刻意保持簡單：

1. 設定 stack pointer 到 `__stack_top`。
2. 設定 global pointer。
3. 清除 `.bss`。
4. 呼叫 `main`。
5. 將 `main` 的回傳值複製到 `x8`，方便 testbench 觀察。
6. 進入無限迴圈。

因此建議 C 程式入口寫成：

```c
int main(void)
{
    /* application code */
    return 0;
}
```

如果程式是互動式 app 或遊戲，通常會自己維持主迴圈：

```c
int main(void)
{
    for (;;) {
        /* update input, logic, output */
    }
    return 0;
}
```

## Memory Layout

目前 `tools/link_ddr.ld` 將程式連結到 DDR 空間：

```text
ORIGIN = 0x80000000
LENGTH = 512K
```

主要 section 配置如下：

| Section | 內容 |
| --- | --- |
| `.text` | startup code、程式碼、唯讀資料。 |
| `.data` | 有初始值的全域/static 變數。 |
| `.bss` | 初始值為 0 或未明確初始化的全域/static 變數。 |
| stack | 放在目前 512 KiB DDR 區域頂端附近。 |

注意事項：

- 這個 512 KiB 是目前 linker script 給 C 程式使用的位址範圍，不代表板上 DDR 實體容量只有 512 KiB。
- 大型 global array、framebuffer copy、大型 local array 都可能讓程式、資料、stack 互相擠壓。
- 若程式變大，應檢查 `build/*.map`，確認 `.text`、`.data`、`.bss` 與 stack 空間是否合理。

## What C Features Are Safe To Use

以下 C 寫法通常可以使用：

```c
static unsigned int counter;

static unsigned int add_score(unsigned int score, unsigned int delta)
{
    return score + delta;
}

int main(void)
{
    unsigned int i;
    unsigned int total = 0;

    for (i = 0; i < 10u; i++) {
        total = add_score(total, i);
    }

    counter = total;
    return (int)counter;
}
```

適合目前 runtime 的寫法包含：

- `int`、`unsigned int`、`char`、array、struct、enum。
- function call 與 small helper function。
- global/static 狀態。
- 小型 local variable。
- 以 `volatile` 存取 MMIO register。
- 不依賴 OS 的純計算邏輯。

編譯器提供的 header，例如 `<stdint.h>`，通常可以用來取得 `uint32_t` 等型別，因為這類 header 不一定需要 runtime library。但只要 header 內的功能會呼叫 libc 或 OS，就不應假設可用。

## Standard Library Limits

目前不應直接使用完整標準函式庫 I/O：

```c
#include <stdio.h>

int main(void)
{
    int x;
    printf("x = %d\n", x);
    scanf("%d", &x);
    return 0;
}
```

上面這類程式在一般電腦上可以執行，是因為背後有：

- C runtime startup。
- libc。
- stdin/stdout/stderr。
- OS syscall。
- terminal 或 console driver。

本專案目前沒有這些環境，所以應改成專案提供的 UART helper，或自己寫 MMIO I/O。

## UART Output Instead Of printf

如果只需要輸出字串與整數，建議使用 `game/games_shared_ui.h`：

```c
#include "games_shared_ui.h"

int main(void)
{
    ui_puts("score = ");
    ui_put_uint(123u);
    ui_putc('\n');
    return 0;
}
```

編譯時要把 helper source 帶進來：

```powershell
make mem SRC=OS/my_uart_app.c EXTRA_SRCS="game/games_shared_ui.c" OUT_NAME=my_uart_app MEM_OUT=TEST_FILES/mem_my_uart_app.mem APP_DEFINES="-DGAME_USE_UART -Igame"
```

如果只想直接操作 UART MMIO，也可以寫：

```c
#define UART_TX_DATA   (*(volatile unsigned int *)0x40000000u)
#define UART_TX_STATUS (*(volatile unsigned int *)0x40000004u)

static void uart_putc(char ch)
{
    while ((UART_TX_STATUS & 1u) == 0u) {
    }
    UART_TX_DATA = (unsigned int)(unsigned char)ch;
}

int main(void)
{
    uart_putc('O');
    uart_putc('K');
    uart_putc('\n');
    return 0;
}
```

重點是 MMIO register 必須用 `volatile`，否則 compiler 可能最佳化掉必要的讀寫。

## UART Input Instead Of scanf

`scanf` 目前不建議使用。應改成讀 UART byte 後自行解析。

最簡單的讀一個字元：

```c
#include "games_shared_ui.h"

int main(void)
{
    int ch;

    ui_puts("press a key: ");
    ch = ui_read_byte_blocking();
    ui_puts("\nyou pressed: ");
    ui_putc((char)ch);
    ui_putc('\n');

    return 0;
}
```

若要讀一個 0 到 99 的十進位數字，可以自行寫簡單 parser：

```c
#include "games_shared_ui.h"

static unsigned int read_uint_0_to_99(void)
{
    unsigned int value = 0u;
    unsigned int digits = 0u;

    for (;;) {
        int ch = ui_read_byte_blocking();

        if (ch >= '0' && ch <= '9' && digits < 2u) {
            ui_putc((char)ch);
            value = value * 10u + (unsigned int)(ch - '0');
            digits++;
        } else if ((ch == '\r') || (ch == '\n')) {
            ui_putc('\n');
            return value;
        }
    }
}

int main(void)
{
    unsigned int value;

    ui_puts("number: ");
    value = read_uint_0_to_99();
    ui_puts("value = ");
    ui_put_uint(value);
    ui_putc('\n');

    return 0;
}
```

這種寫法雖然比 `scanf` 長，但行為是可控的，也不依賴標準輸入系統。

## VGA Output

VGA framebuffer 輸出請使用 `game/vga_fb.h` 與 `game/vga_fb.c`：

```c
#include "vga_fb.h"

int main(void)
{
    vga_fb_set_draw_buffer(0u);
    vga_fb_clear(0u);
    vga_fb_fill_rect4(20u, 20u, 40u, 16u, 4u);
    vga_fb_present_sync();

    for (;;) {
    }
    return 0;
}
```

編譯時要帶入 VGA helper：

```powershell
make mem SRC=OS/my_vga_app.c EXTRA_SRCS="game/vga_fb.c" OUT_NAME=my_vga_app MEM_OUT=TEST_FILES/mem_my_vga_app.mem APP_DEFINES="-Igame"
```

如果 VGA app 同時需要 UART helper：

```powershell
make mem SRC=OS/my_vga_uart_app.c EXTRA_SRCS="game/vga_fb.c game/games_shared_ui.c" OUT_NAME=my_vga_uart_app MEM_OUT=TEST_FILES/mem_my_vga_uart_app.mem APP_DEFINES="-DGAME_USE_UART -Igame"
```

## Dynamic Memory

目前沒有 heap 初始化，也沒有 `malloc/free`。因此不要寫：

```c
#include <stdlib.h>

int main(void)
{
    char *buf = malloc(128);
    free(buf);
    return 0;
}
```

建議改用固定大小的 static/global buffer：

```c
static char buffer[128];

int main(void)
{
    buffer[0] = 'A';
    return 0;
}
```

或使用小型 local array，但要注意 stack 大小：

```c
int main(void)
{
    char small_buffer[32];
    small_buffer[0] = 'A';
    return 0;
}
```

不建議在 function 裡放大型 local array：

```c
int main(void)
{
    char too_large[65536];
    too_large[0] = 0;
    return 0;
}
```

這種寫法可能造成 stack 與 `.bss/.data` 或程式區域重疊。

## Operations That May Pull In Helper Functions

目前 link flow 使用 `-nostdlib`，而 Makefile 沒有額外連結 libc/libgcc。某些 C 寫法可能讓 compiler 產生 helper function call，例如：

- 64-bit division/modulo。
- software floating point。
- 某些 large struct copy。
- 某些 memory operation 被最佳化成 `memcpy`、`memset`、`memcmp`、`memmove`。

如果出現這類狀況，可能在 link 階段看到 unresolved symbol，或在 map/disassembly 中看到 `__...` helper。

建議：

- 優先使用 32-bit integer。
- 避免 `float`、`double`。
- 避免大型 struct by-value 傳遞或回傳。
- 避免依賴標準 `memcpy/memset/strlen`，需要時可在專案內提供自己的小型版本。
- 對新 app 產生 `.mem` 後，檢查 `build/<OUT_NAME>.map`；需要看反組譯時可另外執行 `make disasm` 產生 `build/<OUT_NAME>.dis`。

## Alignment

目前 C 程式應避免未對齊的 word/halfword 存取。建議：

- `unsigned int *` 指向 4-byte aligned address。
- `unsigned short *` 指向 2-byte aligned address。
- MMIO address 依硬體定義使用。
- 不要把任意 `char *` 強制轉成 `unsigned int *` 後讀寫，除非確定位址對齊。

安全範例：

```c
static unsigned int words[4];

int main(void)
{
    unsigned int *p = &words[0];
    p[0] = 0x12345678u;
    return 0;
}
```

應避免的範例：

```c
static unsigned char bytes[8];

int main(void)
{
    unsigned int *p = (unsigned int *)&bytes[1];
    *p = 0x12345678u;
    return 0;
}
```

## Recursion

語法上 recursion 可以編譯，但不建議在目前平台使用。原因是 stack 空間有限，也沒有 stack overflow protection。

不建議：

```c
static unsigned int fib(unsigned int n)
{
    if (n < 2u) {
        return n;
    }
    return fib(n - 1u) + fib(n - 2u);
}
```

建議改成迴圈：

```c
static unsigned int fib_iter(unsigned int n)
{
    unsigned int a = 0u;
    unsigned int b = 1u;
    unsigned int i;

    for (i = 0u; i < n; i++) {
        unsigned int next = a + b;
        a = b;
        b = next;
    }
    return a;
}
```

## printf/scanf 可以改接到 UART/VGA 嗎？

現階段的結論是：目前專案不支援完整標準 `printf` / `scanf`。如果 C 程式需要文字 I/O，請優先使用 `game/games_shared_ui.h` 提供的 UART helper，或依照應用需求自行寫小型輸入 parser。

未來可以加上類似 `printf` / `scanf` 的功能，但要分開看：

| 功能 | 可行方向 | 目前狀態 |
| --- | --- | --- |
| `printf` 輸出到 UART | 可行。底層用 UART TX MMIO 或 `ui_putc` 輸出字元。 | 尚未提供完整 `printf`，目前請使用 `ui_puts`、`ui_put_uint`、`ui_putc`。 |
| `printf` 輸出到 VGA | 可行，但需要先做 VGA text console，例如字型表、游標位置、換行、清畫面。 | 目前 VGA 只有 framebuffer pixel/rectangle API，還沒有共用文字 console layer。 |
| `scanf` 從 UART 讀取 | 可行。底層用 UART RX MMIO 或 `ui_read_byte_blocking` 讀字元，再自己解析。 | 目前建議寫小型 parser，不建議宣稱支援完整 `scanf`。 |
| `scanf` 從 VGA 讀取 | 不合理。VGA 是顯示輸出，不是輸入來源。 | 若需要輸入，應來自 UART、按鍵或其他 input MMIO。 |

如果只是想保留熟悉的函式名稱，可以在未來自己提供小型 wrapper，例如：

```c
#define printf mini_printf
```

但這不代表支援標準 libc 的完整 `printf`。應在文件中明確列出支援的格式，例如只支援：

```text
%c, %s, %u, %d, %x
```

`scanf` 更建議不要直接模仿完整標準格式，因為它要處理空白、錯誤輸入、換行、退格、buffer、格式比對等細節。對目前專案而言，通常比較適合針對遊戲或 app 寫明確的 parser，例如「讀一個方向鍵」、「讀一個 0 到 99 的整數」、「讀一行命令」。

因此比較精準的說法是：

```text
本專案目前不支援完整標準 printf/scanf。
printf 類輸出未來可包裝到 UART，或在完成 VGA text console 後輸出到 VGA。
scanf 類輸入應從 UART 或其他 input MMIO 讀取，再由應用程式自行解析。
```

## Practical Coding Rules

撰寫本專案 C 程式時，建議遵守：

1. 使用 `int main(void)` 或 `int main()`，不要依賴 `argc/argv/envp`。
2. 不使用 OS syscall、file I/O、process、thread。
3. 不直接使用完整 `printf/scanf/malloc/free`。
4. UART I/O 使用 `game/games_shared_ui.h`，VGA I/O 使用 `game/vga_fb.h`。
5. MMIO register 一律使用 `volatile`。
6. 優先使用 32-bit integer，避免 floating point 與複雜 64-bit 運算。
7. 避免 recursion 與大型 local array。
8. 新增 app 後要重新產生 `.mem`，並至少跑對應 testbench 或 FPGA smoke test。
