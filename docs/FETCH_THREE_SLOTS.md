# 三槽位取指與 hit-under-miss

2026-10-29：只在 `FETCH_OVERLAP_EN=1` 啟用。新 radix-4 乘法器保持原樣。
`FETCH_OVERLAP_EN=0` 使用原本的 blocking I-cache 與單筆取指控制，可作實板 A/B 基準。

本次測量與驗證結果見 [FETCH_THREE_SLOTS_RESULTS.md](FETCH_THREE_SLOTS_RESULTS.md)。

## 實作範圍

`icache.v` 中新增 `i_cache_overlap`，由 `icache_top.v` 依參數選擇。
模組放在原有來源檔內，Vivado 不需要額外加入新的設計來源檔。

- 三個指令結果槽位：PC、狀態、指令資料、錯誤、等待的回填編號。
- 環狀 head/tail；只交付 head，完成順序可以不同。交付表示進入 CPU 前端，並非退休。
- 佇列全滿時，只要 head 當拍完成 response handshake，就允許同拍 request handshake 並回收該槽。
- 同步 RAM lookup 與回填獨立；全命中、無 redirect／後端停等時，啟動延遲後每拍可交付一條。
- 三筆 line 工作紀錄：地址、狀態、512-bit 資料、錯誤／回填進度。等待名單以槽位的回填編號反向表示。
- 同 line 的 miss 合併，不重複發下層 line 請求。若加入時剛好回填完成，直接取用完成資料。
- 一次一條 line 使用原本 64-bit L2 burst 介面；DDR2 命令數與讀取方式維持原本設計。
- L2 新增獨立唯讀 hit probe，可在主交易等待 DDR2 時查詢別條 line；probe miss 轉排原本主介面。
- probe 只有一筆在途，不需要外部 transaction ID；I-cache 鎖住該次 probe 對應的 MSHR 編號。
- 主介面與 probe 各自有完成保留空間，不受 CPU head 或 ready 阻擋而無法收回填。

因此可同時出現：A 等 DDR2、B 已從 L2 回來、C 在 I-cache 命中，B/C 先存入槽位，最後依 A/B/C 交付。
若 A、B 都 miss L2，B 先排隊，等 A 的主介面交易完成後才開始它的 DDR2 回填。
這不是多條 DDR2 line 同時讀取的實作。

## 取消、反壓與衝突

Redirect 清除三個指令槽位與 lookup pipeline，但已提出的下層交易繼續完成／排空。
回填工作紀錄不保留可失效的槽位指標；完成時只更新當下有效、且明確等待該紀錄的槽位。
新路徑若需要相同 line，可重新加入仍在進行的 cacheable 回填，避免依賴有限位數 epoch 不繞回。

回填資料先保存在各紀錄內，再一次安裝一條 line。替換 way 在安裝時決定，
不讓不同回填提前保留同一個 victim。安裝時暫停新的 RAM read，以避免依賴 FPGA 同址讀寫的模式。
L2 probe 也只在主介面沒有寫 array 的狀態採樣；得到的是一份完整 tag/data 快照。
CPU response 與下層 request 在 backpressure 時保持穩定。
錯誤回填會排空 burst、讓所有等待者得到 NOP + error，並且不安裝到 I-cache。

## 為密集取指補上的流水線條件

這些調整同樣只在啟用模式生效：

1. WB 與 ID 同拍時，把當拍 WB 資料旁路到 ID/EX，避免擷取寫入前的 RF 值。
2. EX 被 MEM 或長運算卡住時，保存已取得的 forwarding 操作數。
3. load-use bubble 只能在 EX 能前進時插入；不能把仍被較舊 MEM 交易卡住的 EX load 清掉。

`TEST_FILES/prog_perf_fetch_dependencies.S` 專門覆蓋這些相鄰指令與停等情境。
main 區間、退休事件、PMU snapshot 與 UART framing 定義保持一致。

## 重現測試

在專案根目錄執行：

```powershell
make fetch-slots-tb
python tools/run_perf_verification.py --fetch-overlap --seeds 2 --out-dir build_perf/fetch_slots/cpu
python tools/run_coremark_verification.py --seeds 1 --out-dir build_perf/fetch_slots/coremark
```

第一項跑 `tools/tb/fetch_slots_tb.v`，透過真實 L2/arbiter 與可控制延遲的 DDR 模型測試：

- A 等 DDR2、B 命中 L2、C 命中 I-cache，驗證 B/C 提前完成與輸出順序。
- 同 line 三指令共用一次回填，DDR 只發四次 128-bit read。
- 三槽全滿時 response/request 同拍，以及後端 ready=0 的輸出保持。
- 32 條連續命中，每拍一條 response。
- slot ring wrap、同 set 替換、redirect、舊回填晚到、300 次連續槽位取消重用。
- burst 首拍錯誤後仍排空，其餘等待者同樣得到 error，重試不讀到被污染的 I-cache line。

第二項用獨立 RV32IM 解譯器比對每一條 main 退休 PC／暫存器寫入，檢查 PMU main 起訖、
快照凍結與實際 UART TX pin。共十個程式，各 deterministic + 兩個隨機種子。
啟用模式的 `performance_system_tb.v` 另有獨立三槽 PC 順序 scoreboard，檢查取消與 pending 計數。
第三項跑 CoreMark performance／validation 兩種 seed 組合，OFF／ON 與 deterministic／random，檢查官方 CRC。
短程 RTL 測試不產生正式 CoreMark 分數。

也可以一次跑全部：

```powershell
python tools/run_fetch_slots_verification.py --full
```

合成檢查：

```powershell
& 'C:/Xilinx/Vivado/2020.2/bin/vivado.bat' -mode batch -source tools/synth_fetch_comparison.tcl
```

這會分別合成 OFF／ON 的 CPU+L1 與 L2，檢查 RAM 推導、資源與估計 timing。
它不包含整板 MIG 的 place/route，不能代替實際板子工程的 timing closure。

原有 `tools/run_frontend_profile.py` 的四分類觀測器仍限 OFF 模式，因為它假設單筆在途取指。
ON 模式用新的順序 scoreboard／佇列占用資訊；不可把舊觀測器直接套在三槽模式。

## 燒錄與使用

Top 仍是 `board_top`。使用者已將 `board_top` 的 `FETCH_OVERLAP_EN` 預設設成 1，
而 `icache_pipeline_top` 直接實例化的預設仍為 0。重建 OFF 基準時，請明確在 Vivado top-level generic 設 0；
啟用新版時使用 1，再重新 synthesis、implementation、generate bitstream。
若工程沒有其他 generic，可在 Tcl Console 設定：

```tcl
set_property generic {FETCH_OVERLAP_EN=1} [current_fileset]
```

如果已有其他 generic，請在原設定中加入或修改這個欄位，保留其他值。
檢查 synthesis elaboration 的 top 參數為 1，以及整板 implementation timing 通過，再燒錄。

程式映像可沿用同一份 `coremark_*_auto.mem`；不用因取指硬體變更重建不同 benchmark。
燒錄後使用新輸出資料夾，保留已記錄的新乘法器 OFF 實板基準：

```powershell
python tools/run_perf.py --port COM5 --baud 115200 --delay 3 --mem build_perf/coremark_performance_auto.mem --expect-return 0 --timeout 300 --out-dir build_perf/coremark_board/fetch_three_slots_performance
python tools/run_perf.py --port COM5 --baud 115200 --delay 3 --mem build_perf/coremark_validation_auto.mem --expect-return 0 --timeout 300 --out-dir build_perf/coremark_board/fetch_three_slots_validation
```

每次上傳前照原本流程 reset 板子，讓 bootloader 接收新的映像。
UART PMU metadata `features=00000003` 代表新版啟用模式：bit0 overlap、bit1 三槽位與 L2 hit-under-miss。
終端機會同時顯示 `Fetch overlap: ON` 與 `Fetch queue: 3 ordered slots; I-cache/L2 hit-under-miss`。
舊的單筆同拍版本只有 bit0=1，因此新舊 ON 模式能由報告辨識。
確認 return=0、CRC PASS，以及 timed kernel 至少 10 秒後，再與相同映像的 OFF JSON 比較。
自動校準可能選不同迭代數，使用 `compare_coremark.py` 按每次迭代時間正規化比較。
