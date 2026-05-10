# Reproduce 說明

本文件說明如何從一份新的 repository clone 重現本專案的 build、simulation verification、Vivado bitstream，以及 FPGA board 上的 UART/VGA 執行流程。

目標是讓其他人不用依賴你電腦上的絕對路徑，也能照著步驟重建結果。

## Reproduce 範圍

本專案的可重現流程分成四層：

| 層級 | 目標 | 是否一定要 Vivado |
| --- | --- | --- |
| Software build | 從 C source 產生 `.elf`、`.bin`、`.mem` | No |
| RTL simulation | 用 Icarus Verilog / vvp 跑 testbench 與 regression | No |
| Vivado FPGA build | 生成 IP、synthesis、implementation、bitstream | Yes |
| Board run | 下載 bitstream，透過 UART bootloader 載入 `.mem` | Yes |

如果只是檢查 CPU/RTL 功能，前兩層就能先做大量驗證。若要重現實機展示，還需要 Vivado 與 Nexys A7-100T board。

## 需要準備的工具

建議版本以目前專案測試環境為準：

| Tool | 用途 | 建議處理方式 |
| --- | --- | --- |
| Python 3.13.1 | build scripts、bin-to-mem、UART loader | 安裝後確認 `python --version`。 |
| GNU Make | 呼叫 Makefile | 安裝後確認 `make --version`。 |
| Icarus Verilog / vvp | RTL simulation | 安裝後確認 `iverilog -V`、`vvp -V`。 |
| RISC-V GNU toolchain | 編譯 bare-metal C | 從 GitHub Release 下載，不直接 commit 進 Git。 |
| Vivado | 生成 IP、bitstream、timing/CDC report | FPGA build 與 board run 才需要。 |
| pyserial | UART 送 `.mem` 到板子 | board run 才需要。 |

建議把實際版本記錄下來：

```powershell
python --version
make --version
iverilog -V
vvp -V
vivado -version
```

若 `vivado` 不在 PATH，可以在 Vivado GUI 的 Help / About 或 Tcl Console 查看版本。

## Step 1: Clone Repository

在新環境中 clone 專案：

```powershell
git clone <your-repo-url>
cd cpu_design-main
```

確認工作區狀態：

```powershell
git status --short
```

若要重現某次 submission/release，應 checkout 對應 commit 或 tag：

```powershell
git checkout <commit-or-tag>
```

## Step 2: 還原 RISC-V Toolchain

RISC-V compiler 解壓後很大，不建議 commit 進 repository。本專案採用：

```text
Git repository:
  保存原始碼、RTL、scripts、docs、test files

GitHub Release:
  保存大型 toolchain zip
```

目前建議使用的 Release asset：

```text
tag: toolchain-v15.2.0-win64
asset: xpack-riscv-none-elf-gcc-win64-v15.2.0.zip
asset: SHA256SUMS.txt
```

下載後先比對 hash：

```powershell
Get-FileHash .\xpack-riscv-none-elf-gcc-win64-v15.2.0.zip -Algorithm SHA256
Get-Content .\SHA256SUMS.txt
```

確認 zip hash 與 `SHA256SUMS.txt` 內紀錄一致後，再解壓。

Makefile 預期的本地 toolchain layout 是：

```text
toolchain/
  xpack-riscv-none-elf-gcc/
    bin/
      riscv64-unknown-elf-gcc.exe
      riscv-none-elf-objcopy.exe
      riscv-none-elf-objdump.exe
```

如果 zip 解壓後的資料夾名稱不同，請把「含有 `bin/` 的 toolchain 根目錄」改名或移動成：

```text
toolchain/xpack-riscv-none-elf-gcc
```

檢查：

```powershell
Test-Path .\toolchain\xpack-riscv-none-elf-gcc\bin\riscv64-unknown-elf-gcc.exe
Test-Path .\toolchain\xpack-riscv-none-elf-gcc\bin\riscv-none-elf-objcopy.exe
Test-Path .\toolchain\xpack-riscv-none-elf-gcc\bin\riscv-none-elf-objdump.exe
```

三個結果都應該是 `True`。

補充：

- `.gitignore` 已忽略 `toolchain/*`，只保留 `toolchain/README.md`。
- 如果不想放在 repo 內，也可以放在 `C:/riscv/xpack-riscv-none-elf-gcc/bin`，或用 `TOOLCHAIN_BIN=...` 覆寫。
- 不要把解壓後的 1GB+ compiler 直接加入 git commit。

## Step 3: 檢查 Build Tools

在 repository root 執行：

```powershell
make print-config
make check-tools
```

重點檢查：

- `TOOLCHAIN_BIN` 是否指到你剛剛還原的 toolchain。
- `CC_PREFIX` 是否能找到 `riscv64-unknown-elf-gcc`。
- `BINUTILS_PREFIX` 是否能找到 `riscv-none-elf-objcopy` / `objdump`。
- Python、GCC、objcopy、objdump 都能執行。

如果 PowerShell 無法執行 `.ps1` script，可使用單次 bypass：

```powershell
powershell -ExecutionPolicy Bypass -File tools/run_multiseed_regression.ps1
```

## Step 4: 重現 C-to-MEM Build

先跑預設 build：

```powershell
make mem
```

預期輸出：

```text
build_os/game.elf
build_os/game.bin
build_os/game.map
TEST_FILES/mem_game.mem
```

產生反組譯：

```powershell
make disasm
```

預期輸出：

```text
build_os/game.dis
```

如果要重現獨立系統壓測程式：

```powershell
make test29-independent-stress
```

預期輸出：

```text
TEST_FILES/mem_test29_independent_system_stress.mem
```

如果要重現 VGA game/menu slot image：

```powershell
make vga-games-menu
```

預期輸出：

```text
TEST_FILES/mem_vga_games_menu.mem
build_os/vga_slot_suite/
```

更多 C-to-MEM 細節請看 `docs/C_TO_MEM_BUILD_FLOW.md`。

## Step 5: 重現 RTL Simulation

快速 sanity check：

```powershell
make uart-mmio-tb
make vga-subsystem-tb
```

完整一點的子系統與 RV32M 驗證：

```powershell
powershell -ExecutionPolicy Bypass -File tools/run_muldiv_verification.ps1 -Iverilog iverilog
```

預期輸出：

```text
build_muldiv_verification/summary.txt
build_muldiv_verification/summary.csv
```

系統多 seed regression：

```powershell
powershell -ExecutionPolicy Bypass -File tools/run_multiseed_regression.ps1 `
  -Tests "24,25,26,27" `
  -SeedStart 1 `
  -SeedCount 20 `
  -RandMem 1 `
  -AssertEn 1
```

預期輸出：

```text
build_multiseed/summary.txt
build_multiseed/summary.csv
build_multiseed/t<TEST>_s<SEED>.log
```

TEST29 independent system verification：

```powershell
powershell -ExecutionPolicy Bypass -File tools/run_independent_system_verification.ps1 `
  -SeedStart 1 `
  -SeedCount 10
```

預期輸出：

```text
build_independent_system_verification/report.txt
build_independent_system_verification/deterministic/summary.txt
build_independent_system_verification/random_stall/summary.txt
```

更完整驗證流程請看 `docs/VERIFICATION.md`。

## Step 6: 重現 Vivado Project / Bitstream

Vivado project 不是單純由 Icarus simulation 產生，必須重新建立或開啟 Vivado project，並確保 IP output products 正確。

目標板：

```text
Nexys A7-100T
Part: xc7a100tcsg324-1
```

可選 top：

| Top | 用途 | Constraint |
| --- | --- | --- |
| `board_top` | DDR2 + UART，非 VGA top | `Nexys-A7-100T-Master.xdc` |
| `board_top_vga` | DDR2 + UART + VGA | `xdc_for_vga.xdc` |

Vivado project 需要加入：

- 主線 RTL source files。
- `clk_wiz_0` Clocking Wizard IP。
- `mig_7series_0` DDR2 MIG IP。
- active MIG 產生的 DDR2 XDC。
- 對應 top 的 board-level XDC。

目前保存的 MIG 參考設定：

```text
ddr2_ip_file/mig_b.prj
ddr2_ip_file/design_1_mig_7series_0_0.xdc
```

注意：

- `ddr2_ip_file/` 保存的是重建 MIG 的參考設定，不等於完整 Vivado generated IP output products。
- `MIG_DDR2_interface.v` 是 simulation/reference helper，不要拿它取代正式 Vivado MIG IP。
- `clock_interface.v` 是 Clocking Wizard 介面參考，正式 project 應使用 `clk_wiz_0` IP。

Vivado 細節請照 `docs/VIVADO_SETUP.md`。該文件列出 source file、不要加入的檔案、IP 設定、clock 設定與常見錯誤。

完成 synthesis / implementation 後，至少檢查：

```tcl
report_clocks
report_cdc
report_timing_summary
report_utilization
```

關鍵檢查：

- `ui_clk` 是否和文件/設計假設一致。
- DDR2 MIG `init_calib_complete` 能在板上亮起 LED0。
- VGA framebuffer 是否被推成預期的 block RAM / dual-port RAM 類結構。
- timing summary 是否通過。

## Step 7: 重現 Board Run

先安裝 UART 需要的 Python 套件：

```powershell
python -m pip install pyserial
```

查 Windows COM port：

```powershell
Get-WmiObject Win32_SerialPort | Select-Object DeviceID,Name
```

下載 bitstream 到 FPGA 後，按 reset 讓 bootloader 回到等待狀態。然後傳送 `.mem`：

```powershell
python uart_send_mem.py --port COM5 --baud 115200 --mem TEST_FILES/mem_game.mem --delay 1.0 --preamble 4096 --interactive
```

請把 `COM5` 換成你的實際 COM port。

如果是 VGA game/menu：

```powershell
python uart_send_mem.py --port COM5 --baud 115200 --mem TEST_FILES/mem_vga_games_menu.mem --delay 1.0 --preamble 4096 --interactive
```

板上基本判讀：

- LED0 亮：DDR2 MIG calibration done。
- LED10 閃爍：`ui_clk` domain 正在跑。
- LED6 亮：UART bootloader done，CPU 已釋放執行。
- 使用 `board_top_vga` 時，VGA 顯示器應有 hsync/vsync/RGB 輸出。

LED 詳細對應請看 `docs/BOARD_IO.md`。

## Reproducibility Checklist

提交前建議逐項確認：

- `git status --short` 已記錄。
- repository commit hash 已記錄。
- tool versions 已記錄。
- RISC-V toolchain zip 來自 GitHub Release，且 SHA256 已比對。
- `make check-tools` 通過。
- `make mem` 通過。
- `make test29-independent-stress` 通過。
- `make vga-games-menu` 通過。
- `tools/run_muldiv_verification.ps1` 通過。
- `tools/run_multiseed_regression.ps1` 通過，`Fail=0`。
- `tools/run_independent_system_verification.ps1` 通過。
- Vivado synthesis/implementation/timing 通過。
- `report_clocks`、`report_cdc` 已保存。
- bitstream 可下載到板上。
- UART bootloader 可載入 `.mem`。
- 若使用 VGA top，實機 VGA 畫面可顯示。

## 常見問題

### `riscv64-unknown-elf-gcc` 找不到

檢查 toolchain layout 是否正確：

```powershell
Test-Path .\toolchain\xpack-riscv-none-elf-gcc\bin\riscv64-unknown-elf-gcc.exe
```

如果你的 toolchain 放在別處，使用：

```powershell
make check-tools TOOLCHAIN_BIN=C:/your/toolchain/bin
```

### `riscv-none-elf-objcopy` 找不到

本專案目前 Makefile 預設：

```text
CC_PREFIX       = riscv64-unknown-elf-
BINUTILS_PREFIX = riscv-none-elf-
```

所以需要確認 toolchain 的 `bin/` 裡面有：

```text
riscv64-unknown-elf-gcc.exe
riscv-none-elf-objcopy.exe
riscv-none-elf-objdump.exe
```

若你的 toolchain prefix 不同，需要用 `CC_PREFIX=...` / `BINUTILS_PREFIX=...` 覆寫。

### PowerShell 擋住 script

使用單次 bypass：

```powershell
powershell -ExecutionPolicy Bypass -File tools/run_multiseed_regression.ps1
```

### `pyserial not found`

安裝：

```powershell
python -m pip install pyserial
```

### UART 送完沒有反應

依序檢查：

1. COM port 是否正確。
2. 其他 terminal 是否佔用 COM port。
3. baud 是否為 `115200`。
4. FPGA 是否剛 reset 並停在 bootloader 等待狀態。
5. LED0 是否亮起。
6. LED6 是否在送完後亮起。
7. `.mem` 是否是目前要跑的程式。

### Vivado 找不到 `clk_wiz_0` 或 `mig_7series_0`

通常代表 IP 沒有加入 project，或 output products 沒生成。重新確認：

- `clk_wiz_0` Clocking Wizard IP 已加入。
- `mig_7series_0` MIG IP 已加入。
- IP 沒有 AutoDisabled。
- `Generate Output Products` 已執行。

### Icarus simulation 通過但板上不工作

simulation 通過只代表 RTL 功能在模型中通過。板上還需要檢查：

- Vivado timing 是否通過。
- DDR2 MIG 是否 calibration done。
- XDC 是否和 top 相符。
- UART baud divider 是否和實際 `ui_clk` 一致。
- `.mem` 是否成功透過 UART bootloader 寫入 DDR2。

