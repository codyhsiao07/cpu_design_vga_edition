# CoreMark 實板結果：三槽位取指 ON

紀錄日期：2026-10-29，Asia/Taipei。本輪保存實板 UART 捕獲與分析，未修改 RTL。
對照為 [2026-10-28 新乘法器、取指 OFF 基準](COREMARK_BOARD_BASELINE.md)。

## 比較條件與正確性

- 新舊均為 50,000,000 Hz，I/D/L2=8192/8192/16384 bytes，使用相同 radix-4 乘法器。
- 同一 seed 組使用完全相同的 firmware SHA256；compiler、資料大小及配置保存在原始 JSON。
- flags 從 OFF=0 變成 ON=3，確認新版三槽位／I-cache、L2 hit-under-miss 生效。
- performance、validation 都 main return=0、官方 CRC PASS、timed kernel 超過 10 秒。
- 新版兩組自動校準為 1100 iterations；舊版兩組為 400，故採 kernel 時間／iterations 比較。
- 目前每種配置各一次實板量測；沒有以此估計跨次執行的變異或宣稱官方提交認證。
- 當前 RTL 與先前已驗證版本的檔案 hash 相比，僅 board_top 的預設 FETCH_OVERLAP_EN 從 0 改成 1；保留使用者的這項設定。
- 沒有取得 bitstream hash；硬體版本證據為使用者燒錄資訊、UART flags 與目前來源。

新 performance 捕獲完成於 2026-10-29 15:21:29 UTC+8；validation 為 15:23:44 UTC+8。

## Kernel 比較

| 指標 | performance OFF | performance ON | validation OFF | validation ON |
|---|---:|---:|---:|---:|
| timed iterations | 400 | 1100 | 400 | 1100 |
| kernel 總時間（s） | 13.056705 | 21.750444 | 13.076375 | 21.816033 |
| 每次迭代時間（ms） | 32.641763 | 19.773131 | 32.690938 | 19.832757 |
| iterations/s | 30.635601 | 50.573680 | 30.589517 | 50.421633 |
| iterations/s/MHz | 0.612712 | 1.011474 | 0.611790 | 1.008433 |
| kernel 時間減少 | — | **39.4238%** | — | **39.3326%** |
| kernel 吞吐增加 | — | **65.0814%** | — | **64.8330%** |
| main CPI | 5.628888 | 3.412463 | 5.632903 | 3.420028 |

效能數值取 performance seed；validation 是另一組官方資料驗證，不將兩組平均成一個分數。
實板約 39.4% 的每迭代時間改善，與短程 TB 約 39.3% 的結果接近。

`21750444 µs / 1100 = 19773.130909 µs/iteration`，
相較 `13056705 µs / 400 = 32641.7625 µs/iteration`，speedup=1.650814。
時間減少的分母是舊時間；吞吐增加的分母是舊吞吐，所以 39.42% 與 65.08% 是同一個改善的兩種表示。

1100 次與 400 次的差異由官方自動校準產生。程式先以 10、100…次測到至少一秒，
再以整數秒數計算最後迭代數，因此結果不會恰好落在 10 秒。
完整 main 還包含校準試跑、初始化、驗證與 benchmark 輸出；不能直接用 main 總 cycles 或秒數判斷新舊速度。

## 等待計數的意義

以下分母均為各自整段 main cycles，不是僅 timed kernel，也不是互斥的時間分布。

| 事件 | performance OFF | performance ON | validation OFF | validation ON |
|---|---:|---:|---:|---:|
| frontend_wait | 79.680% | **11.978%** | 79.683% | **11.976%** |
| memory_wait | 21.071% | 34.785% | 21.149% | 34.862% |
| multiply_wait | 10.317% | 17.055% | 10.302% | 17.004% |
| load_use_wait | 0.550% | 2.119% | 0.560% | 2.164% |

frontend_wait 的大幅下降支持原本固定取指間隔是主要改善來源。
板上計數沒有拆分每個機制的貢獻，不能由此分配多少提升來自同拍交接、多少來自三槽或 L2 probe。

memory_wait、multiply_wait 的占比上升，不能解讀成相應硬體變慢。
performance 每 1000 條 main 退休指令的等待事件為：

| 事件 cycles／1000 retired | OFF | ON |
|---|---:|---:|
| frontend_wait | 4485.118 | 408.739 |
| memory_wait | 1186.041 | 1187.039 |
| multiply_wait | 580.751 | 582.002 |
| load_use_wait | 30.944 | 72.303 |

前兩個後端事件的每指令成本幾乎一致，取指等待減少後，它們在總 cycles 中更顯著。
這些仍是 main 的混合工作量正規化數字，不代替固定 timed-kernel 區間的事件量測。
load-use 事件增加符合取指更密集、相鄰依賴較常直接相遇的情況，但需 TB 觀測才能確認成因。

目前值得優先分析 memory_wait 的組成：D-cache load/store hit 的處理與 MEM 握手、
miss/refill/writeback、L2 仲裁等待。memory_wait 不等於 DDR2 等待。
D-load miss 率只有約 0.000116%、D-store 約 0.007174%，但 miss 率沒有包含每次 miss 的代價，
不能直接據此排除下層記憶體延遲。

## 額外取指與 miss

performance I-cache miss 率從 0.014299% 變成 0.027036%；
每 1000 條退休指令的 I-cache lookup 從 1019.028 變成 1279.802，miss 從 0.146 變成 0.346。
這說明取指端做了更多未對應到退休指令的工作；提前取指及 redirect 後取消是合理來源，
但也可能包含其他回填／替換交互作用，需要分別追蹤 wrong-path lookup、合併與回填才能定因。
不能只用原始 miss 總數 21642→121663 判斷，因為整段 main 工作量也不同。

分支方向 miss 率約 7.485%→7.511%，沒有證據顯示方向預測本身明顯改善。
整體 kernel 提升已由相同映像的實板計時確認。

## 原始資料

已將四次 OFF／ON 捕獲各自 JSON、CSV、UART 複製至
[benchmarks/results/coremark_board_fetch_three_slots_20261029/](../benchmarks/results/coremark_board_fetch_three_slots_20261029/)，
共 12 份 byte-exact 捕獲及 manifest。manifest 含來源、檔案 SHA256、RTL hash、
兩組 kernel 比較與等待正規化。重新解析 UART 後，metadata、所有 counters 與 benchmark 欄位皆與 JSON 一致。

使用者本次仍以 `baseline_performance`／`baseline_validation` 作為原始輸出資料夾，
時間戳檔名沒有覆寫舊資料；硬體分類以 features 與新封存的 off/on 檔名為準。
