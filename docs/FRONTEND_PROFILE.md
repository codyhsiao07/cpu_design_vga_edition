# CoreMark frontend_wait 的 TB 分析

本流程只加入 simulation observer、wrapper TB 與 Python 分析工具，不修改 CPU、
I-cache、hazard 或 PMU 的行為。使用 `FETCH_OVERLAP_EN=0`，不啟用先前的取指實驗。

## 觀測對象與分類

逐個 core clock 上升緣取樣原始條件：

```verilog
frontend_wait = !id_valid && (if_pending || req_blocked);
```

只在 PMU RUNNING 區間計數。完成後，比對 observer 的 main cycles、退休指令數及
frontend_wait 與硬體 PMU 完全一致，四類總和也必須逐拍完整涵蓋 frontend_wait。

同一拍可以同時有後端停頓、redirect 恢復與 miss。主表採以下互斥優先順序：

| 順序 | 類別 | 定義 |
| --- | --- | --- |
| 1 | 後端反壓 | `stall_id=1`，包含 MEM、長 EX 操作與資料 hazard；即使 cache 也沒準備好，這拍仍先歸後端。 |
| 2 | redirect 關聯等待 | 沒有上述反壓，且正處於 redirect 恢復，或這筆請求最後被 redirect 取消。 |
| 3 | miss 請求等待 | 沒有上述兩種情況，這筆請求經 tag decision 確認為 miss。 |
| 4 | hit lookup／交接 | 沒有上述情況，請求確認為 hit，包含查找 pipeline 及 response 交接當拍。 |

Redirect 恢復從 `fe_redirect_valid` 起，直到最後一次 redirect 的目標 response
被 CPU 接受。ID 預測 taken、EX 預測修正都包含在內。被取消請求在取消前已花的
等待也標為 redirect-associated work；這是依請求最後結果回溯標記。

為避免把「還沒查到 tag 的 miss」誤算成 hit，observer 先保存這筆 request 的各種
等待狀態，再依 tag decision 與最終完成／取消結果提交。使用 PC + epoch 匹配，
排除被取消的舊 lookup。main 結束時還未完成的請求，等待它解析後才提交舊樣本。

四類是觀測狀態與請求結果的分配方式，不等於各項修改可省的 cycles：

- 後端反壓期間可能同時有 cache 等待。
- redirect 類包含目標請求本身的正常查找時間。
- miss 類包含該筆請求初始的 lookup 與最終交接時間，並非已扣掉 hit 成本的額外 miss penalty。
- hit 類另外分成「還沒有 response」與「response 已有效、可交接當拍」。

原始輸出另存 16-bin joint histogram：bit0 backend、bit1 redirect-associated、
bit2 confirmed miss、bit3 raw response valid。Python 同時提供交集，以及
`redirect > backend > miss > hit` 的另一種分配，顯示分類優先順序的影響。
`backend_with_available_response` 是回應有效但 `stall_id=1` 的明確反壓證據。

## 量測區間

1. `main`：與既有 PMU 相同，從 call main 退休之後，到 outer return 退休當拍。
2. `iterate_function`：從 call iterate 退休之後，到該次 iterate 返回退休當拍。
   包含核心演算法與函式 prologue/epilogue，排除框架校準、UART 與 timer functions。
   此區間不是宣稱與官方 timer 的兩次 MMIO 讀取點完全相同。
3. 各迭代：由 ELF disassembly 找出 iterate 內第一個 `core_bench_list` call 的
   退休 PC，作為每輪起點，到下一次相同 PC／iterate 返回。第一輪起點前的
   prologue 保留在 iterate_function，不強行分到第一輪。

預設固定 3 iterations，不做自動校準；兩組官方 seeds 都跑。第一輪可能已受到
初始化的 cache 暖機影響，因此稱「第一輪」，不稱完全 cold-cache。
第二、三輪分開輸出，可檢查後續分布是否接近。

## 執行

```powershell
make frontend-profile-tb
```

或：

```powershell
python tools/run_frontend_profile.py --iterations 3 --out-dir build_perf/frontend_profile
```

兩個 simulator processes 預設並行；完整 CoreMark RTL 模擬需等待數分鐘以上。
可用 `--kind performance` 只跑一組、`--seeds 1` 額外加入 random MIG backpressure、
`--skip-build` 使用已建好的相同迭代映像。實板用 `*_auto.mem` 不會被覆寫。

只重新分析已存在的原始紀錄：

```powershell
python tools/run_frontend_profile.py --iterations 3 --analyze-only --out-dir build_perf/frontend_profile
```

本次核對版本時，工作目錄的乘法器已有 `513a2bf` 的 radix-4 提交（17 輪）；
這不是本輪 profiling 的變更。為避免與先前板上報告混用，另以該提交的 parent
中舊 32 輪乘法器作隔離 TB 參照：

```powershell
python tools/run_frontend_profile.py --iterations 3 --skip-build --multiplier-ref '513a2bf^' --out-dir build_perf/frontend_profile_original
```

此選項以 `git show` 讀取舊檔，僅寫到 ignored build 目錄供 simulator 編譯，
不 checkout、不覆寫工作目錄的 `booth_multiplier.v`。其他 RTL 與同組 `.mem`
保持相同。結果記錄實際使用的歷史 commit 與乘法器 SHA256；重新分析時也須
帶相同 `--multiplier-ref`。既有板上報告沒有 bitstream source fingerprint，
因此歷史參照不宣稱已證明與板上 bitstream 每個來源位元完全相同。

產物：

- `summary.json`：兩組 seeds、各 scope 的分類數量、占 frontend_wait 比例、占 scope 全部 cycles 比例。
- `performance_s0.profile.txt`／`validation_s0.profile.txt`：TB 原始整數計數與交集。
- 同名 `.profile.json`：解析後的完整結果；`.json/.csv/.uart.txt/.trace/.log` 保留原系統驗證證據。
- 同名 `.profile.csv`：每種分類的 cycles、占 frontend_wait 與占 scope 全部 cycles 兩種比例。
- `iterate_*.dis`：用來選定 scope marker 的實際反組譯。
- `rtl_sha256.json`：所有 root synthesizable `.v` 檔案的 hash；執行前後核對未變更。

另有兩個 request-level 診斷 histogram：

- `clean_request_gap_histogram`：兩筆相鄰已接受 request 之間沒有 stall_id、redirect、
  miss 狀態的間隔，觀察原本全 hit 流程的 initiation interval。
- `hit_availability_histogram`：成功匹配 hit 請求，從接受 request 到第一個取樣到
  response valid 的上升緣，含上升緣取樣規則。例如 RTL 在 T2 上升緣後產生 valid，
  observer 在 T3 上升緣取樣到它，所以記為 3；不能誤認為又多了一拍內部查找。
  Histogram 的 64 表示 >=64 拍。

## 驗證與範圍

- Observer 定向 TB：hit、miss、response 已到但不收、反壓交集、lookup 前取消、
  redirect 目標 miss、ID 有效時不計 frontend_wait、跨 main 結束的 pending request。
- 獨立預期數值檢查分類與 joint histogram；不是只檢查總和。
- 負向 mutation：僅在 ignored build 目錄把 backend 分錯成 redirect，分類總和仍正確，
  定向 TB 會因 `wrong category` 失敗，證明它能抓到分類錯誤。
- Python 測試檢查兩種分母、重疊與優先順序、缺漏／重複／負值／巢狀 scope 不一致。
- 全系統保留既有 CPU assertions、UART TX pin 解碼、main return、官方 CRC、PMU
  scoreboard 與 counter freeze 檢查。

TB 使用 100 MHz metadata、2 Mbaud UART、MIG simulation model，I/D/L2=8/8/16 KiB。
這是短 RTL profiling，不報正式 CoreMark 分數。它能檢查目前 RTL 的等待來源，
不能把結果直接當成板上 400 iterations 的精確拆分，尤其 main 的框架／UART 占比
與實際 DDR 等待不同。正式 kernel 以外的差異可藉 iterate_function scope 排除。

實際結果見 [FRONTEND_PROFILE_RESULTS.md](FRONTEND_PROFILE_RESULTS.md)。
CPU／I-cache 的修改由分析後再決定。
