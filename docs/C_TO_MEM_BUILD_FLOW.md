# C to MEM Build Flow

本文件說明一般 C 程式如何在本專案中編譯成 `.mem` 檔。這裡只說明通用 bare-metal C build flow，不以遊戲專用檔案作為主軸。

如果要了解哪些 C 語法或標準函式庫目前不支援，請先看 `docs/C_RUNTIME_LIMITS.md`。

## Build Goal

本專案的 CPU testbench 與 FPGA boot/load 流程使用 `.mem` 檔作為程式記憶體映像。一般 C 檔會經過以下流程：

```text
your_program.c
  + tools/crt0.S
  + tools/link_ddr.ld
        |
        v
riscv64-unknown-elf-gcc
        |
        v
build_os/<name>.elf
        |
        v
riscv-none-elf-objcopy -O binary
        |
        v
build_os/<name>.bin
        |
        v
tools/bin_to_mem.py
        |
        v
TEST_FILES/mem_<name>.mem
```

最後產生的 `.mem` 是一行一個 32-bit word 的 hexadecimal text file，可以被 Verilog testbench 的 `$readmemh` 載入。

## Minimal Example

假設有一個普通 C 檔：

```c
/* OS/main.c */
int main(void)
{
    return 17;
}
```

使用 Makefile 編譯成 `.mem`：

```powershell
make mem SRC=OS/main.c OUT_NAME=os_main MEM_OUT=TEST_FILES/mem_os_main.mem APP_DEFINES=
```

這個指令的意思是：

- `SRC=OS/main.c`：主要 C source file。
- `OUT_NAME=os_main`：中間輸出檔名稱會使用 `os_main`。
- `MEM_OUT=TEST_FILES/mem_os_main.mem`：最後 `.mem` 輸出路徑。
- `APP_DEFINES=`：清掉 Makefile 預設的 app define，使用最單純的 C build。

成功後會產生：

```text
build_os/crt0.o
build_os/main.o
build_os/os_main.elf
build_os/os_main.bin
build_os/os_main.map
TEST_FILES/mem_os_main.mem
```

如果想看反組譯：

```powershell
make disasm SRC=OS/main.c OUT_NAME=os_main MEM_OUT=TEST_FILES/mem_os_main.mem APP_DEFINES=
```

會產生：

```text
build_os/os_main.dis
```

## Files Used In A Normal Build

一般單檔 C 程式會用到以下檔案：

| File | Role |
| --- | --- |
| `Makefile` | 統一呼叫 compiler、linker、objcopy、bin-to-mem，並管理輸出檔名。 |
| `your_program.c` | 使用者要執行的 C 程式，需提供 `main`。 |
| `tools/crt0.S` | 最小 startup code，負責設定 stack、清 `.bss`、呼叫 `main`。 |
| `tools/link_ddr.ld` | linker script，決定程式放到哪個 address、section 如何排列、stack 放在哪裡。 |
| `tools/bin_to_mem.py` | 將 `.bin` 轉成 Verilog `$readmemh` 可讀的 `.mem`。 |
| RISC-V toolchain | 提供 `gcc`、`objcopy`、`objdump`。 |

如果 C 程式有多個 source file，才需要額外使用 `EXTRA_SRCS`。如果 C 程式要用 UART/VGA helper，才需要另外 include 對應 helper source。這些都不是最小 build flow 的必要項目。

## Makefile Details

Makefile 是建議的主要入口。常用 target：

| Target | Output |
| --- | --- |
| `make mem` | 建立 `.mem`，也是預設目標。 |
| `make elf` | 只建立 `.elf`。 |
| `make bin` | 建立 `.bin`。 |
| `make disasm` | 建立 `.dis` 反組譯檔。 |
| `make print-config` | 印出目前 build 變數。 |
| `make check-tools` | 印出 toolchain 與 Python 版本，確認工具可執行。 |
| `make clean` | 清掉目前 `BUILD_DIR` 與目前設定的 `MEM_OUT`。 |

常用變數：

| Variable | Default | Meaning |
| --- | --- | --- |
| `SRC` | `game/game.c` | 主要 C source file。一般程式應改成自己的檔案，例如 `OS/main.c`。 |
| `EXTRA_SRCS` | empty | 額外 C source files，例如共用函式或 driver。 |
| `CRT0` | `tools/crt0.S` | startup assembly。一般不需要改。 |
| `LDSCRIPT` | `tools/link_ddr.ld` | linker script。一般不需要改。 |
| `BUILD_DIR` | `build_os` | `.o/.elf/.bin/.map/.dis` 輸出資料夾。 |
| `OUT_NAME` | `game` | 輸出檔 basename。 |
| `MEM_OUT` | `TEST_FILES/mem_game.mem` | `.mem` 輸出路徑。 |
| `APP_DEFINES` | `-DGAME_USE_UART` | 傳給 compiler 的 define/include path。一般非遊戲程式常用 `APP_DEFINES=` 清空。 |
| `ARCH` | `rv32im` | RISC-V ISA target。 |
| `PYTHON` | `python` | 用來執行 build helper script。 |
| `TOOLCHAIN_BIN` | auto-selected | RISC-V toolchain `bin` 路徑。 |

確認目前設定：

```powershell
make print-config SRC=OS/main.c OUT_NAME=os_main MEM_OUT=TEST_FILES/mem_os_main.mem APP_DEFINES=
```

確認工具版本：

```powershell
make check-tools
```

## Toolchain Search Order

Makefile 會先找 repo 內的工具鏈：

```text
toolchain/xpack-riscv-none-elf-gcc/bin
```

如果找不到，會 fallback 到：

```text
C:/riscv/xpack-riscv-none-elf-gcc/bin
```

也可以手動覆寫：

```powershell
make mem SRC=OS/main.c OUT_NAME=os_main MEM_OUT=TEST_FILES/mem_os_main.mem APP_DEFINES= TOOLCHAIN_BIN=C:/my_toolchain/bin
```

Makefile 目前使用的工具名稱組合是：

```text
riscv64-unknown-elf-gcc
riscv-none-elf-objcopy
riscv-none-elf-objdump
```

因此 `TOOLCHAIN_BIN` 裡至少要有這三個工具。repo 內 `toolchain/README.md` 說明了建議放置位置；大型 toolchain 壓縮檔建議放在 GitHub Release，不直接 commit 進 repo。

## Compiler Flags

目前 Makefile 預設 CFLAGS：

```text
-march=rv32im -mabi=ilp32 -ffreestanding -nostdlib -O2 -Wall -Wextra $(APP_DEFINES)
```

重點：

- `-march=rv32im`：目標 ISA 是 RV32I + M extension。
- `-mabi=ilp32`：32-bit integer/long/pointer ABI。
- `-ffreestanding`：告訴 compiler 這不是一般 OS hosted C environment。
- `-nostdlib`：不自動連結一般 standard library/startup file。
- `-O2`：使用最佳化。
- `-Wall -Wextra`：開啟常用 warning。
- `$(APP_DEFINES)`：使用者可傳入 `-D...` 或 `-I...`。

因為使用 `-nostdlib`，C 程式不應直接假設完整 `printf`、`scanf`、`malloc`、file I/O 可用。這些限制請看 `docs/C_RUNTIME_LIMITS.md`。

## Linker Flags

目前 Makefile 預設 LDFLAGS：

```text
-march=rv32im -mabi=ilp32 -nostdlib -Wl,-T,tools/link_ddr.ld -Wl,-Map,build_os/<OUT_NAME>.map
```

重點：

- `-Wl,-T,tools/link_ddr.ld`：指定 linker script。
- `-Wl,-Map,...`：產生 `.map` 檔，方便檢查 section 大小與 symbol address。
- `-nostdlib`：link 階段也不自動加入一般 standard library。

## Startup File: tools/crt0.S

`tools/crt0.S` 是目前 C 程式真正的 entry point。linker script 指定：

```text
ENTRY(_start)
```

所以 CPU reset 後執行的不是 `main`，而是 `_start`。`_start` 做的事情是：

1. `la sp, __stack_top`：設定 stack pointer。
2. `la gp, __global_pointer$`：設定 global pointer。
3. 由 `__bss_start` 清到 `__bss_end`：把 `.bss` 清成 0。
4. `call main`：呼叫 C 程式的 `main`。
5. `addi x8, a0, 0`：把 `main` 回傳值放到 `x8`，方便 testbench 檢查。
6. 進入無限迴圈，避免 `main` return 後跳到未知位置。

因此一般 C 程式只要提供：

```c
int main(void)
{
    return 0;
}
```

不需要自己寫 `_start`。除非你要改 startup 行為，否則不要替換 `tools/crt0.S`。

## Linker Script: tools/link_ddr.ld

`tools/link_ddr.ld` 決定程式記憶體配置。目前設定：

```text
MEMORY
{
  DDR (rwx) : ORIGIN = 0x80000000, LENGTH = 512K
}
```

也就是 C 程式會被 link 到：

```text
0x80000000
```

主要 section：

| Section | Contents |
| --- | --- |
| `.text` | startup code、一般 code、read-only data。 |
| `.data` | 有初始值的 global/static data。 |
| `.bss` | 未初始化或初始為 0 的 global/static data。 |
| stack | `__stack_top = ORIGIN(DDR) + LENGTH(DDR) - 4`。 |

目前 `.text` 裡也收了 `.rodata`：

```text
*(.text.start)
*(.text*)
*(.rodata*)
```

這代表字串常數、`const` read-only table 等資料會跟 code 一起放在 DDR 起始區域後面。

需要注意：

- `LENGTH = 512K` 是目前 linker script 給程式使用的範圍，不等於板上 DDR 實體總容量。
- 如果程式很大，應檢查 `.map`，確認 `.text/.data/.bss` 沒有擠壓 stack。
- 如果未來要使用更大的程式空間，需要修改 linker script，並同步確認 testbench/FPGA boot/load path 能載入對應大小。

## Object Files

Makefile 會先編譯 startup 與 C source：

```text
tools/crt0.S  -> build_os/crt0.o
OS/main.c     -> build_os/main.o
```

如果設定：

```powershell
EXTRA_SRCS="src/math_utils.c src/mmio.c"
```

則也會產生：

```text
build_os/math_utils.o
build_os/mmio.o
```

注意：目前 Makefile 使用 source basename 產生 object file 名稱。如果兩個不同資料夾裡有相同檔名，例如：

```text
src/a/common.c
src/b/common.c
```

兩者都會變成：

```text
build_os/common.o
```

這會互相衝突。一般建議避免在同一次 build 的 `SRC/EXTRA_SRCS` 中使用相同 basename。

## ELF Output

`.elf` 是完整的 linked executable，包含 symbol、section、address 等資訊：

```text
build_os/<OUT_NAME>.elf
```

它是最適合 debug 的格式。可以從 `.elf` 產生：

- `.map`：linker map。
- `.dis`：反組譯。
- `.bin`：純 binary image。

如果 link 失敗，常見原因包括：

- C 程式呼叫了未提供實作的函式。
- 使用了會產生 helper call 的語法，例如某些 64-bit division 或 floating point。
- `EXTRA_SRCS` 漏掉某個 source file。
- include path 沒有放進 `APP_DEFINES`。

## MAP Output

`.map` 由 linker 產生：

```text
build_os/<OUT_NAME>.map
```

它可以用來檢查：

- `_start` 是否在 `0x80000000` 附近。
- `main` 的 address。
- `.text/.data/.bss` 大小。
- global/static array 是否太大。
- 是否出現不預期的 helper symbol。

如果你想確認程式是否超出 linker 配置，先看 `.map`。

## BIN Output

`.bin` 是從 `.elf` 轉出的純二進位檔：

```powershell
riscv-none-elf-objcopy -O binary build_os/<OUT_NAME>.elf build_os/<OUT_NAME>.bin
```

`.bin` 不保留 symbol、section 名稱或 debug 資訊，只保留需要載入記憶體的 bytes。下一步 `tools/bin_to_mem.py` 會把 `.bin` 轉成 Verilog 容易載入的文字格式。

## MEM Output Format

`tools/bin_to_mem.py` 的行為是：

1. 讀取 `.bin` 的所有 bytes。
2. 每 4 bytes 組成一個 32-bit word。
3. 如果最後不足 4 bytes，用 `0x00` 補齊。
4. 每個 word 輸出成 8 位 hex，一行一個 word。

組 word 時使用 little-endian：

```text
bytes:  b0 b1 b2 b3
word:   b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
```

例如 `.bin` 前四個 byte 是：

```text
13 00 00 00
```

則 `.mem` 第一行會是：

```text
00000013
```

對目前 linker script 而言，`.mem` 第一行對應的起始 address 是：

```text
0x80000000
```

testbench 會用 `$readmemh` 載入 `.mem`。MIG memory model 也會把每個 32-bit word 拆回 little-endian byte 儲存。

## DIS Output

執行：

```powershell
make disasm SRC=OS/main.c OUT_NAME=os_main MEM_OUT=TEST_FILES/mem_os_main.mem APP_DEFINES=
```

會產生：

```text
build_os/os_main.dis
```

這個檔案可用來檢查：

- 是否真的產生 RV32IM 指令。
- 是否出現不預期的 helper function call。
- `main` 和 `_start` 的實際指令。
- branch/load/store 是否符合預期。

## Building Multiple C Files

本專案的 Makefile 不是用 `make main`、`make keyboard` 這種「檔名就是 target」的方式編譯。一般情況都使用 `make mem`，再用變數告訴 Makefile 哪些 `.c` 檔要一起編譯。

如果一般 C 程式拆成多個檔案，例如：

```text
src/main.c
src/keyboard.c
src/display.c
src/keyboard.h
src/display.h
```

可以這樣 build：

```powershell
make mem SRC=src/main.c EXTRA_SRCS="src/keyboard.c src/display.c" OUT_NAME=my_app MEM_OUT=TEST_FILES/mem_my_app.mem APP_DEFINES="-Isrc"
```

原則：

- `SRC` 放有 `main` 的主要檔案。
- `EXTRA_SRCS` 放其他需要一起 link 的 `.c` 檔。
- `.h` header 不放在 `EXTRA_SRCS`，而是用 `APP_DEFINES="-I資料夾"` 提供 include path。
- 如果需要 define，例如 `-DUSE_UART=1`，也放在 `APP_DEFINES`。

以上面的例子來說：

```text
src/main.c       -> 放在 SRC，因為它提供 main()
src/keyboard.c   -> 放在 EXTRA_SRCS，因為 main.c 會呼叫裡面的函式
src/display.c    -> 放在 EXTRA_SRCS，因為 main.c 會呼叫裡面的函式
src/keyboard.h   -> 不放在 EXTRA_SRCS，只用 -Isrc 讓 compiler 找得到
src/display.h    -> 不放在 EXTRA_SRCS，只用 -Isrc 讓 compiler 找得到
```

如果只有單一檔案：

```text
src/main.c
```

就不需要 `EXTRA_SRCS`：

```powershell
make mem SRC=src/main.c OUT_NAME=my_app MEM_OUT=TEST_FILES/mem_my_app.mem APP_DEFINES="-Isrc"
```

如果 `main.c` include 的 header 放在另一個資料夾，例如：

```text
src/main.c
drivers/keyboard.c
include/keyboard.h
```

則 build 指令可以寫成：

```powershell
make mem SRC=src/main.c EXTRA_SRCS="drivers/keyboard.c" OUT_NAME=my_app MEM_OUT=TEST_FILES/mem_my_app.mem APP_DEFINES="-Iinclude"
```

## Optional UART/VGA Helpers

一般 build flow 不需要 UART/VGA helper。只有當 C 程式真的 include 這些 API 時，才需要加入對應 source。

UART helper：

```powershell
make mem SRC=src/main.c EXTRA_SRCS="game/games_shared_ui.c" OUT_NAME=my_uart_app MEM_OUT=TEST_FILES/mem_my_uart_app.mem APP_DEFINES="-DGAME_USE_UART -Igame"
```

VGA framebuffer helper：

```powershell
make mem SRC=src/main.c EXTRA_SRCS="game/vga_fb.c" OUT_NAME=my_vga_app MEM_OUT=TEST_FILES/mem_my_vga_app.mem APP_DEFINES="-Igame"
```

這些 helper 是專案內可重用的 driver/API，不是 C-to-MEM build flow 本身的必要部分。API 細節請看 `docs/API_UART_VGA.md`。

## PowerShell Script Alternative

`tools/build_mem_from_c.ps1` 是較直接的 PowerShell build script。它會做：

```text
gcc tools/crt0.S your_program.c -T tools/link_ddr.ld -> .elf
objcopy -O binary -> .bin
python tools/bin_to_mem.py -> .mem
```

範例：

```powershell
tools/build_mem_from_c.ps1 -Source OS/main.c -OutMem TEST_FILES/mem_os_main.mem
```

不過正式文件與一般使用建議優先使用 Makefile，原因是：

- Makefile 支援 `EXTRA_SRCS`。
- Makefile 會產生 `.map`。
- Makefile 有 `print-config`、`check-tools`、`disasm`。
- Makefile 的變數比較容易和回歸測試、CI 或助教/審查者重現。

## Running In Simulation

這一段的目的不是「重新編譯 C」，而是「把已經產生的 `.mem` 放進 Verilog testbench，讓模擬版 CPU 跑這個程式」。

整體關係如下：

```text
OS/main.c
   |
   v
make mem
   |
   v
TEST_FILES/mem_os_main.mem
   |
   v
icache_pipeline_tb.v 載入 .mem
   |
   v
CPU 從 0x80000000 開始執行程式
   |
   v
testbench 檢查結果是否符合 EXPECT_VAL
```

Makefile 有 `run-sim` target：

```powershell
make run-sim SRC=OS/main.c OUT_NAME=os_main MEM_OUT=TEST_FILES/mem_os_main.mem APP_DEFINES= SIM_EXPECT_VAL=00000011
```

這個 target 會先確認 `MEM_OUT` 已建立，然後執行：

```text
vvp $(SIM_EXE) +TEST=0 +MEMFILE=$(MEM_OUT) +ASSERT_EN=1 +MAXCYCLES=$(SIM_MAXCYCLES) +EXPECT_RD=$(SIM_EXPECT_RD) +EXPECT_VAL=$(SIM_EXPECT_VAL)
```

各參數意思如下：

| Parameter | Default | Meaning |
| --- | --- | --- |
| `SIM_EXE` | `icache_pipeline_tb.out` | 已經由 Icarus Verilog 編譯好的 testbench executable。 |
| `+TEST=0` | fixed by Makefile | 使用外部 `MEMFILE` 模式，而不是 testbench 內建 test case。 |
| `+MEMFILE=...` | `$(MEM_OUT)` | 要載入的 `.mem` 檔。 |
| `+ASSERT_EN=1` | fixed by Makefile | 開啟 testbench assertion。 |
| `+MAXCYCLES=...` | `500000` | 最多跑幾個 cycle，超過就 timeout。 |
| `+EXPECT_RD=...` | `8` | 預期最後要檢查的暫存器。 |
| `+EXPECT_VAL=...` | `00000011` | 預期該暫存器最後的值。 |

以 `OS/main.c` 為例：

```c
int main(void) {
    return 17;
}
```

`17` 的十六進位是：

```text
0x00000011
```

`tools/crt0.S` 在 `main` return 後會做：

```asm
addi x8, a0, 0
```

也就是把 `main()` 的回傳值從 `a0` 複製到 `x8`。因此 testbench 可以用：

```text
SIM_EXPECT_RD=8
SIM_EXPECT_VAL=00000011
```

確認程式最後是否得到正確結果。

如果你的程式改成：

```c
int main(void)
{
    return 0x55;
}
```

模擬指令就應改成：

```powershell
make run-sim SRC=OS/main.c OUT_NAME=os_main MEM_OUT=TEST_FILES/mem_os_main.mem APP_DEFINES= SIM_EXPECT_VAL=00000055
```

如果你的程式是遊戲、互動式程式或無限迴圈：

```c
int main(void)
{
    for (;;) {
        /* keep running */
    }
    return 0;
}
```

那它不會回到 `crt0.S`，testbench 也就不會看到 `main` return value 被放到 `x8`。這種程式不適合用簡單的 `SIM_EXPECT_VAL` 檢查結束結果，應改用專門的 testbench、UART/VGA 行為檢查、timeout/smoke test，或在測試版本中讓程式在完成後 return 一個 signature。

注意：

- `run-sim` 需要已有 `icache_pipeline_tb.out`；Makefile 的 `run-sim` 只負責跑 `vvp`，不負責重新編譯 Verilog testbench。
- 若 testbench 找不到 `.mem`，請使用正確相對路徑或絕對路徑。
- Vivado xsim 的工作目錄可能不同，必要時要用正確的 `MEMFILE=<path>`。
- 如果模擬 timeout，可能是程式真的跑太久、卡在等待輸入、`MAXCYCLES` 太小，或 CPU/testbench 遇到錯誤。

如果目前沒有 `icache_pipeline_tb.out`，可以先用 Icarus Verilog 編譯一次 testbench。testbench 的 RTL 清單屬於驗證流程，不是 C-to-MEM build 本身的一部分；正式清單應以 `docs/VERIFICATION.md` 或回歸腳本為準。

下面是 Icarus standalone simulation 的概念清單：

```powershell
iverilog -g2005-sv -o icache_pipeline_tb.out `
  icache_pipeline_tb.v `
  icache_pipeline_top.v `
  icache_top.v `
  icache.v `
  IF.v `
  IFID_register.v `
  ID.v `
  IDEX_register.v `
  EX.v `
  booth_multiplier.v `
  restoring_divider.v `
  EXMEM_register.v `
  MEM.v `
  MEMWB_register.v `
  WB.v `
  hazard_unit.v `
  forward_unit.v `
  dcache.v `
  L2_cache.v `
  I_D_arbitration.v `
  branch_predictor.v `
  uart_rx.v `
  uart_tx.v `
  uart_bootloader.v `
  <one source that defines mig_7series_0>
```

關於 MIG 要特別區分：

- 在 Vivado 正式 FPGA project 中，DDR2 MIG 相關檔案應由 Vivado IP generation 產生，不需要把 repo 中複製出來的 `MIG_DDR2_interface.v` 當成使用者必須手動加入的通用檔案。
- 在 standalone Icarus regression 中，因為沒有跑 Vivado IP generation，simulation 仍需要某個 module 定義 `mig_7series_0`。目前專案回歸腳本使用 repo 內的 `MIG_DDR2_interface.v` 作為方便模擬用的 wrapper，讓 `icache_pipeline_top.v` 可以 elaboration。
- 因此 `MIG_DDR2_interface.v` 不應被理解成 C-to-MEM build flow 的必要檔案；它只和 DDR2/MIG 相關的 RTL simulation 或 FPGA IP source set 有關。

編譯完 testbench 後，再執行：

```powershell
make run-sim SRC=OS/main.c OUT_NAME=os_main MEM_OUT=TEST_FILES/mem_os_main.mem APP_DEFINES= SIM_EXPECT_VAL=00000011
```

## Common Commands

建立一般單檔 C 程式：

```powershell
make mem SRC=OS/main.c OUT_NAME=os_main MEM_OUT=TEST_FILES/mem_os_main.mem APP_DEFINES=
```

只建立 ELF：

```powershell
make elf SRC=OS/main.c OUT_NAME=os_main APP_DEFINES=
```

建立 `.mem` 並產生反組譯：

```powershell
make mem disasm SRC=OS/main.c OUT_NAME=os_main MEM_OUT=TEST_FILES/mem_os_main.mem APP_DEFINES=
```

指定不同 build 目錄：

```powershell
make mem SRC=OS/main.c OUT_NAME=os_main BUILD_DIR=build_os_main MEM_OUT=TEST_FILES/mem_os_main.mem APP_DEFINES=
```

指定工具鏈：

```powershell
make mem SRC=OS/main.c OUT_NAME=os_main MEM_OUT=TEST_FILES/mem_os_main.mem APP_DEFINES= TOOLCHAIN_BIN=C:/riscv/xpack-riscv-none-elf-gcc/bin
```

清理目前 build：

```powershell
make clean SRC=OS/main.c OUT_NAME=os_main MEM_OUT=TEST_FILES/mem_os_main.mem APP_DEFINES=
```

## Common Problems

### Toolchain Not Found

現象可能是：

```text
riscv64-unknown-elf-gcc: command not found
```

或 PowerShell 找不到對應 `.exe`。

處理方式：

1. 確認 GitHub Release 的 toolchain zip 已解壓縮。
2. 確認路徑符合 `toolchain/xpack-riscv-none-elf-gcc/bin`。
3. 或用 `TOOLCHAIN_BIN=...` 指定實際路徑。
4. 執行 `make check-tools` 確認版本。

### Undefined Reference

如果 link 階段出現：

```text
undefined reference to ...
```

常見原因：

- 呼叫了沒有實作的 function。
- 忘記把 `.c` 檔放進 `EXTRA_SRCS`。
- 使用了 `printf`、`scanf`、`malloc` 等目前沒有提供的 standard library function。
- 使用了 floating point 或某些 64-bit 運算，導致 compiler 產生 helper call。

處理方式：

- 補上對應 source 到 `EXTRA_SRCS`。
- 改用專案已有 helper 或自行實作小型函式。
- 檢查 `docs/C_RUNTIME_LIMITS.md`。
- 產生 `make disasm` 或檢查 `.map` 看 symbol 來源。

### Header Not Found

如果出現：

```text
fatal error: xxx.h: No such file or directory
```

請把 include path 放到 `APP_DEFINES`：

```powershell
make mem SRC=src/main.c EXTRA_SRCS="src/mmio.c" OUT_NAME=my_app MEM_OUT=TEST_FILES/mem_my_app.mem APP_DEFINES="-Iinclude"
```

### LOAD Segment With RWX Permissions

目前 link 時可能看到類似 warning：

```text
warning: build_os/<OUT_NAME>.elf has a LOAD segment with RWX permissions
```

這是因為 `tools/link_ddr.ld` 目前把 DDR memory region 宣告成：

```text
DDR (rwx)
```

也就是同一段 DDR 區域同時放 code、read-only data、writable data 與 stack。對目前這個簡化 bare-metal runtime 來說，這個 warning 不代表 build 失敗；只要 linker 最後有產生 `.elf/.bin/.mem`，流程仍可繼續。

若未來要做更嚴格的 memory protection 或更接近 OS 的 execution model，才需要把 executable/read-only/writable section 分開設計。

### Wrong Program Loaded

如果模擬結果不像新程式，常見原因：

- `MEM_OUT` 指到舊檔。
- testbench `MEMFILE` 仍使用舊路徑。
- `make clean` 只刪目前設定的 `MEM_OUT`，不是整個 `TEST_FILES/`。
- Vivado/xsim 工作目錄不同，導致相對路徑解析到別的位置。

建議：

- 明確指定 `OUT_NAME` 與 `MEM_OUT`。
- 用 `make print-config` 檢查。
- 模擬時明確傳 `+MEMFILE=<path>`。

## Suggested Review Checklist

交付或重現 build 前，建議檢查：

1. `make print-config` 的 `SRC/EXTRA_SRCS/OUT_NAME/MEM_OUT` 正確。
2. `make check-tools` 可列出 gcc、objcopy、objdump、Python 版本。
3. `build_os/<OUT_NAME>.map` 中程式 section 沒有超出 linker script 範圍。
4. `make disasm` 後沒有不預期的 helper call。
5. `.mem` 檔已更新，且 testbench/Vivado 使用的就是該路徑。
6. 若使用 UART/VGA helper，對應 source 已放在 `EXTRA_SRCS`。
7. 若是純一般 C 程式，已用 `APP_DEFINES=` 清掉不必要的預設 define。
