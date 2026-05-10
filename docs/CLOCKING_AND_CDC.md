# Clocking And CDC

本文件說明本專案目前的時脈架構，以及實際有使用到的 CDC（Clock Domain Crossing，跨時脈域）位置與處理方式。

CDC 的核心問題是：如果某個訊號由 clock A 的邏輯產生，卻直接被 clock B 的 flip-flop 取樣，而兩個 clock 之間沒有固定相位關係，就可能發生 metastability（亞穩態）或多 bit 資料不一致。因此跨時脈域時，必須使用同步器、握手、dual-clock FIFO、dual-port RAM，或交給可靠的 IP 內部處理。

## Clock Domains

目前 FPGA 主線設計中，主要 clock/domain 如下：

| Domain / signal | 來源 | 主要用途 |
| --- | --- | --- |
| `sys_clk_i` | Nexys A7 板載 100 MHz oscillator，pin `E3` | top-level input clock，送進 `clock_bridge.v` / `clk_wiz_0` |
| `aux_clk_100` | `clk_wiz_0` 的 `clk_out1` | MIG `sys_clk_i`、board-level debug logic、VGA master clock input |
| `mig_ref_clk` | `clk_wiz_0` 的 `clk_out2` | MIG `clk_ref_i`，給 MIG / IO delay reference 使用 |
| `ui_clk` | DDR2 MIG output | `USE_MIG=1` 時供 CPU、I-Cache、D-Cache、L2、UART bootloader、UART MMIO 使用 |
| `core_clk` | `USE_MIG=1` 時等於 `ui_clk` | CPU/cache/L2 主時脈 |
| `clk25` | `clkdiv` 從 `vga_mclk` 分頻產生 | VGA timing 與 framebuffer read side |
| external async inputs | 板上外部輸入腳位 | `rst_n`、`uart_rx_i`、`launcher_btn_i` |

目前最重要的設計選擇是：`USE_MIG=1` 時，`icache_pipeline_top.v` 內部讓核心時脈跟著 MIG 的 `ui_clk`：

```verilog
assign core_clk = ui_clk;
```

也就是說，CPU/cache/L2 是在 MIG user interface clock domain 中跟 MIG 溝通。DDR2 PHY 內部高速時序則藏在 MIG IP 裡，不由 L2 直接處理。

## 哪些地方不是 CDC

目前設計中，L2 到 DDR2 的主要資料路徑不是你自己寫的 CDC。

路徑如下：

```text
CPU / I-Cache / D-Cache / L2
  run in core_clk
  core_clk = MIG ui_clk
        |
        v
MIG native app_* interface
  app_addr, app_cmd, app_en, app_wdf_data, app_rdy, app_wdf_rdy
        |
        v
MIG internal controller / PHY
        |
        v
DDR2 pins
```

L2 寫入時是在 `ui_clk` 的 clock domain 中，依照 MIG ready 訊號送資料：

```verilog
app_en       = app_rdy && app_wdf_rdy;
app_wdf_wren = app_rdy && app_wdf_rdy;
```

這是同一個 clock domain 內的 ready/valid 類 flow control，不是 CDC。MIG user logic 到 DDR2 PHY 之間的 CDC 與高速 timing 由 Xilinx MIG IP 內部處理。

## CDC 1: MIG 內部時脈處理

MIG IP 接收：

```text
sys_clk_i
clk_ref_i
sys_rst
```

並輸出：

```text
ui_clk
ui_clk_sync_rst
init_calib_complete
```

同時 MIG 也會驅動 DDR2 physical pins：

```text
ddr2_dq
ddr2_dqs_p/n
ddr2_addr
ddr2_ba
ddr2_ck_p/n
...
```

DDR2 PHY 的實際時脈、DQS、DDR command timing、calibration 等細節都由 MIG 內部處理。你的使用者 RTL 不應該直接跨進 DDR2 PHY clock domain，而是留在 `ui_clk`，透過 `app_*` 介面存取 DDR2。

目前專案規則：

```text
不要直接用 DDR2 PHY clock 去 clock L2/cache。
不要手動把 L2 資料直接送到 DDR2 pins。
只透過 MIG ui_clk + app_* interface 存取 DDR2。
```

## CDC 2: UART RX 外部輸入

`uart_rx_i` 是外部序列輸入腳位，不會和 FPGA 內部 clock 同步。因此本專案在使用它之前會先同步到本地 clock domain。

因為 UART 在專案中有多種用途，所以有幾個同步位置：

| 位置 | Clock domain | 訊號 | 用途 |
| --- | --- | --- | --- |
| `board_top.v` / `board_top_vga.v` | `aux_clk_100` | `uart_raw_ff1`, `uart_raw_ff2` | board-level debug edge detector |
| `icache_pipeline_top.v` | `ui_clk` / `core_clk` | `ui_rx_ff1_q`, `ui_rx_ff2_q` | UI-clock debug edge detector |
| `icache_pipeline_top.v` | `core_clk` | `uart_rx_ff1_q`, `uart_rx_ff2_q` | UART MMIO receiver input sync |
| `uart_bootloader.v` | bootloader `clk`，目前是 `ui_clk` | `rx_ff1`, `rx_ff2` | UART bootloader input sync |

基本結構是 two-flop synchronizer：

```verilog
always @(posedge clk) begin
    rx_ff1 <= uart_rx_i;
    rx_ff2 <= rx_ff1;
end
```

原理：

- 第一個 flip-flop 可能因為 `uart_rx_i` 剛好在 clock edge 附近變化而進入 metastability。
- 第二個 flip-flop 讓訊號多一個 clock cycle 的時間穩定下來。
- 後面的邏輯只使用第二級同步後的訊號。

這種做法適合單 bit 外部非同步輸入，例如 UART RX。

同步完成後，`uart_rx.v` 才根據 `CLK_HZ` 和 `BAUD` 做 UART bit timing sampling。也就是：

```text
two-flop synchronizer 負責降低 metastability 風險
uart_rx.v 負責 8N1 UART protocol sampling
```

注意：`uart_bootloader.v` 和部分 debug synchronizer 使用了 `(* ASYNC_REG = "TRUE" *)`。主要 UART MMIO path 也有 two-flop synchronizer，但目前 `uart_rx_ff1_q` / `uart_rx_ff2_q` 尚未標註 `ASYNC_REG`。未來若要讓 Vivado 更明確辨識 CDC synchronizer，可以補上這個 attribute。

## CDC 3: Launcher Button 外部按鍵

`launcher_btn_i` 是 `board_top_vga` 使用的外部按鍵。機械按鍵有兩個問題：

1. 它是非同步輸入，可能造成 metastability。
2. 它會 bounce，按下或放開時會在短時間內跳動多次。

在 `icache_pipeline_top.v` 中，按鍵先被同步到 `core_clk`：

```verilog
launcher_reset_ff1_q <= launcher_reset_req_i;
launcher_reset_ff2_q <= launcher_reset_ff1_q;
```

接著用 debounce / state logic 追蹤穩定狀態：

```text
launcher_reset_btn_q
launcher_reset_db_cnt_q
launcher_reset_pending_q
launcher_reset_active_q
```

原理：

- `launcher_reset_ff1_q` / `launcher_reset_ff2_q` 降低 metastability 風險。
- debounce counter 等到同步後的輸入穩定足夠久，才接受狀態變化。
- 最後再轉成內部可控的 reset request / reset pulse。

這是按鍵常見處理方式：

```text
async button
  -> two-flop synchronizer
  -> debounce counter
  -> clean internal event/state
```

## CDC 4: VGA Framebuffer 跨時脈

VGA subsystem 有兩個重要 clock：

```text
cpu_clk: CPU/MMIO write side
clk25:   VGA pixel/timing read side
```

在 `icache_pipeline_top.v` 中，VGA 是這樣接的：

```verilog
vga_subsystem u_vga (
    .cpu_clk  (core_clk),
    .vga_mclk (clk),
    ...
);
```

在 `vga_subsystem.v` 裡，`clkdiv` 從 `vga_mclk` 產生 `clk25`：

```verilog
assign clk25 = q[1];
```

### Framebuffer Data

Framebuffer storage 是：

```verilog
(* ram_style = "block" *) reg [31:0] fb_mem [0:FB_WORDS-1];
```

CPU side 在 `cpu_clk` 寫入：

```verilog
always @(posedge cpu_clk) begin
    if (cpu_req_valid && cpu_addr_hit && cpu_req_we) begin
        fb_mem[cpu_word_addr] <= ...
    end
end
```

VGA side 在 `clk25` 讀取：

```verilog
always @(posedge clk25) begin
    vga_word_q <= fb_mem[vga_mem_word_addr];
end
```

這不是簡單的單 bit synchronizer。它是 framebuffer memory 的跨時脈讀寫問題，通常應該讓 FPGA 推成 block RAM 或等效的 memory structure。CPU 寫入端和 VGA 讀取端用不同 clock，因此不能用「每個 bit 各自兩級同步」的方式處理 pixel data。

這裡要把兩件事分開：

1. CDC 安全：pixel data 如何從 CPU clock domain 到 VGA pixel clock domain。
2. 畫面一致性：VGA 顯示一幀畫面時，會不會讀到 CPU 正在修改中的資料。

### Shared Framebuffer Memory 是哪一種 CDC

Framebuffer pixel data 的 crossing 方式是 memory-based CDC：

```text
CPU clock domain
  -> write port / write side of framebuffer memory
  -> shared framebuffer memory
  -> read port / read side of framebuffer memory
  -> VGA pixel clock domain
```

也就是說，large multi-bit pixel data 不靠每個 bit 各自 two-flop synchronizer。正確概念是讓 framebuffer 被實作成可接受不同讀寫 clock 的 memory structure，例如 true dual-port RAM / dual-clock block RAM，或明確使用 Xilinx XPM memory。

目前 RTL 使用：

```verilog
(* ram_style = "block" *) reg [31:0] fb_mem [0:FB_WORDS-1];
```

這是希望 Vivado 把 framebuffer 推成 block RAM 類資源。因為這是 inference 寫法，實務上需要在 Vivado synthesis 後確認它沒有被推成不符合預期的 unsafe distributed logic。若要讓論文/研討會文件更嚴謹，後續可以把它改成明確的 `xpm_memory_tdpram` 或 vendor RAM IP，這樣就能直接說明 framebuffer 使用 dual-clock RAM 作為 multi-bit CDC boundary。

### 單一 Buffer 可以解決什麼

即使只有單一 buffer，只要 framebuffer storage 真的是 dual-clock / dual-port memory，仍然可以解決「資料跨時脈」問題：

```text
CPU 用 cpu_clk 寫同一塊 framebuffer
VGA 用 clk25 讀同一塊 framebuffer
memory primitive 本身作為兩個 clock domain 的邊界
```

所以單一 buffer 並不是「不能做 CDC」。單一 buffer 的問題是畫面一致性：

```text
VGA 正在讀某個 pixel / word
CPU 同時可能正在寫同一個 pixel / word
```

如果 CPU 寫入位置剛好和 VGA 正在掃描的位置重疊，VGA 可能在同一幀畫面中看到舊資料和新資料混在一起，造成 tearing、閃爍或局部更新痕跡。這通常不是 metastability 問題，而是 framebuffer coherency 問題。

因此：

```text
single buffer + proper dual-clock memory
  可以處理 CDC
  不能保證畫面每一幀完整一致
```

### Double Buffer 解決的是畫面一致性

目前設計用 double buffering 降低畫面 tearing：

```text
CPU writes draw buffer
VGA reads display/front buffer
software requests buffer swap
VGA switches displayed buffer at frame boundary
```

double buffer 的角色不是取代 memory-based CDC，而是讓 CPU 和 VGA 在正常使用時操作不同 buffer：

```text
back/draw buffer:
  CPU 寫入下一幀畫面

front/display buffer:
  VGA 讀取目前顯示中的畫面
```

當 CPU 畫完 back buffer 後，軟體寫 framebuffer control register 要求 swap。VGA domain 收到同步後的 buffer select request，但只在 frame boundary 套用新 front buffer。這樣可以避免一幀畫面上半部來自舊 buffer、下半部來自新 buffer。

注意：硬體不會自動阻止軟體去寫目前正在顯示的 buffer。軟體 API 必須遵守 double-buffering discipline，也就是畫 back buffer，present/swap 後，再畫下一個 back buffer。如果軟體直接寫 front buffer，CDC boundary 仍然存在，但畫面可能 tearing。

總結如下：

| 架構 | CDC 是否可行 | 畫面一致性 |
| --- | --- | --- |
| 單一 buffer + 正確 dual-clock/shared memory | 可行 | 可能 tearing，因為 CPU/VGA 可能同時碰同一畫面 |
| double buffer + 正確 dual-clock/shared memory | 可行 | 較好，CPU 畫 back buffer，VGA 讀 front buffer |
| 單一或 double buffer，但 memory 沒有被正確實作成安全跨時脈 memory | 不可靠 | 不能只靠 buffer 數量修正 CDC 問題 |

### Front Buffer Select: CPU Domain To VGA Domain

CPU 透過 framebuffer control register 寫入希望顯示的 front buffer：

```text
front_buf_sel_cpu_q
```

這個單 bit request 透過以下暫存器同步到 VGA pixel clock domain：

```text
front_buf_sel_vga_meta_q
front_buf_sel_vga_req_q
```

真正切換顯示 buffer 時，不是在任意 pixel 時刻切換，而是在 frame 起點：

```verilog
if ((hc == 10'd0) && (vc == 10'd0)) begin
    front_buf_sel_vga_q <= front_buf_sel_vga_req_q;
end
```

原理：

- 先把單 bit request 同步到 `clk25`。
- 不在 frame 中途切換 buffer。
- 只在 `hc == 0` 且 `vc == 0` 時套用新 front buffer。

這樣可以避免一個畫面上半部和下半部來自不同 buffer，降低 tearing。

### Display Buffer Acknowledge: VGA Domain To CPU Domain

VGA side 實際使用的 buffer 也會同步回 CPU domain：

```text
front_buf_sel_vga_q
  -> front_buf_sel_seen_meta_q
  -> front_buf_sel_seen_q
```

CPU 可以從 framebuffer control register 讀到：

```verilog
{30'd0, front_buf_sel_cpu_q, front_buf_sel_seen_q}
```

這讓軟體知道 VGA domain 是否已經看到並套用要求的 display buffer。

## CDC 5: Board-Level Debug Sampling

`board_top.v` 和 `board_top_vga.v` 裡有一些 board pin edge detector，用來在 status LED 上顯示板上是否有活動。

例如：

```verilog
uart_raw_ff1 <= uart_rx_i;
uart_raw_ff2 <= uart_raw_ff1;
...
uart_tx_ff1 <= uart_tx_o;
uart_tx_ff2 <= uart_tx_ff1;
```

這些邏輯 clocked by `aux_clk_100`，用途是 debug/status，不是正式 UART datapath 的功能核心。

原理：

- 把外部 pin 或不同 domain 的 activity sample 到 `aux_clk_100`。
- 用同步後的訊號和 delayed version 比較，偵測 edge。
- 再把 sticky/debug status 顯示到 LED/status output。

## Reset Handling

Top-level reset `rst_n` 是外部輸入，因此它本身也是非同步訊號。專案目前用以下訊號形成內部 reset release：

```text
rst_n
clk_wiz_locked
rst_release
```

產生：

```text
rst_n_int
```

目的：

1. clock wizard 還沒 locked 時，保持系統 reset。
2. locked 後再等一段 hold window。
3. 再釋放板級主要邏輯。

MIG 另外提供：

```text
ui_clk_sync_rst
init_calib_complete
```

核心 reset base 也會被 MIG ready 狀態限制：

```verilog
assign core_rst_n_base = rst_n & ~ui_clk_sync_rst & init_calib_complete & boot_release_ok_q;
```

設計原則：

```text
每個 clock domain 都應該收到對該 domain 安全的 reset。
Reset assertion 可以是 asynchronous，但 reset release 應該被控制。
```

如果未來加入更多獨立 clock domain，建議為每個 domain 加明確的 reset synchronizer。

## 本專案使用到的 CDC 原則

### 單 bit level signal

使用 two-flop synchronizer：

```text
async signal
  -> ff1
  -> ff2
  -> local logic
```

本專案用於：

- UART RX pin
- launcher button
- VGA buffer select bit
- debug pin sampling

### 單 cycle pulse

不要假設 clock A 裡的一拍 pulse 一定會被 clock B 看到。若接收 clock 比較慢，或相位剛好錯過，這個 pulse 可能會消失。

比較安全的方式：

- 把 pulse 拉長到足夠久。
- 把 pulse 轉成 toggle，再跨 domain 後偵測 toggle。
- 使用 request/ack handshake。
- 在 Xilinx 設計中使用 `xpm_cdc_pulse`。

### 多 bit bus

不要把多 bit bus 的每一個 bit 各自用 two-flop synchronizer，除非這個 bus 的 encoding 保證一次只會變一個 bit。

比較安全的方式：

- dual-clock FIFO
- dual-port RAM 搭配安全存取規則
- request/ack handshake，並在接收完成前保持 data stable
- Xilinx `xpm_fifo_async`
- AXI bus 使用 AXI Clock Converter

本專案目前：

- VGA framebuffer data 透過 shared / dual-clock memory structure 作為 multi-bit CDC boundary，不是 bit-by-bit synchronizer。
- double buffering 是畫面一致性策略，用來降低 tearing；它不是取代 dual-clock memory 的 CDC 同步器。
- MIG 的 DDR2 PHY multi-bit crossing 由 MIG IP 內部處理。

## Current CDC Inventory

| 路徑 | 來源 clock domain | 目的 clock domain | 目前處理方式 |
| --- | --- | --- | --- |
| L2/cache to MIG `app_*` | `ui_clk` | `ui_clk` | 不是自寫 CDC；同 domain ready/valid flow control |
| MIG user interface to DDR2 PHY | MIG internal | MIG internal / DDR2 pins | 由 Xilinx MIG IP 處理 |
| UART RX pin to bootloader | async external | `ui_clk` | two-flop sync，然後進 UART receiver |
| UART RX pin to UART MMIO | async external | `core_clk` | two-flop sync，然後進 UART receiver |
| UART RX/TX pin debug | async/external or core output | `aux_clk_100` | two-flop sync，edge/sticky detector |
| launcher button | async external | `core_clk` | two-flop sync + debounce |
| VGA buffer select request | `cpu_clk` | `clk25` | two-flop sync，並在 frame boundary 切換 |
| VGA buffer selected feedback | `clk25` | `cpu_clk` | two-flop sync 成 status bit |
| framebuffer pixel data | CPU write side | VGA read side | shared / dual-clock framebuffer memory；double buffering 用於降低 tearing |
| top reset | async external | multiple domains | clock lock/MIG ready gating；未來可用 per-domain reset sync 強化 |

## 驗證建議

正式 FPGA submission 前，建議檢查：

1. 在 Vivado 跑 `report_clocks`，確認 `sys_clk_i`、`clk_wiz_0` output、`ui_clk`、VGA pixel clock 符合預期。
2. 如果 Vivado 版本支援，跑 `report_cdc`，檢查 `uart_rx_i`、`launcher_btn_i`、`front_buf_sel_*`、reset 相關 crossing。
3. 確認預期的 synchronizer flops 有保留 `ASYNC_REG` attribute。
4. 確認 VGA framebuffer 沒有被推成不符合預期的 unsafe distributed logic，最好確認它是 block RAM / true dual-port RAM 類結構。
5. 確認軟體遵守 double buffering：畫 back buffer，present/swap，下一幀再畫另一個 buffer。若軟體只使用單一 buffer，CDC 仍需靠正確 memory structure 處理，但畫面可能 tearing。

## 總結

最重要的結論：

- L2-to-MIG 不是你自己寫的 CDC；CPU/cache/L2 跑在 `ui_clk`。
- MIG 內部處理 DDR2 PHY clocking。
- 本專案真正需要注意的 CDC 主要是 UART input、launcher button、VGA buffer control、framebuffer read/write clock separation、board debug sampling、reset release。
- 單 bit CDC 使用 two-flop synchronizer。
- 多 bit CDC 應使用 memory/FIFO/handshake，不應該每個 bit 各自同步。
