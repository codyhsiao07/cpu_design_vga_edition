# Board I/O 說明

本文件說明目前 FPGA board top 使用到的外部 I/O、Vivado XDC 約束檔、LED 診斷燈號，以及哪些板上資源目前沒有接入設計。

目前主要目標板以 Nexys A7-100T / Nexys 4 DDR 類型的板級腳位為準。實際 pin assignment 以專案內 XDC 與 Vivado active IP 產生的 XDC 為準。

## Top Module 選擇

| Top module | 用途 | 使用的板上 I/O |
| --- | --- | --- |
| `board_top.v` | DDR2 + UART boot/MMIO + 非 VGA 主線驗證 | clock、reset、DDR2、USB-UART、status LED |
| `board_top_vga.v` | DDR2 + UART + VGA framebuffer/game/launcher | clock、reset、DDR2、USB-UART、VGA、BTNC、status LED |

如果要使用 VGA 輸出，Vivado top 必須選 `board_top_vga`。如果只要做 DDR2/UART bring-up 或非 VGA 測試，可以用 `board_top`。

## XDC 檔案選擇

| 目標 | 建議啟用的 XDC |
| --- | --- |
| `board_top.v` | `Nexys-A7-100T-Master.xdc`、active MIG 產生的 DDR2 XDC、`clk_wiz_0.xdc` |
| `board_top_vga.v` | `xdc_for_vga.xdc`、active MIG 產生的 DDR2 XDC、`clk_wiz_0.xdc` |

注意事項：

- `Nexys-A7-100T-Master.xdc` 在目前專案中是給 `board_top.v` 使用的非 DDR 板級 I/O 約束。
- `xdc_for_vga.xdc` 是給 `board_top_vga.v` 使用，包含 `board_top.v` 的共用 I/O，再加上 VGA 與 launcher button。
- 不要同時啟用 `Nexys-A7-100T-Master.xdc` 和 `xdc_for_vga.xdc` 約束同一個 top，避免重複約束同一批 port。
- DDR2 腳位不要手動改寫到一般 board XDC；請使用目前 active MIG IP 產生的 DDR2 XDC。專案中的 `ddr2_ip_file/design_1_mig_7series_0_0.xdc` 是目前保存的 DDR2 參考約束。
- `sys_clk_i` 的 clock constraint 應由 Clocking Wizard / Vivado 產生的 clock constraint 管理，不要在多個 XDC 重複 `create_clock`。

## 共用 Board I/O

以下 I/O 在 `board_top.v` 與 `board_top_vga.v` 都會使用。

| Top port | 方向 | Package pin | Board signal | 說明 |
| --- | --- | --- | --- | --- |
| `sys_clk_i` | input | `E3` | `CLK100MHZ` | 板載 100 MHz clock，送入 `clock_bridge.v` / `clk_wiz_0`。 |
| `rst_n` | input | `C12` | `CPU_RESETN` | active-low reset button，XDC 啟用 pull-up。按下時為 0。 |
| `uart_rx_i` | input | `C4` | USB-UART TX into FPGA | PC/USB-UART 傳入 FPGA 的 RX。UART idle 為 high。 |
| `uart_tx_o` | output | `D4` | FPGA TX to USB-UART RX | FPGA 傳回 PC/USB-UART 的 TX。 |
| `status_o[14:0]` | output | see LED table | LED status | 多用途診斷燈號。 |
| `ifetch_err_o` | output | `J13` | LED2 | 歷史名稱保留；runtime 階段不是單純代表 ifetch error，詳見 LED 表。 |

UART 預設 baud rate 由 top parameter `UART_BAUD` 決定，目前為 `115200`。UART 實際 baud divider 也會受 `UART_CLK_HZ` 影響，所以若重新設定 MIG `ui_clk` 或 UART clock，必須同步檢查 top parameter。

## VGA 專用 I/O

以下 I/O 只在 `board_top_vga.v` 使用。

| Top port | 方向 | Package pin | Board signal | 說明 |
| --- | --- | --- | --- | --- |
| `launcher_btn_i` | input | `N17` | `BTNC` | launcher button，XDC 啟用 pull-down。RTL 內有同步與 debounce。 |
| `vga_hsync_o` | output | `B11` | `VGA_HS` | VGA horizontal sync，640x480 timing，sync pulse active low。 |
| `vga_vsync_o` | output | `B12` | `VGA_VS` | VGA vertical sync，sync pulse active low。 |
| `vga_red_o[0]` | output | `A3` | `VGA_R[0]` | VGA red bit 0。 |
| `vga_red_o[1]` | output | `B4` | `VGA_R[1]` | VGA red bit 1。 |
| `vga_red_o[2]` | output | `C5` | `VGA_R[2]` | VGA red bit 2。 |
| `vga_red_o[3]` | output | `A4` | `VGA_R[3]` | VGA red bit 3。 |
| `vga_green_o[0]` | output | `C6` | `VGA_G[0]` | VGA green bit 0。 |
| `vga_green_o[1]` | output | `A5` | `VGA_G[1]` | VGA green bit 1。 |
| `vga_green_o[2]` | output | `B6` | `VGA_G[2]` | VGA green bit 2。 |
| `vga_green_o[3]` | output | `A6` | `VGA_G[3]` | VGA green bit 3。 |
| `vga_blue_o[0]` | output | `B7` | `VGA_B[0]` | VGA blue bit 0。 |
| `vga_blue_o[1]` | output | `C7` | `VGA_B[1]` | VGA blue bit 1。 |
| `vga_blue_o[2]` | output | `D7` | `VGA_B[2]` | VGA blue bit 2。 |
| `vga_blue_o[3]` | output | `D8` | `VGA_B[3]` | VGA blue bit 3。 |

目前 VGA timing 由 `vga_640x480.v` 產生，邏輯解析度由 framebuffer/render path 轉成顯示畫面。`vga_subsystem.v` 內部用 `clkdiv.v` 從輸入 clock 分出約 25 MHz pixel clock。

## DDR2 I/O

DDR2 I/O 由 Xilinx MIG IP 負責產生與約束。Top-level port 名稱如下：

| Top port | 方向 | 說明 |
| --- | --- | --- |
| `ddr2_dq[15:0]` | inout | DDR2 data bus。 |
| `ddr2_dqs_p[1:0]` / `ddr2_dqs_n[1:0]` | inout | DDR2 data strobe differential pair。 |
| `ddr2_addr[12:0]` | output | DDR2 address。 |
| `ddr2_ba[2:0]` | output | DDR2 bank address。 |
| `ddr2_ras_n` | output | DDR2 RAS，active low。 |
| `ddr2_cas_n` | output | DDR2 CAS，active low。 |
| `ddr2_we_n` | output | DDR2 write enable，active low。 |
| `ddr2_ck_p[0]` / `ddr2_ck_n[0]` | output | DDR2 differential clock。 |
| `ddr2_cke[0]` | output | DDR2 clock enable。 |
| `ddr2_cs_n[0]` | output | DDR2 chip select，active low。 |
| `ddr2_dm[1:0]` | output | DDR2 data mask。 |
| `ddr2_odt[0]` | output | DDR2 on-die termination control。 |

DDR2 package pin、IOSTANDARD、termination、SLEW 等設定應使用 MIG 產生的 XDC。不要只靠一般 board master XDC，因為 DDR2 需要 SSTL18 / DIFF_SSTL18_II 等專用約束。

目前保存的 DDR2 參考設定：

```text
ddr2_ip_file/mig_b.prj
ddr2_ip_file/design_1_mig_7series_0_0.xdc
```

Vivado 專案中仍應加入真正的 MIG IP source/output products。`MIG_DDR2_interface.v` 只是專案中保留的參考/模擬輔助檔，不應取代正式 Vivado MIG IP。

## LED 實體對應

Nexys A7 的 LED2 實體腳位 `J13` 被單獨接到 `ifetch_err_o`，所以 `status_o[2]` 並不是板子上的 LED2，而是 LED3。

| Board LED | Package pin | RTL signal |
| --- | --- | --- |
| LED0 | `H17` | `status_o[0]` |
| LED1 | `K15` | `status_o[1]` |
| LED2 | `J13` | `ifetch_err_o` |
| LED3 | `N14` | `status_o[2]` |
| LED4 | `R18` | `status_o[3]` |
| LED5 | `V17` | `status_o[4]` |
| LED6 | `U17` | `status_o[5]` |
| LED7 | `U16` | `status_o[6]` |
| LED8 | `V16` | `status_o[7]` |
| LED9 | `T15` | `status_o[8]` |
| LED10 | `U14` | `status_o[9]` |
| LED11 | `T16` | `status_o[10]` |
| LED12 | `V15` | `status_o[11]` |
| LED13 | `V14` | `status_o[12]` |
| LED14 | `V12` | `status_o[13]` |
| LED15 | `V11` | `status_o[14]` |

## LED 診斷狀態

LED 診斷訊號會依 boot 階段改變。最常看的是以下幾個：

| Board LED | RTL signal | 一般判讀 |
| --- | --- | --- |
| LED0 | `status_o[0]` | `init_calib_complete`。亮起代表 DDR2 MIG calibration 完成。 |
| LED6 | `status_o[5]` | `boot_done`。亮起代表 UART bootloader 已完成並釋放 CPU 執行程式。 |
| LED10 | `status_o[9]` | `boot_ui_clk_blink`。閃爍代表 MIG `ui_clk` domain 正在跑。 |
| LED2 | `ifetch_err_o` | boot 後代表 `core_pc_seen`，也就是 PC 已經變動；名稱是歷史 debug 名稱。 |

`boot_done = 1` 之後的 runtime 診斷：

| Board LED | RTL signal | `boot_done` 後的意義 |
| --- | --- | --- |
| LED0 | `status_o[0]` | DDR2 MIG calibration done。 |
| LED1 | `status_o[1]` | core 已從 reset 釋放並在跑。 |
| LED2 | `ifetch_err_o` | PC changed after boot。 |
| LED3 | `status_o[2]` | CPU hit UART MMIO。 |
| LED4 | `status_o[3]` | CPU 發出 data-memory request。 |
| LED5 | `status_o[4]` | CPU 發出 DDR store。 |
| LED6 | `status_o[5]` | bootloader done。 |
| LED7 | `status_o[6]` | clock wizard locked。 |
| LED8 | `status_o[7]` | internal reset released。 |
| LED9 | `status_o[8]` | CPU writeback commit 曾經發生。 |
| LED10 | `status_o[9]` | `ui_clk` blink。 |
| LED11 | `status_o[10]` | boot payload word0 check OK。 |
| LED12 | `status_o[11]` | boot payload word1 check OK。 |
| LED13 | `status_o[12]` | boot payload word2 check OK。 |
| LED14 | `status_o[13]` | DDR/data response 曾經回來。 |
| LED15 | `status_o[14]` | memory stall 曾經發生。 |

bootloader 還沒完成時，LED 會顯示 UART sync、DDR self-test、boot payload verify 等 bring-up 訊號。若板子上完全沒有反應，通常先看：

1. LED0 是否亮起：DDR2 MIG calibration 是否完成。
2. LED10 是否閃爍：`ui_clk` domain 是否在跑。
3. LED6 是否亮起：UART boot 是否完成。
4. LED3/LED4/LED5 是否在 boot 後亮起：CPU 是否有碰到 UART/MMIO/DDR store。

## Launcher Button

`launcher_btn_i` 只在 `board_top_vga.v` 使用，接到 BTNC。

目前 RTL 中 button 本身主要提供 debounced button status：

```text
0x4000_0010 read -> bit0 = launcher button pressed
```

launcher soft reset 是透過 MMIO 觸發：

```text
0x4000_0014 write -> bit0 = 1 triggers launcher reset request
```

也就是說，C 程式可以先讀 `0x4000_0010` 得知按鈕是否按下，再自行決定是否寫 `0x4000_0014` 觸發 launcher reset。

## 目前未使用的板上資源

下列板上資源目前沒有接到 `board_top.v` 或 `board_top_vga.v`，不要在 Vivado 中啟用對應未使用 port 的 constraint：

- switches `SW[15:0]`
- seven-segment display `CA`..`CG`、`DP`、`AN[7:0]`
- RGB LEDs
- PMOD headers
- Micro SD
- PS/2
- Ethernet
- audio
- accelerometer / temperature sensor

如果之後要加入這些 I/O，建議先在 top module 新增明確 port，再從原始 Nexys A7 master XDC 複製對應腳位並改成目前 top-level port name。

## Bring-Up 檢查順序

板上測試時可以用以下順序排查：

1. 確認 Vivado top 是 `board_top` 或 `board_top_vga`，且 XDC 選擇和 top 相符。
2. 確認 `clk_wiz_0` 與 MIG IP 都已生成 output products。
3. 確認只啟用一份 board-level XDC，不要重複約束同一個 port。
4. 確認 active MIG DDR2 XDC 已加入專案。
5. Program bitstream 後先看 LED0 是否亮起。
6. 再看 LED10 是否閃爍。
7. 透過 USB-UART 傳送 boot image，確認 LED6 是否亮起。
8. 若使用 VGA top，接上 VGA 顯示器並確認 `vga_hsync_o` / `vga_vsync_o` 有輸出。

