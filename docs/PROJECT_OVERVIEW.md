# Project Overview

本專案是一個以 FPGA 實作為目標的 RISC-V SoC 教學與驗證專案。主線設計是一顆 5-stage pipeline CPU，搭配 L1 I-Cache、L1 D-Cache、Unified L2 cache、DDR2 MIG、UART MMIO、UART bootloader，以及 VGA framebuffer。專案同時提供 bare-metal C 程式、遊戲範例、測試記憶體映像與模擬回歸腳本，目標是讓設計可以從 C 程式一路重建成 `.mem`，再透過 testbench 或 Vivado/FPGA 流程驗證。

## Design Goal

本專案主要用途：

- 驗證 RV32I/RV32M CPU pipeline、hazard、forwarding、branch redirect、load-store、乘除法與 cache 行為。
- 展示 CPU、cache、DDR2、UART、VGA framebuffer 的完整 SoC 整合。
- 支援以 bare-metal C 撰寫應用程式，透過 RISC-V toolchain 產生 `.mem` 映像。
- 提供可重現的模擬與回歸測試流程，作為研討會投稿與設計驗證資料。

## Top-Level Architecture

目前主線硬體路徑如下：

```text
board_top.v
  |
  +-- clock_bridge.v
  |
  +-- icache_pipeline_top.v
        |
        +-- IF / ID / EX / MEM / WB pipeline
        +-- branch_predictor.v
        +-- hazard_unit.v
        +-- forward_unit.v
        +-- booth_multiplier.v
        +-- restoring_divider.v
        +-- icache_top.v / icache.v
        +-- dcache.v
        +-- I_D_arbitration.v
        +-- L2_cache.v
        +-- DDR2 MIG IP / wrapper
        +-- uart_bootloader.v
        +-- uart_rx.v / uart_tx.v
```

主要模組角色：

- `board_top.v`：不含 VGA 輸出的 FPGA board-level top，整合 clock、DDR2、UART boot、UART MMIO、status LED/debug signal 與 CPU SoC。適合 DDR2/UART bring-up、UART bootloader 驗證、非 VGA 的 bare-metal 程式執行。
- `board_top_vga.v`：含 VGA 輸出的 FPGA board-level top，功能等同 `board_top.v`，但額外啟用 VGA framebuffer path、VGA HSYNC/VSYNC/RGB pin、launcher button input，並在 `icache_pipeline_top.v` 內使用 `USE_VGA=1`。適合執行 VGA game/menu demo。
- `icache_pipeline_top.v`：CPU/cache/DDR2/UART/VGA 的核心 SoC top。
- `icache_pipeline_tb.v`：主要 system-level 模擬 testbench。
- DDR2 MIG IP / wrapper：實機 Vivado 專案應使用 Vivado 產生的 MIG IP output products。repo 內的 `MIG_DDR2_interface.v` 是為了方便參考與 standalone simulation 而保留的複製 wrapper，不應被視為 C-to-MEM build 必要檔案。
- `vga_subsystem.v`：VGA framebuffer 顯示子系統。
- `uart_bootloader.v`：透過 UART 載入 `.mem`/program image 的 bootloader 路徑。

板級 top 選擇建議：

| Top module | 用途 | 是否含 VGA | 主要 I/O |
| --- | --- | --- | --- |
| `board_top.v` | UART/DDR2 bring-up、非 VGA bare-metal app、UART smoke/debug | No | clock, reset, DDR2, UART, status |
| `board_top_vga.v` | VGA game/menu demo、framebuffer app、launcher button flow | Yes | clock, reset, DDR2, UART, VGA, launcher button, status |

## CPU Feature Set

目前軟體 build 預設使用：

```text
ARCH=rv32im
ABI=ilp32
```

CPU 目前驗證重點包含：

- RV32I 整數指令基本功能。
- RV32M 乘除法指令：`mul`、`mulh`、`mulhsu`、`mulhu`、`div`、`divu`、`rem`、`remu`。
- 5-stage pipeline hazard/forwarding。
- load-use stall。
- branch taken / not-taken / redirect scenario。
- I-Cache / D-Cache / L2 cache miss、writeback 與 DDR2 存取。
- UART MMIO 與 VGA framebuffer 存取。

## Execution Environment Limits

本專案目前的 CPU/SoC 是 bare-metal application platform，不是可直接執行一般作業系統的完整 RISC-V platform。這裡的「不能執行作業系統的指令」主要指目前尚未完整支援 RISC-V privileged architecture 與 OS runtime 所需機制。

目前可執行的是：

- RV32I/RV32M bare-metal C 程式。
- 直接透過 MMIO 存取 UART、VGA framebuffer 與 launcher control。
- 由 `tools/crt0.S` 啟動、由 `tools/link_ddr.ld` 連結到 DDR 空間的單一程式映像。

目前不應假設支援的是：

- Linux、一般桌面 OS、或完整 RTOS。
- 標準 OS syscall，例如一般環境下 `printf`/`scanf` 會依賴的 host/OS I/O。
- RISC-V privileged CSR/trap flow，例如完整的 `mstatus`、`mie`、`mip`、`mtvec`、`mepc`、`mcause`、`mscratch`。
- 完整 exception/interrupt handling，例如 `ecall`、`ebreak`、illegal instruction trap、timer interrupt、external interrupt。
- 虛擬記憶體、process/thread、file system、dynamic loader。

換句話說，目前程式應寫成「單一 bare-metal firmware/application」。如果未來要支援 RTOS 或 Linux-like software，需要額外設計 CSR、trap/exception、timer interrupt、interrupt controller、context switch ABI，以及相對應的 runtime/driver。

## Memory Map

目前常用記憶體與 MMIO 位址如下：

| Address Range / Address | Function |
| --- | --- |
| `0x8000_0000` | DDR program reset/start address |
| `0x8000_0000` and above | DDR-backed instruction/data memory |
| `0x4000_0000` | UART TX data |
| `0x4000_0004` | UART TX status |
| `0x4000_0008` | UART RX data |
| `0x4000_000C` | UART RX status |
| `0x4000_0010` | Launcher button/status MMIO |
| `0x4000_0014` | Launcher reset request MMIO |
| `0x5000_0000` | VGA framebuffer base |
| `0x5000_7FFC` | VGA framebuffer control / display buffer select |

VGA framebuffer 目前使用 160x120 logical resolution，每個 pixel 使用 4-bit color index。`game/vga_fb.h` 與 `game/vga_fb.c` 提供基本 framebuffer API。

## Software Model

本專案的 C 程式是 bare-metal/freestanding 程式，不是一般 OS 環境下的 C program。預設編譯旗標包含：

```text
-ffreestanding -nostdlib -march=rv32im -mabi=ilp32
```

因此：

- 程式入口由 `tools/crt0.S` 提供。
- linker script 使用 `tools/link_ddr.ld`。
- 程式預設連結到 DDR address space，從 `0x8000_0000` 開始。
- 一般標準函式庫 I/O，例如完整 `printf`、`scanf`，目前不是預設支援項目。
- UART/VGA I/O 目前透過專案內的 lightweight helper 與 MMIO API 使用。

更完整的 C runtime 限制、可用語法、不可用標準函式庫項目與替代寫法請見 `docs/C_RUNTIME_LIMITS.md`。

## C to MEM Build Flow

一般 C 程式到 `.mem` 的概念流程如下：

```text
.c source
  + tools/crt0.S
  + tools/link_ddr.ld
        |
        v
riscv64-unknown-elf-gcc
        |
        v
.elf
        |
        v
riscv-none-elf-objcopy -O binary
        |
        v
.bin
        |
        v
tools/bin_to_mem.py
        |
        v
.mem
```

Makefile 已支援這個流程。預設工具鏈搜尋順序：

1. `toolchain/xpack-riscv-none-elf-gcc/bin`
2. `C:/riscv/xpack-riscv-none-elf-gcc/bin`
3. 使用者透過 `TOOLCHAIN_BIN`、`CC_PREFIX`、`BINUTILS_PREFIX` 覆寫

詳細 build 指令、輸出檔案與常見設定應放在 `docs/C_TO_MEM_BUILD_FLOW.md`。

## Repository Layout

目前建議閱讀的主要資料夾：

| Path | Purpose |
| --- | --- |
| `game/` | VGA game demos, shared UI helpers, framebuffer API |
| `OS/` | OS/bare-metal C experiment source |
| `TEST_FILES/` | simulation `.mem` images and C stress programs |
| `tools/` | build scripts, regression scripts, trace tools |
| `toolchain/` | local toolchain placeholder; compiler binary is distributed by GitHub Release |
| `spec/` | cache/L2 design specifications |
| `docs/` | project documentation |
| `archive/` | historical/reference modules not used as the current mainline |

## Verification

本專案提供多層級驗證：模組級 testbench、UART/VGA subsystem testbench、pipeline regression、多 seed 隨機 stall regression，以及獨立 full-system stress test。詳細測試指令、測試清單、預期 PASS 結果與重跑方式應放在 `docs/VERIFICATION.md`。

## FPGA Build

FPGA 實作需要 Vivado project、主線 RTL、board constraints、DDR2 MIG IP 與 clock wizard IP。`board_top.v` 與 `board_top_vga.v` 分別對應非 VGA 與 VGA 板級整合情境。詳細 Vivado project 建立、IP 產生、constraint 加入、synthesis/implementation/bitstream 設定應放在 `docs/VIVADO_SETUP.md`。

## Scope of Archive

`archive/` 放的是歷史設計、替代 top、早期 cache/storage 實作或暫存參考資料。它們可以保留供追溯，但不應被視為目前主線 build/verification path。正式使用時，請以 root-level RTL、`game/`、`TEST_FILES/`、`tools/` 與 `docs/` 為主。
