# RV32IM FPGA SoC（DDR2 / UART / VGA）

本專案是一個以 Nexys A7-100T / Artix-7 FPGA 為目標的 RISC-V bare-metal SoC。主線設計包含 5-stage pipeline CPU、RV32I/RV32M 指令支援、I-Cache、D-Cache、Unified L2 cache、DDR2 MIG、UART bootloader、UART MMIO，以及 VGA framebuffer。

這個 repository 的目標不是提供可執行作業系統的完整 RISC-V 平台，而是提供一個可從 C 程式一路重建到 `.mem`、可在 RTL simulation 驗證、也可在 FPGA board 上透過 UART boot 到 DDR2 執行的教學與實驗平台。

## 目前範圍

目前主線支援：

- RV32I + RV32M bare-metal 程式。
- 5-stage pipeline：IF / ID / EX / MEM / WB。
- Hazard detection、forwarding、branch redirect。
- Booth multiplier 與 restoring divider。
- L1 I-Cache、L1 D-Cache。
- Unified L2 cache 與 I/D arbitration。
- 透過 Xilinx MIG native `app_*` interface 存取 DDR2。
- UART bootloader：透過 USB-UART 將 `.mem` 載入 DDR2。
- UART MMIO：bare-metal C 程式可做文字輸入/輸出。
- main 全程效能監測：退休／cycles、cache、分支與等待統計，返回後透過 UART 輸出。
- VGA framebuffer：支援簡單圖形/game demo。
- Icarus Verilog 回歸腳本與 Vivado FPGA bring-up 文件。

目前不支援：

- Linux 或一般作業系統。
- RISC-V privileged architecture / CSR / trap / interrupt subsystem。
- 完整 libc、OS syscall、file I/O。
- 完整標準 `printf` / `scanf` / `malloc`。
- hardware floating point extension。

詳細限制請看 [C runtime 限制](docs/C_RUNTIME_LIMITS.md)。

## 文件導覽

建議先從下面文件開始讀：

| 文件 | 用途 |
| --- | --- |
| [PROJECT_OVERVIEW.md](docs/PROJECT_OVERVIEW.md) | 專案用途、架構、top module、memory map、限制總覽。 |
| [REPRODUCE.md](docs/REPRODUCE.md) | 從新環境 clone 後重現 build、verification、Vivado、board run。 |
| [VERIFICATION.md](docs/VERIFICATION.md) | 完整 RTL simulation / regression 驗證流程。 |
| [VIVADO_SETUP.md](docs/VIVADO_SETUP.md) | Vivado project、Clocking Wizard、DDR2 MIG、bitstream 設定。 |
| [BOARD_IO.md](docs/BOARD_IO.md) | Board pins、XDC 選擇、LED 診斷燈號、VGA/UART/DDR2 I/O。 |
| [API_UART_VGA.md](docs/API_UART_VGA.md) | UART/VGA bare-metal API、include/source 檔案、範例。 |
| [PERFORMANCE_MONITOR.md](docs/PERFORMANCE_MONITOR.md) | main 效能量測、UART 報告、測試程式、TB 與實板操作。 |
| [PERFORMANCE_VERIFICATION.md](docs/PERFORMANCE_VERIFICATION.md) | 本次效能監測驗證結果、模擬數據與 synthesis 範圍。 |
| [STANDARD_BENCHMARKS.md](docs/STANDARD_BENCHMARKS.md) | 官方 CoreMark 移植、標準計時、取指改良與 A/B 比較。 |
| [C_TO_MEM_BUILD_FLOW.md](docs/C_TO_MEM_BUILD_FLOW.md) | 一般 C 程式如何編譯成 `.mem`。 |
| [CLOCKING_AND_CDC.md](docs/CLOCKING_AND_CDC.md) | Clock domains、CDC、VGA framebuffer single/double buffer 說明。 |
| [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Toolchain、simulation、Vivado、DDR2、UART、VGA 常見問題排查。 |

## 資料夾結構

| Path | 說明 |
| --- | --- |
| `board_top.v` | 非 VGA FPGA board top，整合 DDR2、UART boot/MMIO、status LED。 |
| `board_top_vga.v` | VGA FPGA board top，包含 DDR2、UART、VGA framebuffer、launcher button。 |
| `icache_pipeline_top.v` | CPU/cache/L2/DDR2/UART/VGA 的主要 SoC top。 |
| `IF.v`, `ID.v`, `EX.v`, `MEM.v`, `WB.v` | 5-stage pipeline 主要 stage。 |
| `icache.v`, `dcache.v`, `L2_cache.v` | cache hierarchy。 |
| `uart_bootloader.v`, `uart_rx.v`, `uart_tx.v` | UART boot 與 UART TX/RX。 |
| `vga_subsystem.v` | VGA framebuffer 與 VGA timing integration。 |
| `game/` | bare-metal UART/VGA helper 與 demo/game source。 |
| `TEST_FILES/` | `.mem` 測試映像與部分 C 測試程式。 |
| `tools/` | build、verification、trace、VGA slot image scripts。 |
| `docs/` | 正式說明文件。 |
| `ddr2_ip_file/` | DDR2 MIG 參考設定/XDC；正式 Vivado project 仍需生成 MIG IP。 |
| `toolchain/` | 本地 toolchain placeholder；大型 compiler zip 放 GitHub Release。 |
| `archive/` | 歷史/舊版參考，不是目前主線。 |

## 工具鏈

RISC-V compiler 不建議直接 commit 到 Git，因為解壓後體積很大。目前建議從 GitHub Release 下載 toolchain zip，並解壓成：

```text
toolchain/
  xpack-riscv-none-elf-gcc/
    bin/
      riscv64-unknown-elf-gcc.exe
      riscv-none-elf-objcopy.exe
      riscv-none-elf-objdump.exe
```

Makefile 搜尋順序：

1. `toolchain/xpack-riscv-none-elf-gcc/bin`
2. `C:/riscv/xpack-riscv-none-elf-gcc/bin`
3. 手動指定 `TOOLCHAIN_BIN=...`

檢查工具：

```powershell
make print-config
make check-tools
```

完整重現方式請看 [REPRODUCE.md](docs/REPRODUCE.md)。

## 將 C 程式編譯成 `.mem`

預設 build：

```powershell
make mem
```

預設會使用：

```text
SRC=game/game.c
OUT_NAME=game
MEM_OUT=TEST_FILES/mem_game.mem
APP_DEFINES=-DGAME_USE_UART
```

編譯自己的 C 檔：

```powershell
make mem SRC=OS/main.c OUT_NAME=os_main MEM_OUT=TEST_FILES/mem_os_main.mem APP_DEFINES=
```

多個 C 檔一起編：

```powershell
make mem SRC=src/main.c EXTRA_SRCS="src/keyboard.c src/display.c" OUT_NAME=my_app MEM_OUT=TEST_FILES/mem_my_app.mem APP_DEFINES="-Isrc"
```

產生反組譯：

```powershell
make disasm SRC=OS/main.c OUT_NAME=os_main MEM_OUT=TEST_FILES/mem_os_main.mem APP_DEFINES=
```

更多細節請看 [C_TO_MEM_BUILD_FLOW.md](docs/C_TO_MEM_BUILD_FLOW.md)。

## 快速驗證

快速確認 build 與基本 testbench：

```powershell
make check-tools
make mem
make uart-mmio-tb
make vga-subsystem-tb
```

子系統與 RV32M 驗證：

```powershell
powershell -ExecutionPolicy Bypass -File tools/run_muldiv_verification.ps1 -Iverilog iverilog
```

系統多 seed regression：

```powershell
powershell -ExecutionPolicy Bypass -File tools/run_multiseed_regression.ps1
```

獨立系統壓測：

```powershell
powershell -ExecutionPolicy Bypass -File tools/run_independent_system_verification.ps1
```

完整驗證策略、TEST 編號、plusargs、pass/fail 判讀請看 [VERIFICATION.md](docs/VERIFICATION.md)。

## FPGA / Vivado 流程

目標板卡：

```text
Nexys A7-100T
Part: xc7a100tcsg324-1
```

主要 top：

| Top | 用途 | Board XDC |
| --- | --- | --- |
| `board_top` | DDR2 + UART boot/MMIO，非 VGA app | `Nexys-A7-100T-Master.xdc` |
| `board_top_vga` | DDR2 + UART + VGA framebuffer/game/menu | `xdc_for_vga.xdc` |

Vivado project 需要：

- 主線 RTL source。
- `clk_wiz_0` Clocking Wizard IP。
- `mig_7series_0` DDR2 MIG IP。
- active MIG 產生的 DDR2 XDC。
- 對應 top 的 board-level XDC。

不要把 `MIG_DDR2_interface.v` 當作正式 Vivado MIG IP 替代品。它主要是 repository 內保留的 simulation/reference helper。正式 FPGA project 應使用 Vivado 生成的 MIG IP output products。

Vivado 設定請看 [VIVADO_SETUP.md](docs/VIVADO_SETUP.md)。Board pins 與 LED 診斷請看 [BOARD_IO.md](docs/BOARD_IO.md)。

## 板上執行

安裝 UART loader 需要的 Python package：

```powershell
python -m pip install pyserial
```

查 COM port：

```powershell
Get-WmiObject Win32_SerialPort | Select-Object DeviceID,Name
```

下載 bitstream 後，透過 UART bootloader 傳送 `.mem`：

```powershell
python uart_send_mem.py --port COM5 --baud 115200 --mem TEST_FILES/mem_game.mem --delay 1.0 --preamble 4096 --interactive
```

VGA game/menu image：

```powershell
make vga-games-menu
python uart_send_mem.py --port COM5 --baud 115200 --mem TEST_FILES/mem_vga_games_menu.mem --delay 1.0 --preamble 4096 --interactive
```

請把 `COM5` 換成你的實際 COM port。

板上最基本判讀：

- LED0 亮：DDR2 MIG calibration done。
- LED10 閃爍：`ui_clk` domain 在跑。
- LED6 亮：UART bootloader done，CPU 已開始執行。

如果板上沒有反應，先看 [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)。

## 記憶體映射

常用位址：

| Address / Range | 功能 |
| --- | --- |
| `0x8000_0000` | DDR program reset/start address。 |
| `0x8000_0000` and above | DDR-backed instruction/data memory。 |
| `0x4000_0000` | UART TX data。 |
| `0x4000_0004` | UART TX status。 |
| `0x4000_0008` | UART RX data。 |
| `0x4000_000C` | UART RX status。 |
| `0x4000_0010` | Launcher button/status MMIO。 |
| `0x4000_0014` | Launcher reset request MMIO。 |
| `0x4001_0000..0x4001_0FFF` | 效能監測器 MMIO。 |
| `0x5000_0000` | VGA framebuffer base。 |
| `0x5000_7FFC` | VGA framebuffer control / display buffer select。 |

UART/VGA C API 請看 [API_UART_VGA.md](docs/API_UART_VGA.md)。

## 可重現性

提交或發布時，建議記錄：

- Git commit hash。
- `git status --short`。
- Python / Make / Icarus Verilog / Vivado 版本。
- RISC-V toolchain Release asset 與 SHA256。
- 跑過的 verification scripts 與 seed range。
- Vivado `report_clocks`、`report_cdc`、`report_timing_summary`。

完整 checklist 請看 [REPRODUCE.md](docs/REPRODUCE.md) 和 [VERIFICATION.md](docs/VERIFICATION.md)。
