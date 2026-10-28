# Vivado Setup

本文件說明如何在 Vivado 中建立本專案的 FPGA project、加入 RTL/constraint、產生 Clocking Wizard 與 DDR2 MIG IP，最後完成 synthesis、implementation、bitstream 與板上執行。

本文件只處理 Vivado/FPGA project 設定。C 程式如何產生 `.mem` 請看 `docs/C_TO_MEM_BUILD_FLOW.md`。

Clock domain 與 CDC 的完整說明請看 `docs/CLOCKING_AND_CDC.md`。

## Scope

本專案目前主要有兩個 FPGA top：

| Top | 用途 | VGA | 建議 constraint |
| --- | --- | --- | --- |
| `board_top` | DDR2、UART boot、UART MMIO、非 VGA bare-metal app | No | `Nexys-A7-100T-Master.xdc` |
| `board_top_vga` | DDR2、UART boot、UART MMIO、VGA framebuffer/game/menu | Yes | `xdc_for_vga.xdc` |

兩個 top 都需要：

- 主線 RTL。
- `clk_wiz_0` Clocking Wizard IP。
- `mig_7series_0` DDR2 MIG IP。
- DDR2 MIG 產生的 XDC。
- board-level XDC。

## Board And Part

目標板卡是 Nexys A7-100T。Vivado project 建議使用：

```text
Part: xc7a100tcsg324-1
Board: Nexys A7-100T, if board files are installed
```

如果 Vivado 有 Digilent board files，可以用 board 選項建立 project；如果沒有，直接用 part number 建立也可以。

## Project Creation

建議建立 RTL project：

1. `Create Project`
2. 選 `RTL Project`
3. 先不要勾選只用 IP integrator 的 block design flow；本專案主線是 Verilog top。
4. 選 Nexys A7-100T 或 part `xc7a100tcsg324-1`
5. 建立完成後，再手動加入 source、constraint、IP。

建議不要把 Vivado project 產生的 `.runs/`、`.cache/`、`.gen/`、`.sim/` 等資料夾 commit 到 Git。專案只需要保存可重建 project 的 RTL、constraint、IP 設定檔與說明文件。

## Source Files

### Common RTL

以下是 `board_top` 和 `board_top_vga` 都會用到的主線 RTL：

```text
clock_bridge.v
icache_pipeline_top.v
performance_monitor.v
IF.v
IFID_register.v
ID.v
IDEX_register.v
EX.v
EXMEM_register.v
MEM.v
MEMWB_register.v
WB.v
hazard_unit.v
forward_unit.v
branch_predictor.v
icache_top.v
icache.v
dcache.v
L2_cache.v
I_D_arbitration.v
booth_multiplier.v
restoring_divider.v
uart_bootloader.v
uart_rx.v
uart_tx.v
```

如果使用 `board_top`，再加入：

```text
board_top.v
```

如果使用 `board_top_vga`，再加入：

```text
board_top_vga.v
vga_subsystem.v
clkdiv.v
vga_640x480.v
vga_initials.v
```

### Do Not Add As Main Vivado Sources

以下檔案通常不要加入正式 Vivado `sources_1`：

| File pattern / file | Reason |
| --- | --- |
| `*_tb.v` | Testbench，只用於 simulation。 |
| `archive/` | 歷史設計或舊版參考，不是目前主線。 |
| `ip_test.v` | MIG/example reference，不是目前 board top 主線。 |
| `ddr2_test.v` | DDR2 test/reference top，不是目前主線 top。 |
| `vga_initials_top.v` | VGA standalone/reference top，不是目前主線 top。 |
| `clock_interface.v` | 這是 Clocking Wizard wrapper 參考；正式 project 應使用 `clk_wiz_0` IP output products，避免重複定義或 AutoDisabled 問題。 |
| root-level `MIG_DDR2_interface.v` | 這是為了參考與 standalone simulation 保留的複製 wrapper；正式 Vivado project 應使用生成的 DDR2 MIG IP output products。 |

如果你故意使用某個 reference top 做實驗，可以另外建立獨立 project 或獨立 fileset，不要和目前主線 top 混在一起。

## Constraints

### Non-VGA Top

使用 `board_top` 時，constraint 建議包含：

```text
Nexys-A7-100T-Master.xdc
DDR2 MIG generated XDC
clk_wiz_0 generated XDC
```

目前 repo 內的 `Nexys-A7-100T-Master.xdc` 只約束非 DDR2 的板級 I/O，例如：

- `sys_clk_i`
- `rst_n`
- `uart_rx_i`
- `uart_tx_o`
- `status_o`
- `ifetch_err_o`

DDR2 腳位應由 MIG-generated XDC 負責。

### VGA Top

使用 `board_top_vga` 時，constraint 建議包含：

```text
xdc_for_vga.xdc
DDR2 MIG generated XDC
clk_wiz_0 generated XDC
```

`xdc_for_vga.xdc` 額外約束：

- `launcher_btn_i`
- `vga_red_o`
- `vga_green_o`
- `vga_blue_o`
- `vga_hsync_o`
- `vga_vsync_o`

不要同時啟用 `Nexys-A7-100T-Master.xdc` 和 `xdc_for_vga.xdc` 給同一個 top，否則同一組 board I/O 可能重複約束。

### DDR2 XDC

目前 `ddr2_ip_file/` 用來保存 DDR2 MIG 生成/重建相關資料：

```text
ddr2_ip_file/mig_b.prj
ddr2_ip_file/design_1_mig_7series_0_0.xdc
```

其中：

- `mig_b.prj` 記錄 MIG 設定，例如 DDR2 part、pin selection、clock mode。
- `design_1_mig_7series_0_0.xdc` 是 MIG 產生的 DDR2 constraint。

實際 Vivado project 中，請以目前 active MIG IP 產生的 XDC 為準。若你使用 `ddr2_ip_file/design_1_mig_7series_0_0.xdc`，要確認它和目前生成的 MIG IP、top port name、board pin 都一致。

MIG XDC 中可能有 `create_clock` 被註解掉。這是符合目前設計的：本專案的 board clock 由 board-level XDC + `clk_wiz_0.xdc` 管理，避免多個 XDC 對同一個 clock 重複建立 clock constraint。

## Clocking Wizard IP

`clock_bridge.v` 會例化：

```verilog
clk_wiz_0 u_clk_wiz (
  .clk_out1 (...),
  .clk_out2 (...),
  .reset    (...),
  .locked   (...),
  .clk_in1  (...)
);
```

因此 Vivado project 需要一個名為：

```text
clk_wiz_0
```

的 Clocking Wizard IP。

建議設定：

| Port | Setting |
| --- | --- |
| `clk_in1` | 100 MHz input clock from board `sys_clk_i` |
| `clk_out1` | 100 MHz, used as CPU/MIG `sys_clk_i` path |
| `clk_out2` | 200 MHz, used as MIG `clk_ref_i` |
| `reset` | enabled |
| `locked` | enabled |

目前板上只有一個 top-level clock input：

```text
sys_clk_i = 100 MHz, package pin E3
```

不要額外拉一條 top-level `clk_ref_i` 到板外。`clk_ref_i` 是在 FPGA 內部由 `clock_bridge.v` 和 `clk_wiz_0` 產生。

產生 IP 後，請確認：

1. `clk_wiz_0.xci` 已加入 `sources_1`。
2. `clk_wiz_0.xdc` 或等效 generated constraint 已啟用。
3. IP status 不是 `AutoDisabled`。
4. Synthesis 不會出現 `module 'clk_wiz_0' not found`。

如果看到 `module 'clk_wiz_0' not found`，通常代表 Clocking Wizard IP 沒有加入、沒有 generate output products，或被 AutoDisabled。

## DDR2 MIG IP

`icache_pipeline_top.v` 會例化：

```verilog
mig_7series_0 u_mig (...);
```

所以 Vivado project 中必須有一個可供 synthesis 使用的 module：

```text
mig_7series_0
```

這個 module 應由 DDR2 MIG IP output products 產生，不建議把 repo root 的 `MIG_DDR2_interface.v` 當成正式 Vivado source 來取代 IP generation。

### Required MIG Interface

目前 RTL 期待的 MIG port 介面包含：

```text
DDR2 physical pins:
ddr2_dq
ddr2_dqs_n
ddr2_dqs_p
ddr2_addr
ddr2_ba
ddr2_ras_n
ddr2_cas_n
ddr2_we_n
ddr2_ck_p
ddr2_ck_n
ddr2_cke
ddr2_cs_n
ddr2_dm
ddr2_odt

Clock/reset:
sys_clk_i
clk_ref_i
sys_rst

Native app interface:
app_addr
app_cmd
app_en
app_wdf_data
app_wdf_end
app_wdf_mask
app_wdf_wren
app_rd_data
app_rd_data_end
app_rd_data_valid
app_rdy
app_wdf_rdy
app_sr_req
app_ref_req
app_zq_req
app_sr_active
app_ref_ack
app_zq_ack
ui_clk
ui_clk_sync_rst
init_calib_complete
```

如果你重新產生 MIG IP，要確認 module name 與 port names 和上面一致，否則 `icache_pipeline_top.v` 需要同步修改。

重點是：不管 Vivado 內部是用 IP Catalog 還是 Block Design 生成，最後在 `sources_1` 裡讓 `icache_pipeline_top.v` 看到的外層 module 必須相容於上面的 `mig_7series_0` native app interface。如果你生成的是 AXI `s_axi_*` 介面，而不是 `app_*` 介面，就不能直接接到目前 RTL；這時需要重新生成相容 wrapper，或另外寫 AXI-to-app/SoC adapter，或修改 `icache_pipeline_top.v` 的 MIG 連接。

### Current MIG Reference Settings

`ddr2_ip_file/mig_b.prj` 中目前可見的關鍵設定包含：

| Setting | Value |
| --- | --- |
| Target FPGA | `xc7a100t-csg324/-1` |
| MIG version | `4.2` |
| Memory device | `MT47H64M16HR-25E` |
| Data width | `16` |
| Row / Column / Bank | `13 / 10 / 3` |
| System Clock | `No Buffer` |
| Reference Clock | `No Buffer` |
| Input clock frequency | about `100 MHz` |
| Reset polarity | active low |

目前設計預期：

```text
board sys_clk_i 100 MHz
  -> clk_wiz_0 clk_out1 100 MHz -> MIG sys_clk_i
  -> clk_wiz_0 clk_out2 200 MHz -> MIG clk_ref_i
```

### L2 / DDR2 Clock Domain And Write Timing

目前主線設計不是讓 L2 直接用外部 `100 MHz` 或 `200 MHz` clock 去操作 DDR2 pins。DDR2 pins 的實際高速時序由 MIG controller/PHY 處理，L2 只和 MIG 的 native `app_*` user interface 溝通。

在 `USE_MIG=1` 時，`icache_pipeline_top.v` 內部會把 CPU/cache/L2 的主時脈接到 MIG 輸出的 `ui_clk`：

```verilog
assign core_clk = ui_clk;
```

因此：

```text
CPU / I-Cache / D-Cache / L2
  -> run in MIG ui_clk domain
  -> use app_* interface to request DDR2 read/write
  -> MIG internally converts app_* transactions to DDR2 PHY timing
```

寫入 DDR2 的判斷點是 `ui_clk` 的 posedge，不是 `clk_ref_i` 的 posedge，也不是 DDR2 PHY 內部 clock 的 posedge。L2 只有在 MIG 表示願意收命令和寫資料時才能送出 write beat：

```verilog
if (app_rdy && app_wdf_rdy) begin
    app_en       = 1'b1;
    app_wdf_wren = 1'b1;
    app_wdf_data = write_data_128;
end
```

目前 L2 到 MIG 的資料寬度是：

```text
app_wdf_data = 128 bit = 16 byte
```

所以理論最高寫入頻寬是：

```text
16 byte * ui_clk frequency
```

如果目前 active MIG IP 的 `ui_clk` 設定為 `100 MHz`，則理論峰值為：

```text
16 byte * 100,000,000 = 1,600,000,000 byte/s
約 1.6 GB/s
```

L2 cache line 是 `64 byte`，MIG app write beat 是 `16 byte`，所以一條 cache line writeback 需要：

```text
64 byte / 16 byte = 4 beats
```

若 `ui_clk = 100 MHz` 且每一拍 `app_rdy && app_wdf_rdy` 都成立，理論最快：

```text
4 cycles / 100 MHz = 40 ns
```

這只是理論峰值。實際有效頻寬通常會比較低，因為 MIG 可能因為 refresh、activate/precharge、read/write turnaround、內部排程或校正狀態，讓 `app_rdy` 或 `app_wdf_rdy` 在某些 cycle 為 0。

實務上請用 Vivado 確認目前 active IP 的 `ui_clk`：

```tcl
report_clocks
```

如果 `ui_clk` 的 period 是 `10.000 ns`，就是 `100 MHz`。文件與計算應以 Vivado 目前 active MIG IP 的 `report_clocks` 結果為準。

### MIG Generation Notes

Vivado 生成 MIG 時要確認：

1. 使用 Nexys A7-100T 對應的 DDR2 pinout。
2. 產生的 IP module 能提供 `mig_7series_0`。
3. 產生 output products。
4. DDR2 generated XDC 已加入 `constrs_1` 並啟用。
5. 不要同時啟用多份互相衝突的 DDR2 XDC。

`ddr2_ip_file/` 的定位是「保存重建 MIG 所需參考設定」，不是完整取代 Vivado 產生的 `.xci/.gen` output products。

## Select Top Module

Vivado GUI：

1. `Sources`
2. 找到 `board_top` 或 `board_top_vga`
3. Right click
4. `Set as Top`

Tcl：

```tcl
set_property top board_top [current_fileset]
update_compile_order -fileset sources_1
```

或 VGA 版本：

```tcl
set_property top board_top_vga [current_fileset]
update_compile_order -fileset sources_1
```

選錯 top 時常見現象：

- 使用 `board_top` 卻啟用 `xdc_for_vga.xdc`：VGA/launcher ports 找不到。
- 使用 `board_top_vga` 卻啟用 `Nexys-A7-100T-Master.xdc`：VGA/launcher ports 沒有約束。
- 沒有設 top：Vivado 可能自動選到 testbench 或 reference top。

## C Program And .mem In Vivado

目前主線 FPGA flow 是：

1. Vivado bitstream 只包含 CPU/DDR2/UART/VGA/bootloader 硬體。
2. C 程式先用 Makefile 產生 `.mem`。
3. FPGA programming 完成後，透過 UART bootloader 把 `.mem` 傳進 DDR2。
4. CPU 從 `0x80000000` 開始執行。

因此一般情況下，不需要把 `.c` 或 `.mem` 加入 Vivado `sources_1`。

產生 `.mem`：

```powershell
make mem SRC=OS/main.c OUT_NAME=os_main MEM_OUT=TEST_FILES/mem_os_main.mem APP_DEFINES=
```

下載 bitstream 後，透過 UART 送 `.mem`：

```powershell
python uart_send_mem.py --port COM5 --baud 115200 --mem TEST_FILES/mem_os_main.mem
```

COM port 依你的電腦而定。查詢 Windows COM port：

```powershell
Get-WmiObject Win32_SerialPort | Select-Object DeviceID,Name
```

UART 使用方式更詳細可看 `docs/UART_SEND_MEM_GUIDE.md`。

## Synthesis And Implementation

建議流程：

1. `Generate Output Products` for `clk_wiz_0`
2. `Generate Output Products` for DDR2 MIG IP
3. `Report IP Status`，確認 IP 沒有 out-of-date 或 AutoDisabled
4. `Run Synthesis`
5. 檢查 synthesis log
6. `Run Implementation`
7. 檢查 timing
8. `Generate Bitstream`

Timing 建議：

- `WNS >= 0`
- `TNS = 0`
- setup failing endpoints = 0

如果 timing 不收斂，implementation directive 可參考 `docs/TIMING_CLOSURE_SETUP.md`。

目前較穩定的 implementation directive 是：

| Step | Directive |
| --- | --- |
| Place Design | `ExtraTimingOpt` |
| Physical Optimization | `ExploreWithAggressiveHoldFix` |
| Route Design | `AggressiveExplore` |

## Programming The Board

Vivado GUI：

1. `Open Hardware Manager`
2. `Open Target`
3. `Auto Connect`
4. `Program Device`
5. 選擇產生的 `.bit`
6. Program

Program 完成後：

1. 板子會進入 UART bootloader 等待程式。
2. 用 `uart_send_mem.py` 傳送 `.mem`。
3. 若是 UART app，可用 serial terminal 以 `115200 8N1` 互動。
4. 若是 VGA app，確認 VGA cable/monitor 已接好，再傳送 VGA app 的 `.mem`。

## Common Problems

### `module 'clk_wiz_0' not found`

原因通常是：

- `clk_wiz_0.xci` 沒有加入 project。
- Clocking Wizard output products 沒有生成。
- IP 被 AutoDisabled。
- 用 `clock_interface.v` 代替 IP 但沒有完整 generated implementation。

處理方式：

1. 確認 `clk_wiz_0` IP 存在。
2. `Generate Output Products`
3. `Report IP Status`
4. 確認 `clock_bridge.v` 仍然例化 `clk_wiz_0`
5. 不要把 `clock_interface.v` 和 generated `clk_wiz_0` wrapper 重複加入。

### `module 'mig_7series_0' not found`

原因通常是：

- DDR2 MIG IP 沒有加入 project。
- MIG output products 沒有生成。
- 生成的 module name 不是 `mig_7series_0`。
- 只加入了 `ddr2_ip_file/` 的設定/XDC，但沒有加入真正的 IP source/output products。

處理方式：

1. 確認 Vivado project 中有 DDR2 MIG IP。
2. 確認 module name 是 `mig_7series_0`，或同步修改 `icache_pipeline_top.v`。
3. `Generate Output Products`
4. 確認 generated DDR2 XDC 已啟用。

### XDC Port Not Found

常見原因：

- `board_top` 卻啟用 VGA XDC。
- `board_top_vga` 卻沒有啟用 VGA XDC。
- XDC port name 和 Verilog top port name 不一致。

處理方式：

- 先確認 top module。
- 只啟用對應 top 的 board-level XDC。
- DDR2 pins 使用 MIG-generated XDC。

### Duplicate Clock / Overriding Clock Warning

目前 `sys_clk_i` 的 clock 約束應由 `clk_wiz_0.xdc` 或單一 board-level clock source 管理，不要在多個 XDC 內重複 `create_clock`。

如果看到 clock override 或 duplicate clock 類 warning：

- 檢查 board-level XDC 是否手動加了 `create_clock`。
- 檢查 MIG XDC 是否也啟用了 `create_clock`。
- 保留一個正確 clock constraint source。

### DDR2 Calibration Fails

可能原因：

- MIG pinout/XDC 不正確。
- `sys_clk_i` 或 `clk_ref_i` 頻率不對。
- reset polarity 不對。
- DDR2 generated XDC 未啟用。
- board/part 選錯。

優先檢查：

1. `clk_wiz_0` output 是否為 100 MHz / 200 MHz。
2. MIG `System Clock = No Buffer`
3. MIG `Reference Clock = No Buffer`
4. MIG XDC 是否對到 Nexys A7-100T DDR2 pins。
5. `init_calib_complete` 是否曾經變成 1。

### Bitstream Loads But Program Does Not Run

可能原因：

- 沒有透過 UART 傳 `.mem`。
- 傳錯 COM port。
- baud rate 不是 `115200`。
- `.mem` 不是目前要跑的程式。
- reset/bootloader 還沒準備好。

處理方式：

1. 重新產生 `.mem`。
2. 重新 program bitstream。
3. 查 COM port。
4. 使用 `uart_send_mem.py --delay 1.0` 保守送入。
5. 看 `status_o` LED 與 UART terminal 是否有反應。

## Final Checklist

產生 bitstream 前，建議確認：

1. Top module 是 `board_top` 或 `board_top_vga`。
2. 只啟用對應 top 的 board-level XDC。
3. DDR2 MIG generated XDC 已啟用。
4. `clk_wiz_0` IP 已生成 output products。
5. DDR2 MIG IP 已生成 output products。
6. `clock_interface.v` 沒有和 generated `clk_wiz_0` 重複加入。
7. root-level `MIG_DDR2_interface.v` 沒有被當作正式 Vivado IP source 的替代品。
8. 沒有把 testbench 或 archive source 加入主線 synthesis source set。
9. Synthesis 完成且沒有 missing module。
10. Implementation timing 通過。
11. `report_clocks` 中 `ui_clk`、`clk_wiz_0` output clock 與預期頻率一致。
12. Bitstream 產生後，再用 UART 傳送 `.mem`。
