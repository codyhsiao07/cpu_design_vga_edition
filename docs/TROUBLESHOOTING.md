# Troubleshooting 排錯指南

本文件整理本專案常見問題的排查方式。建議遇到問題時先依照「症狀」找對應章節，再看「檢查方式」和「修法」。

相關文件：

- 重現完整流程：`docs/REPRODUCE.md`
- 驗證流程：`docs/VERIFICATION.md`
- Vivado/IP 設定：`docs/VIVADO_SETUP.md`
- Board I/O / LED：`docs/BOARD_IO.md`
- C runtime 限制：`docs/C_RUNTIME_LIMITS.md`
- C-to-MEM：`docs/C_TO_MEM_BUILD_FLOW.md`
- Clock/CDC：`docs/CLOCKING_AND_CDC.md`

## 先做的基本檢查

不管是哪一類問題，先記錄以下資訊：

```powershell
git status --short
make print-config
make check-tools
```

如果是 simulation 問題，再看該 script 的 summary：

```text
build_muldiv_verification/summary.txt
build_multiseed/summary.txt
build_independent_system_verification/report.txt
build_long_verification/report.txt
```

如果是板上問題，先看 LED：

| LED | 代表意義 | 若不正常，先查 |
| --- | --- | --- |
| LED0 | DDR2 MIG `init_calib_complete` | MIG IP、DDR2 XDC、clock/reset。 |
| LED10 | `ui_clk` heartbeat | Clocking Wizard、MIG `ui_clk`。 |
| LED6 | UART bootloader done | UART 傳輸、bootloader sync、`.mem`。 |
| LED2 | boot 後 PC changed | CPU 是否真的開始取指執行。 |

完整 LED 對應請看 `docs/BOARD_IO.md`。

## 快速症狀索引

| 症狀 | 優先看 |
| --- | --- |
| `riscv64-unknown-elf-gcc` 找不到 | Toolchain 路徑與 Release 解壓。 |
| `riscv-none-elf-objcopy` 找不到 | `BINUTILS_PREFIX` 是否符合 toolchain。 |
| `make mem` 失敗 | C source、`EXTRA_SRCS`、linker、runtime 限制。 |
| `undefined reference to printf/scanf/malloc` | 目前不是完整 libc 環境。 |
| simulation `ASSERT_FAIL` | 找對應 log，通常是 ready/valid/stall protocol。 |
| simulation `TIMEOUT` | 程式卡住、`MAXCYCLES` 太小、等待 UART input。 |
| Vivado `module 'clk_wiz_0' not found` | Clocking Wizard IP 未加入或 output products 未生成。 |
| Vivado 找不到 `mig_7series_0` | DDR2 MIG IP 未加入或 module/interface 不相容。 |
| LED0 不亮 | DDR2 MIG calibration 沒完成。 |
| UART 送完 `.mem` 沒反應 | COM port、baud、reset、bootloader、LED6。 |
| VGA 沒畫面 | top/XDC 選錯、VGA source 未加入、clock/timing、monitor。 |
| GitHub 上傳很慢或 repo 太大 | 不要 commit toolchain，改放 GitHub Release。 |

## Toolchain / Build 問題

### `riscv64-unknown-elf-gcc` 找不到

可能原因：

- GitHub Release 的 toolchain zip 沒解壓。
- 解壓後資料夾名稱不符合 Makefile 預期。
- `TOOLCHAIN_BIN` 指到錯的資料夾。

檢查：

```powershell
Test-Path .\toolchain\xpack-riscv-none-elf-gcc\bin\riscv64-unknown-elf-gcc.exe
make print-config
```

修法：

1. 從 GitHub Release 下載 `xpack-riscv-none-elf-gcc-win64-v15.2.0.zip`。
2. 比對 `SHA256SUMS.txt`。
3. 解壓後把 toolchain 根目錄放成：

```text
toolchain/xpack-riscv-none-elf-gcc
```

如果 toolchain 放在其他位置：

```powershell
make check-tools TOOLCHAIN_BIN=C:/your/toolchain/bin
```

### `riscv-none-elf-objcopy` 或 `objdump` 找不到

可能原因：

- 你的 toolchain prefix 和 Makefile 預設不同。
- Makefile 找到 gcc，但 binutils prefix 不同。

目前 Makefile 預設：

```text
CC_PREFIX       = $(TOOLCHAIN_BIN)/riscv64-unknown-elf-
BINUTILS_PREFIX = $(TOOLCHAIN_BIN)/riscv-none-elf-
```

檢查：

```powershell
Get-ChildItem .\toolchain\xpack-riscv-none-elf-gcc\bin | Select-Object Name
```

修法：

```powershell
make check-tools `
  TOOLCHAIN_BIN=C:/your/toolchain/bin `
  CC_PREFIX=C:/your/toolchain/bin/riscv64-unknown-elf- `
  BINUTILS_PREFIX=C:/your/toolchain/bin/riscv-none-elf-
```

如果你的 toolchain 使用 `riscv64-unknown-elf-objcopy`，就把 `BINUTILS_PREFIX` 改成對應 prefix。

### `make` 找不到

可能原因：

- Windows 環境沒有安裝 GNU Make。
- 安裝了但沒有加入 PATH。

檢查：

```powershell
make --version
```

修法：

- 安裝 GNU Make。
- 或使用能提供 `make` 的環境，例如 MSYS2、Git Bash、Chocolatey/winget 安裝的 make。
- 確認新的 terminal 能執行 `make --version`。

### `python` 找不到或版本不對

檢查：

```powershell
python --version
```

修法：

- 安裝 Python。
- 確認 PATH 正確。
- 如果系統使用 `py` launcher，可以改用：

```powershell
make mem PYTHON=py
```

### PowerShell 不允許執行 `.ps1`

症狀：

```text
running scripts is disabled on this system
```

修法：使用單次 bypass，不需要永久修改系統政策：

```powershell
powershell -ExecutionPolicy Bypass -File tools/run_multiseed_regression.ps1
```

## C-to-MEM 問題

### `make mem` 編出來的不是我要的 C 檔

原因：

Makefile 預設：

```text
SRC=game/game.c
OUT_NAME=game
MEM_OUT=TEST_FILES/mem_game.mem
APP_DEFINES=-DGAME_USE_UART
```

如果要編自己的 C 檔，請明確指定：

```powershell
make mem SRC=OS/main.c OUT_NAME=os_main MEM_OUT=TEST_FILES/mem_os_main.mem APP_DEFINES=
```

### 多個 C 檔不知道怎麼一起編

不要用 `make main` 或 `make keyboard`。本專案用 `SRC` 加 `EXTRA_SRCS`：

```powershell
make mem `
  SRC=src/main.c `
  EXTRA_SRCS="src/keyboard.c src/display.c" `
  OUT_NAME=my_app `
  MEM_OUT=TEST_FILES/mem_my_app.mem `
  APP_DEFINES="-Isrc"
```

### 找不到 header

症狀：

```text
fatal error: xxx.h: No such file or directory
```

修法：

把 include path 放進 `APP_DEFINES`：

```powershell
make mem SRC=src/main.c OUT_NAME=my_app MEM_OUT=TEST_FILES/mem_my_app.mem APP_DEFINES="-Isrc -Iinclude"
```

### `undefined reference to printf`, `scanf`, `malloc`

原因：

本專案目前是 freestanding bare-metal flow，使用 `-nostdlib`，沒有完整 OS syscall、stdin/stdout、heap manager。

修法：

- 不要直接使用完整 `printf` / `scanf` / `malloc`。
- UART 輸出請用 `game/games_shared_ui.h` 的 helper，例如 `ui_puts()`、`ui_put_uint()`。
- UART 輸入請用 byte-level helper，再自己解析字串或數字。
- 靜態配置陣列，不使用 heap。

詳細限制請看 `docs/C_RUNTIME_LIMITS.md`。

### 使用 `float` / `double` 後 link 失敗或產生 helper call

原因：

目前 build 使用：

```text
ARCH=rv32im
ABI=ilp32
```

沒有 `F/D` floating point extension。`float` / `double` 可能需要 software floating helper library，而目前 link flow 不保證支援。

修法：

- 優先使用 32-bit integer。
- 小數需求改用 fixed-point。
- 編完後檢查 disassembly：

```powershell
make disasm SRC=OS/main.c OUT_NAME=os_main MEM_OUT=TEST_FILES/mem_os_main.mem APP_DEFINES=
```

### `.mem` 沒更新

可能原因：

- 你改了 `MEM_OUT`，但 FPGA 送的是另一個 `.mem`。
- `make clean` 只刪目前設定的 `MEM_OUT`，不是刪全部 `TEST_FILES/*.mem`。
- Vivado/board run 仍載入舊檔。

檢查：

```powershell
Get-Item TEST_FILES/mem_game.mem | Select-Object FullName,LastWriteTime,Length
Get-Item TEST_FILES/mem_your_app.mem | Select-Object FullName,LastWriteTime,Length
```

修法：

明確指定並送同一個檔：

```powershell
make mem SRC=OS/main.c OUT_NAME=os_main MEM_OUT=TEST_FILES/mem_os_main.mem APP_DEFINES=
python uart_send_mem.py --port COM5 --baud 115200 --mem TEST_FILES/mem_os_main.mem --delay 1.0 --preamble 4096 --interactive
```

## Simulation 問題

### `iverilog` 或 `vvp` 找不到

檢查：

```powershell
iverilog -V
vvp -V
```

如果 `run_muldiv_verification.ps1` 預設找 `C:/iverilog/bin/iverilog.exe` 但你的 `iverilog` 在 PATH，使用：

```powershell
powershell -ExecutionPolicy Bypass -File tools/run_muldiv_verification.ps1 -Iverilog iverilog
```

### `ASSERT_FAIL`

意義：

testbench runtime assertion 發現 protocol 不符合預期，常見是 ready/valid stall 期間訊號變動、response watchdog timeout、未知 X 值等。

檢查：

1. 看 `summary.txt` 找出失敗 case。
2. 打開對應 log：

```text
build_multiseed/t<TEST>_s<SEED>.log
```

3. 搜尋：

```text
ASSERT_FAIL
```

修法：

- 若是固定 seed 可重現，先用同一個 `TEST` / `SEED` 單獨重跑。
- 若最近改過 cache/L2/ready-valid，優先檢查 stalled 時 request/response 是否保持 stable。
- 若是 read response watchdog，檢查 response 是否可能被前一筆 transaction 殘留 beat 污染或卡住。

### `TIMEOUT`

可能原因：

- 程式真的跑太久。
- `MAXCYCLES` 太小。
- C 程式卡在等待 UART input。
- CPU 沒有從 reset release。
- `.mem` 內容不符合預期。

修法：

先把 timeout 放大：

```powershell
powershell -ExecutionPolicy Bypass -File tools/run_multiseed_regression.ps1 `
  -Tests 29 `
  -SeedStart 1 `
  -SeedCount 1 `
  -MaxCycles 500000
```

如果仍 timeout：

- 檢查 log 中的 `[TB CFG] MEMFILE=...` 是否是你要的檔。
- 檢查程式是否等待 UART input。
- 檢查 expected register 是否正確。
- 使用 `+TRACE_EN=1` 產生 commit trace 觀察是否還在執行。

### `FATAL: cannot open MEMFILE`

可能原因：

- working directory 不在 repo root。
- `MEMFILE` relative path 不對。
- 在 Vivado xsim 中，模擬 working directory 和 PowerShell 不同。

修法：

使用正確相對路徑或絕對路徑：

```powershell
vvp simv +TEST=24 +MEMFILE=TEST_FILES/mem_test24_from_c.mem
```

在 Vivado xsim 中，可用 testplusarg 指向正確路徑：

```text
-testplusarg MEMFILE=<absolute-or-correct-relative-path>
```

### regression 只有某個 seed 失敗

這通常是好事，代表 random stall 抓到 corner case。

做法：

1. 先保存失敗 log。
2. 用同一個 seed 重跑確認可重現。
3. 降低測試範圍，只跑該 TEST / SEED：

```powershell
powershell -ExecutionPolicy Bypass -File tools/run_multiseed_regression.ps1 `
  -Tests 27 `
  -SeedStart 13 `
  -SeedCount 1 `
  -RandMem 1 `
  -AssertEn 1
```

4. 若和 protocol 有關，優先看 `ASSERT_FAIL` 前後的 request/response log。

## Vivado / IP 問題

### `module 'clk_wiz_0' not found`

可能原因：

- Clocking Wizard IP 沒加入 project。
- IP output products 沒生成。
- IP 被 AutoDisabled。
- 把 `clock_interface.v` 當成正式 wrapper 加入，造成混亂。

修法：

1. 確認 Vivado project 有 `clk_wiz_0.xci`。
2. 右鍵 IP，執行 `Generate Output Products`。
3. `Report IP Status` 確認不是 AutoDisabled / out-of-date。
4. 正式 Vivado source 不要用 `clock_interface.v` 取代 generated IP。

### 找不到 `mig_7series_0`

可能原因：

- DDR2 MIG IP 沒加入 project。
- MIG output products 沒生成。
- 生成的 module name 不是 `mig_7series_0`。
- 生成的是 AXI 介面，不是目前 RTL 期待的 native `app_*` interface。

修法：

1. 確認 MIG IP module name 和 `icache_pipeline_top.v` 例化名稱一致。
2. 確認 port 介面包含 `app_addr`、`app_cmd`、`app_en`、`app_wdf_data`、`app_rdy`、`app_wdf_rdy`、`ui_clk`、`ui_clk_sync_rst`。
3. 若 MIG 生成的是 AXI `s_axi_*` 介面，不能直接接目前 RTL，需要重新生成 native app interface 或修改 RTL。
4. 不要用 root-level `MIG_DDR2_interface.v` 取代正式 Vivado MIG IP。

### `clk_wiz_0` 或 MIG IP 顯示 AutoDisabled

可能原因：

- IP 沒有被目前 top 使用到。
- source hierarchy/top 設錯。
- IP output products 或 generated target 不完整。

修法：

- 確認 top 是 `board_top` 或 `board_top_vga`。
- 確認 `clock_bridge.v` 有被加入 sources。
- 確認 `icache_pipeline_top.v` 使用 MIG path。
- 重新 `Generate Output Products`。
- 必要時 reset output products 後重新生成。

### XDC / pin 約束衝突

症狀：

- 同一個 port 被約束多次。
- Vivado warning clock redefined。
- implementation pin conflict。

修法：

- `board_top` 使用 `Nexys-A7-100T-Master.xdc`。
- `board_top_vga` 使用 `xdc_for_vga.xdc`。
- 不要同時啟用兩份 board-level XDC 約束同一個 top。
- DDR2 pins 使用 MIG-generated XDC。
- 不要在多個 XDC 對 `sys_clk_i` 重複 `create_clock`。

### 把不該加入的檔案加進 Vivado

正式 Vivado `sources_1` 通常不要加入：

- `*_tb.v`
- `archive/`
- `ip_test.v`
- `ddr2_test.v`
- `vga_initials_top.v`
- `clock_interface.v`
- root-level `MIG_DDR2_interface.v` 作為正式 MIG IP 替代品

完整說明請看 `docs/VIVADO_SETUP.md`。

### timing 不通過

先不要只改 timing strategy。先確認：

- top module 正確。
- XDC 正確。
- `report_clocks` 中 `ui_clk`、Clocking Wizard output、VGA pixel clock 符合預期。
- MIG/Clocking Wizard IP 都是 active 且 output products 最新。

然後再看：

```tcl
report_timing_summary
report_clock_interaction
report_cdc
report_utilization
```

## DDR2 / MIG / Clock 問題

### LED0 不亮

LED0 對應 `init_calib_complete`。不亮代表 DDR2 MIG calibration 沒完成。

可能原因：

- MIG IP 沒正確生成。
- DDR2 XDC 不正確或沒加入。
- `sys_clk_i` / `clk_ref_i` 頻率不對。
- reset 極性錯。
- top/XDC 不匹配。

檢查：

- `report_clocks`。
- `clk_wiz_0` 是否輸出預期 100 MHz / 200 MHz。
- MIG `System Clock = No Buffer`、`Reference Clock = No Buffer` 是否和目前 RTL 接法一致。
- DDR2 package pins 是否來自 MIG-generated XDC。

### L2 寫 DDR2 到底看哪個 clock

在目前架構中，L2 不直接用 DDR2 PHY clock，也不是看 200 MHz `clk_ref_i` 的 posedge。

判斷點是 MIG `ui_clk`：

```text
L2/cache/core run in ui_clk domain
L2 sees app_rdy && app_wdf_rdy
then sends app_en/app_wdf_wren on ui_clk edge
```

因此如果你在 debug L2-to-DDR write timing，請看：

- `ui_clk`
- `app_rdy`
- `app_wdf_rdy`
- `app_en`
- `app_wdf_wren`
- `app_addr`
- `app_wdf_data`

不要用 `clk_ref_i` 判斷使用者 RTL 何時寫入 DDR2。

### `app_addr` 單位搞錯

目前專案的重要規則：

```text
MIG app_addr 使用 byte-domain DDR offset
不要把 app_addr 當成 16-byte beat index
```

如果出現「單一地址測試 pass，但相鄰多地址互相覆蓋」的現象，優先檢查：

- L2 address translation。
- bootloader address translation。
- testbench MIG memory model。
- memtest address stride。

歷史 debug 詳情可看 `docs/DDR2_UART_DEBUG_NOTES.md`。

## UART / Bootloader / Board Run 問題

### `pyserial not found`

修法：

```powershell
python -m pip install pyserial
```

### 找不到 COM port

檢查：

```powershell
Get-WmiObject Win32_SerialPort | Select-Object DeviceID,Name
```

或：

```powershell
Get-CimInstance Win32_SerialPort | Select-Object DeviceID,Name
```

可能原因：

- USB 線沒接好。
- Digilent USB driver 沒裝好。
- 板子沒上電。
- COM port 被其他 terminal 佔用。

### `could not open port`

常見原因：

- COM port 寫錯。
- PuTTY / Tera Term / MobaXterm 已經佔用同一個 COM port。
- 之前的 Python terminal 還沒關。

修法：

- 關閉所有 serial terminal。
- 重新查 COM port。
- 重新執行 `uart_send_mem.py`。

### UART 送完 `.mem` 但板子沒反應

建議指令：

```powershell
python uart_send_mem.py --port COM5 --baud 115200 --mem TEST_FILES/mem_game.mem --delay 1.0 --preamble 4096 --interactive
```

排查順序：

1. COM port 是否正確。
2. baud 是否為 `115200`。
3. 送之前是否按 reset，讓 bootloader 等待。
4. LED0 是否亮起。
5. LED10 是否閃爍。
6. LED6 是否在送完後亮起。
7. `.mem` 是否是最新 build。
8. 是否誤用 `--listen` 期待可以輸入。

`--listen` 只看輸出，不送鍵盤輸入。互動程式請用 `--interactive`。

### 只送 `--zero` 有什麼用

`--zero` 只送 sync + zero length，用來測 bootloader/UART 基本連線。

```powershell
python uart_send_mem.py --port COM5 --baud 115200 --mem TEST_FILES/mem_game.mem --delay 1.0 --zero
```

它不會載入真正程式，不要拿它當作 app 啟動測試。

### 什麼時候要重新送 `.mem`

需要重新送：

- 重新 program bitstream。
- 按 reset。
- 想換另一個 app。
- 程式跑飛，需要重回 bootloader。

不一定需要重新送：

- 程式已經在跑，只是等待 UART input。
- 只是遊戲下一步輸入。

## VGA 問題

### VGA 完全沒畫面

可能原因：

- Vivado top 選到 `board_top`，不是 `board_top_vga`。
- 沒啟用 `xdc_for_vga.xdc`。
- VGA 相關 RTL 沒加入 sources。
- VGA cable/monitor 不支援目前 timing。
- bitstream 正確但還沒透過 UART 載入 VGA app `.mem`。

檢查：

- top 是否為 `board_top_vga`。
- source 是否包含 `vga_subsystem.v`、`clkdiv.v`、`vga_640x480.v`、`vga_initials.v`。
- constraint 是否包含 VGA pins。
- `make vga-subsystem-tb` 是否 pass。

### 有 VGA sync 但畫面空白

可能原因：

- framebuffer 沒被寫入。
- app 沒有使用 VGA helper。
- 送錯 `.mem`。
- buffer select 沒 swap 到有內容的 buffer。

檢查：

- 是否使用 `TEST_FILES/mem_vga_games_menu.mem` 或對應 VGA app。
- C 程式是否 include `game/vga_fb.h` 並 link `game/vga_fb.c`。
- 是否有呼叫 framebuffer draw API。
- 是否有呼叫 `vga_fb_swap_draw_buffer()` 或正確設定 display buffer。

### 畫面撕裂或局部閃爍

可能原因：

- 軟體直接寫正在顯示的 front buffer。
- 只使用 single buffer。
- framebuffer 沒被 Vivado 推成預期的 safe memory structure。

修法：

- 遵守 double buffering：畫 back buffer，再 swap。
- Vivado synthesis 後確認 framebuffer 被推成 block RAM / dual-port RAM 類結構。
- 詳細 CDC 說明看 `docs/CLOCKING_AND_CDC.md`。

## Clock / CDC 問題

### `report_cdc` 對 UART/button/VGA buffer select 報告 crossing

本專案確實有這些 crossing：

- UART RX external input。
- launcher button external input。
- VGA buffer select CPU domain 到 pixel domain。
- VGA selected feedback pixel domain 到 CPU domain。
- framebuffer CPU write side / VGA read side。

判讀重點：

- single-bit control 應使用 two-flop synchronizer。
- framebuffer pixel data 應透過 shared / dual-clock memory structure。
- 不要把 multi-bit bus 每個 bit 各自 two-flop。

如果 report 顯示 synchronizer 沒被辨識，可以考慮在對應 FF 補 `ASYNC_REG` attribute。

### VGA framebuffer CDC 和 double buffer 混淆

正確分法：

```text
shared / dual-clock framebuffer memory:
  處理 CPU clock -> VGA pixel clock 的 multi-bit data crossing

double buffering:
  降低畫面 tearing，讓 CPU 畫 back buffer、VGA 讀 front buffer
```

單一 buffer 仍然可以靠正確 memory structure 做 CDC，但可能 tearing。double buffer 不能取代正確的 CDC memory boundary。

## Git / Release / Repository 大小問題

### Toolchain 太大，不能直接放 repo

不要把 1GB+ 解壓後 compiler commit 進 Git。

目前建議：

- repo 只保留 `toolchain/README.md`。
- toolchain zip 放 GitHub Release。
- `.gitignore` 忽略 `toolchain/*`。

確認：

```powershell
git status --short
```

如果看到大量 `toolchain/...` 檔案準備被加入，先不要 commit。

### GitHub Release asset 上傳很久

大型 zip 上傳數百 MB 很正常，時間取決於網路上傳速度。建議：

- 使用 zip 而不是解壓後上傳。
- 同時上傳 `SHA256SUMS.txt`。
- release note 寫清楚解壓路徑。

### `release_assets/` 要不要 commit

通常不要。這是本地打包暫存資料夾，`.gitignore` 已忽略：

```text
release_assets/
```

正式發布請用 GitHub Release asset。

## 送交前的最後排錯清單

提交前建議至少確認：

```powershell
make check-tools
make mem
make uart-mmio-tb
make vga-subsystem-tb
powershell -ExecutionPolicy Bypass -File tools/run_muldiv_verification.ps1 -Iverilog iverilog
powershell -ExecutionPolicy Bypass -File tools/run_multiseed_regression.ps1
powershell -ExecutionPolicy Bypass -File tools/run_independent_system_verification.ps1
```

Vivado 端確認：

```tcl
report_clocks
report_cdc
report_timing_summary
report_utilization
```

板上確認：

- LED0 亮。
- LED10 閃爍。
- UART 可載入 `.mem`。
- LED6 在 `.mem` 送完後亮。
- UART app 可互動。
- VGA top 可顯示畫面。

如果其中某一步失敗，先不要直接改大範圍 RTL。先保存 log、確認是哪一層失敗，再從本文件對應章節排查。

