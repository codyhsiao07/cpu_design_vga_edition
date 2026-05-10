# Verification 說明

本文件說明本專案目前建議的驗證流程、可執行的 testbench/script、pass/fail 判讀方式，以及研討會提交前建議保存的驗證紀錄。

這份文件的定位是「完整驗證入口」。如果只是要了解架構，請先看 `docs/PROJECT_OVERVIEW.md`；如果是 Vivado/IP/bitstream 設定，請看 `docs/VIVADO_SETUP.md`。

## 驗證目標

本專案需要驗證的範圍包含：

| 類別                     | 主要檢查內容                                                                  |
| ------------------------ | ----------------------------------------------------------------------------- |
| C-to-MEM build           | C 程式是否能穩定編譯成 `.mem`，link address 是否符合 DDR boot flow。          |
| RV32I pipeline           | ALU、forwarding、hazard、load-use、branch/jump redirect、writeback。          |
| RV32M                    | `mul/mulh/mulhsu/mulhu/div/divu/rem/remu` decode、EX 執行、C 程式產生的指令。 |
| I-Cache / D-Cache / L2   | cache miss、linefill、writeback、I/D arbitration、stall/ready behavior。      |
| DDR2/MIG path simulation | 使用 `MIG_DDR2_interface.v` 模型檢查 app interface 行為。                     |
| UART                     | UART MMIO TX/RX、RX overrun、UART bootloader sync/write/readback。            |
| VGA                      | framebuffer MMIO read/write、buffer select CDC/status、VGA timing counter。   |
| randomized regression    | 隨機 memory stall / ready delay、watchdog、assertion。                        |

注意：Icarus Verilog simulation 不等於 Vivado timing sign-off。simulation 驗證 RTL 功能；Vivado 仍需另外跑 synthesis、implementation、timing report、CDC report。

## 前置工具

Windows PowerShell 下建議至少確認：

```powershell
python --version
make --version
iverilog -V
vvp -V
```

RISC-V toolchain 可用以下方式確認：

```powershell
make check-tools
make print-config
```

目前 Makefile 的 toolchain 搜尋順序：

1. `toolchain/xpack-riscv-none-elf-gcc/bin`
2. `C:/riscv/xpack-riscv-none-elf-gcc/bin`
3. 使用 `TOOLCHAIN_BIN=...`、`CC_PREFIX=...`、`BINUTILS_PREFIX=...` 手動覆寫

如果 Vivado CLI 不在 PATH，也可以在 Vivado GUI 的 Help / About 或 Tcl Console 查版本。

## 快速驗證流程

如果只是要確認目前 repo 沒有明顯壞掉，建議先跑：

```powershell
make check-tools
make mem
make uart-mmio-tb
make vga-subsystem-tb
```

預期：

- `make mem` 產生預設 `TEST_FILES/mem_game.mem`
- `make uart-mmio-tb` 顯示 UART MMIO PASS
- `make vga-subsystem-tb` 顯示 `VGA TB PASS`

這組檢查速度較快，但不是完整系統回歸。

## 建議完整驗證順序

正式整理 submission 前，建議用以下順序跑。

### Step 1: 清楚記錄目前設定

```powershell
git status --short
make print-config
make check-tools
```

`git status --short` 用來確認當下驗證的是哪一批檔案。若工作區有未 commit 的檔案，驗證報告應該註明。

### Step 2: 重新生成重要 MEM

一般預設程式：

```powershell
make mem
```

獨立系統壓測程式：

```powershell
make test29-independent-stress
```

VGA slot/game suite：

```powershell
make vga-games-menu
```

若要重新生成所有 VGA game `.mem` 並檢查 objdump 中是否沒有軟體 mul/div helper，可跑：

```powershell
powershell -ExecutionPolicy Bypass -File tools/rebuild_vga_games_rv32im.ps1
```

這一步主要確認 C build flow、linker script、crt0、bin-to-mem 都正常。

### Step 3: 子系統與 RV32M 驗證

```powershell
powershell -ExecutionPolicy Bypass -File tools/run_muldiv_verification.ps1
```

這個 script 會執行：

| Check                         | 目的                                                                          |
| ----------------------------- | ----------------------------------------------------------------------------- |
| `booth_multiplier_tb`         | multiplier 單元測試。                                                         |
| `restoring_divider_tb`        | divider 單元測試。                                                            |
| `ex_muldiv_tb`                | EX stage mul/div 整合測試。                                                   |
| `id_muldiv_decode_tb`         | ID stage RV32M decode 測試。                                                  |
| `uart_mmio_tb`                | UART MMIO TX/RX/overrun 測試。                                                |
| `bp_redirect_scenarios_tb`    | branch predictor redirect/flush 場景測試。                                    |
| `uart_bootloader_tb`          | UART bootloader sync、MIG write、readback verify。                            |
| `uart_bootloader_stall_tb`    | bootloader 在 `app_rdy/app_wdf_rdy` stall 下仍能完成。                        |
| `icache_tb`                   | I-cache 基本測試。                                                            |
| `icache_pipeline_top_compile` | core top compile-only check。                                                 |
| `board_top_vga_compile`       | VGA board top compile-only check。                                            |
| `test28_muldiv_smoke_build`   | C 程式以 `-march=rv32im` 編譯，並檢查八個 RV32M mnemonic 出現在 disassembly。 |

預設輸出：

```text
build_muldiv_verification/summary.txt
build_muldiv_verification/summary.csv
build_muldiv_verification/*.log
```

如果你的 `iverilog` 不在 `C:/iverilog/bin/iverilog.exe`，可以覆寫：

```powershell
powershell -ExecutionPolicy Bypass -File tools/run_muldiv_verification.ps1 -Iverilog iverilog
```

### Step 4: 系統多 seed 回歸

`tools/run_multiseed_regression.ps1` 是主要系統回歸入口。預設會跑 TEST 24、25、26、27，每個 20 個 seed，並開啟 randomized memory behavior 與 assertions。

```powershell
powershell -ExecutionPolicy Bypass -File tools/run_multiseed_regression.ps1
```

預設輸出：

```text
build_multiseed/summary.txt
build_multiseed/summary.csv
build_multiseed/t<TEST>_s<SEED>.log
```

常用參數：

```powershell
powershell -ExecutionPolicy Bypass -File tools/run_multiseed_regression.ps1 `
  -Tests "24,25,26,27" `
  -SeedStart 1 `
  -SeedCount 20 `
  -RandMem 1 `
  -AssertEn 1 `
  -MaxCycles 250000
```

若要跑 deterministic、不加 random stall：

```powershell
powershell -ExecutionPolicy Bypass -File tools/run_multiseed_regression.ps1 `
  -Tests "1,2,3,4,5,6,7,8,9,10,11,12,13,14,17,18,19,20,21,22,23,24,25,26,27,29" `
  -SeedStart 1 `
  -SeedCount 1 `
  -RandMem 0 `
  -AssertEn 1 `
  -MaxCycles 350000
```

判讀方式：

- 每個 case log 中應該有 `PASS: test ...`
- log 中不應出現 `ASSERT_FAIL`、`TIMEOUT`、`FATAL`、`FAIL`
- `summary.txt` 的 `Fail` 應為 `0`

### Step 5: TEST29 獨立系統壓測

TEST29 是獨立 C 壓測程式，涵蓋 RV32M、JALR、signed byte/halfword access、cache-line boundary traffic 等。

```powershell
powershell -ExecutionPolicy Bypass -File tools/run_independent_system_verification.ps1
```

這個 script 會做三件事：

1. 重新 build `TEST_FILES/prog_test29_independent_system_stress.c`
2. 跑 TEST29 deterministic simulation
3. 跑 TEST29 randomized memory-stall regression

預設輸出：

```text
build_independent_system_verification/report.txt
build_independent_system_verification/deterministic/summary.txt
build_independent_system_verification/random_stall/summary.txt
```

可調整 seed 數：

```powershell
powershell -ExecutionPolicy Bypass -File tools/run_independent_system_verification.ps1 `
  -SeedStart 1 `
  -SeedCount 20 `
  -MaxCycles 350000
```

### Step 6: Long Verification

`tools/run_long_verification.ps1` 是較長時間的回歸入口，包含：

1. multiseed regression
2. commit trace capture
3. coverage summary
4. optional differential compare

基本用法：

```powershell
powershell -ExecutionPolicy Bypass -File tools/run_long_verification.ps1
```

增加 seed 數：

```powershell
powershell -ExecutionPolicy Bypass -File tools/run_long_verification.ps1 `
  -Tests "24,25,26,27" `
  -SeedStart 1 `
  -SeedCount 100 `
  -TraceSeed 1
```

預設輸出：

```text
build_long_verification/report.txt
build_long_verification/regression/summary.txt
build_long_verification/traces/trace_summary.csv
build_long_verification/coverage/coverage_summary.csv
build_long_verification/diff/diff_summary.csv
```

如果要做 reference trace differential compare，先產生 reference traces：

```powershell
powershell -ExecutionPolicy Bypass -File tools/gen_ref_traces.ps1 `
  -Tests "24,25,26,27" `
  -OutDir build_ref_traces
```

再跑 long verification 並指定 reference：

```powershell
powershell -ExecutionPolicy Bypass -File tools/run_long_verification.ps1 `
  -Tests "24,25,26,27" `
  -RefTraceDir build_ref_traces
```

注意：reference trace generator 是軟體模型輔助工具，適合拿來比對 commit sequence。若某些測試使用了模型尚未完整支援的行為，script 可能標示 `MISS` 或略過 differential compare。

## `icache_pipeline_tb` TEST 編號

`icache_pipeline_tb.v` 的 `+TEST=N` 會選擇不同 `.mem` 與預期結果。

| TEST | MEM file                                   | 主要覆蓋內容                           |
| ---- | ------------------------------------------ | -------------------------------------- |
| 1    | `mem_test1_alu_fwd.mem`                    | ALU / forwarding。                     |
| 2    | `mem_test2_load_use.mem`                   | load-use hazard。                      |
| 3    | `mem_test3_store_dep.mem`                  | store dependency。                     |
| 4    | `mem_test4_branch_taken.mem`               | branch taken。                         |
| 5    | `mem_test5_load_store.mem`                 | load/store。                           |
| 6    | `mem_test6_branch_not_taken.mem`           | branch not taken。                     |
| 7    | `mem_test7_jal.mem`                        | JAL。                                  |
| 8    | `mem_test8_jalr.mem`                       | JALR。                                 |
| 9    | `mem_test9_lb_sb.mem`                      | signed byte load/store。               |
| 10   | `mem_test10_lhu_sh.mem`                    | halfword load/store。                  |
| 11   | `mem_test11_long_mix.mem`                  | mixed instruction sequence。           |
| 12   | `mem_test12_long_mem.mem`                  | memory-heavy sequence。                |
| 13   | `mem_test13_stress.mem`                    | stress workload。                      |
| 14   | `mem_test14_id_miss.mem`                   | instruction miss related path。        |
| 15   | `mem_test1_alu_fwd.mem`                    | injected I-cache response error path。 |
| 16   | `mem_test5_load_store.mem`                 | injected D-cache response error path。 |
| 17   | `mem_test17_icache_stress.mem`             | I-cache stress。                       |
| 18   | `mem_test18_dcache_wb.mem`                 | D-cache writeback。                    |
| 19   | `mem_test19_hazard_branch.mem`             | hazard + branch。                      |
| 20   | `mem_test20_long_mix.mem`                  | long mixed workload。                  |
| 21   | `mem_test21_long_branch.mem`               | long branch workload。                 |
| 22   | `mem_test22_branch_mem_mix.mem`            | branch + memory mix。                  |
| 23   | `mem_test22_from_c.mem`                    | C generated branch/memory test。       |
| 24   | `mem_test24_from_c.mem`                    | C generated system workload。          |
| 25   | `mem_test25_all_instr_stress.mem`          | instruction stress。                   |
| 26   | `mem_test26_mixed_stress.mem`              | mixed stress hash check。              |
| 27   | `mem_test27_full_system_stress.mem`        | full-system stress。                   |
| 29   | `mem_test29_independent_system_stress.mem` | independent full-system stress。       |

目前沒有 TEST28 的 `icache_pipeline_tb` entry。TEST28 是 RV32M smoke build / disassembly check，由 `tools/run_muldiv_verification.ps1` 使用。

## 常用 Plusargs

`icache_pipeline_tb.v` 支援以下常用 plusargs：

| Plusarg                | 用途                              |
| ---------------------- | --------------------------------- |
| `+TEST=N`              | 選擇內建測試。                    |
| `+MEMFILE=path`        | 覆寫載入的 `.mem`。               |
| `+EXPECT_RD=N`         | 覆寫預期完成時要檢查的 register。 |
| `+EXPECT_VAL=XXXXXXXX` | 覆寫預期 register value。         |
| `+MAXCYCLES=N`         | timeout cycle 數。                |
| `+RAND_MEM=1`          | 啟用隨機 memory stall / delay。   |
| `+SEED=N`              | random seed。                     |
| `+RAND_I_MAX=N`        | I-side 隨機 delay 上限。          |
| `+RAND_D_MAX=N`        | D-side 隨機 delay 上限。          |
| `+ASSERT_EN=1`         | 啟用 testbench assertions。       |
| `+STALL_WDOG=N`        | request stall watchdog。          |
| `+RD_WDOG=N`           | read response watchdog。          |
| `+TRACE_EN=1`          | 輸出 commit trace。               |
| `+TRACE_FILE=path`     | commit trace 輸出路徑。           |
| `+COV_EN=1`            | 輸出 coverage summary。           |
| `+COV_FILE=path`       | coverage 輸出路徑。               |
| `+STATE_COV_EN=1`      | 輸出 state coverage。             |
| `+STATE_COV_FILE=path` | state coverage 輸出路徑。         |

一般不建議手動直接呼叫 `vvp` 跑大量 case，優先使用 `run_multiseed_regression.ps1` 或 `run_long_verification.ps1`，因為 script 會自動整理 log、CSV、summary。

## Pass / Fail 標準

一輪 RTL simulation verification 視為通過時，至少需要滿足：

- 所有 script exit code 為 0。
- summary 中 `Fail` 為 0。
- log 中沒有 `ASSERT_FAIL`。
- log 中沒有 `TIMEOUT`。
- log 中沒有 `FATAL`。
- log 中沒有非預期 `FAIL`。
- 對 `icache_pipeline_tb`，每個 case 都有 `PASS: test ...`。
- 對 UART/VGA 專用 testbench，分別出現對應 PASS 訊息。

若遇到 fail，先看該 case 的 log。`run_multiseed_regression.ps1` 的 `summary.txt` 會列出失敗的 `TEST`、`SEED` 和 log path。


## Vivado / FPGA 端驗證

RTL simulation 通過後，Vivado 端仍建議至少做：

```tcl
report_clocks
report_cdc
report_timing_summary
report_utilization
```

板上 bring-up 可搭配：

- `docs/BOARD_IO.md` 的 LED 診斷表
- `docs/VIVADO_SETUP.md` 的 IP / bitstream 設定
- UART bootloader 實機載入 `.mem`
- VGA top 實機確認 hsync/vsync/RGB 輸出

特別注意：

- `MIG_DDR2_interface.v` 是 simulation/helper，不取代 Vivado 正式 MIG IP。
- Icarus simulation 不會證明 DDR2 實體 timing closure。
- VGA framebuffer CDC 最好在 Vivado synthesis 後確認推成預期的 block RAM / dual-port RAM 類結構。

