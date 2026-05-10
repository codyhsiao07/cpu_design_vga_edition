# Bugfix Notes

## 2026-04-27

本次只修改已經能重現，或能從 ready/valid 協定確認的問題。`tools/crt0.S` 在開始前就已有既有修改，這次沒有納入修正。

### 1. `icache.v`: uncached instruction read 可能取錯 32-bit half

原因：
- L2 的 UC_READ 回傳 64-bit beat，但 I-cache 原本固定使用 `l2_rsp_data[31:0]`。
- 當 PC 位在同一個 8-byte beat 的高 32-bit half，也就是 `PC[2]=1` 時，正確指令應該取 `l2_rsp_data[63:32]`。

修改：
- 新增 `pick_uc_word32()`，依照 `PC[2]` 選低 32-bit 或高 32-bit。
- UC_READ 發生錯誤時回傳 RISC-V NOP `32'h0000_0013`，並保留 `if_resp_err=1`。

### 2. `icache.v`: 失敗或過短的 line refill 不可寫入 I-cache

原因：
- cached miss refill 如果遇到 `l2_rsp_err` 或 `l2_rsp_last` 太早出現，原本仍可能進入寫入 cache line 的流程。
- 這會把不完整或錯誤的 line 安裝進 I-cache，後續取指可能讀到污染資料。

修改：
- cached line refill 發生錯誤或短 burst 時，不寫入 tag/data/valid。
- 對 CPU 回傳 NOP 並 assert `if_resp_err`。
- 新增 `ST_DRAIN_ERR`，若錯誤 beat 不是 `last`，會繼續 drain 到 `l2_rsp_last`，避免舊 response beat 卡住或污染下一筆 transaction。

### 3. `dcache.v`: D-cache refill error 後需要 drain 剩餘 response beats

原因：
- D-cache 在 line refill 中途遇到 `l2_rsp_err` 時，若錯誤 beat 不是 `last`，直接回 CPU error 會留下後續 beat。
- 下一筆 miss 可能吃到上一筆 refill 的殘留 response，造成讀回舊資料。
- `l2_rsp_ready` 原本在 request state 也可能為 1，容易在還沒進入接收狀態前接走不屬於當前狀態的 response。

修改：
- 新增 `S_REFILL_DRAIN_ERR`，錯誤 refill 會等到 `l2_rsp_last` 後才回 CPU error。
- `l2_rsp_ready` 限縮在真正等待 response 的 state。

### 4. `dcache_tb.v`: error response 不應比對 data

原因：
- 當 `cpu_rsp_err=1` 時，`cpu_rsp_rdata` 不應被當成有效資料。
- 原本 testbench 仍比對 backing memory 的期望值，會造成 false failure。

修改：
- `exp_err=1` 時只檢查 error bit，不檢查 data。

### 5. `icache_pipeline_tb.v`: MIG 模型 reset 極性與 app_addr domain 不一致

原因：
- top 端接入的 MIG `sys_rst` 是 active-low，但 testbench stub 原本用 active-high reset 行為，導致 reset 放開後 `init_calib_complete` 反而維持 0，CPU 不會開始正常 fetch。
- L2 送給 MIG 的 `app_addr` 是 byte-domain DDR offset，stub 原本當成 16-byte index 使用，等於把位址多乘 16。
- pipeline testbench 不需要長時間 boot release delay，原本預設值會拖慢或干擾短測試。

修改：
- `init_calib_complete = sys_rst`，並改成 `negedge sys_rst` reset。
- `rd128()` / `wr128()` 直接用 byte-domain `app_addr`。
- pipeline TB instantiate DUT 時設定 `.BOOT_RELEASE_CYCLES(1)`。

### 6. `icache_pipeline_top.v`: `UART_BOOT_EN=0` 時 memtest 訊號避免多重 driver

原因：
- `ddr_app_memtest` 的輸出與 `UART_BOOT_EN=0` bypass assign 可能同時驅動 `boot_memtest_*_int`。
- 這在模擬中可能形成 `X`，也會讓 boot/memtest 完成條件不穩定。

修改：
- memtest instance 先接到 `boot_memtest_*_raw`。
- 再依 `UART_BOOT_EN` 選擇 raw 結果或 bypass 常數。

### 7. `l2_arb_tb.v`: L2 arbitration test 的 MIG read pattern 位址換算錯

原因：
- L2 RTL 現在以 byte-domain 驅動 MIG `app_addr`。
- testbench 的 `gen_rd_data()` 原本把 `app_addr` 當成較粗的 index，導致讀回 pattern 與 RTL 位址定義不一致。

修改：
- 改用 `app_addr[26:2]` 轉成 32-bit word index。

### 8. `ip_test.v`: 補上 implicit wire 宣告

原因：
- `po_win_tg_rst`、`manual_clear_error`、`dbg_clear_error`、`wdt_en_w`、`cmd_wdt_err_w`、`wr_wdt_err_w`、`rd_wdt_err_w` 原本依賴 Verilog implicit net。
- 這會產生 warning，也不利於未來使用 `default_nettype none` 或 lint。

修改：
- 明確補上 wire declarations。

## Verification

已通過：
- `icache_tb`
- `dcache_tb`
- `l2_arb_tb`
- `bp_redirect_scenarios_tb`
- `ex_muldiv_tb`
- `id_muldiv_decode_tb`
- `make uart-mmio-tb`
- `icache_pipeline_tb` TEST 1、15、16、24

備註：
- `icache_tb` 另外新增 non-last refill error 測試，確認 I-cache 會 drain 到 `l2_rsp_last`。
- `dcache_tb` 20000 次隨機 regression 已通過。
