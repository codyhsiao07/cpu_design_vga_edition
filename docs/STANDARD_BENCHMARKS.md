# 標準 benchmark、瓶頸判斷與硬體 A/B 比較

目前的小程式保留作監測器與指令完成的回歸驗證。正式效能分析從官方 CoreMark 開始，
維持完整 main 的 PMU 報告，另外保留 benchmark 自己的 timed kernel 計時。

目前後續實驗採用的實板基準是
[新乘法器、Fetch overlap OFF](COREMARK_BOARD_BASELINE.md)，附新舊原始捕獲與比較。

2026-10-29 的啟用模式已擴充為三個取指槽位與 I-cache/L2 hit-under-miss，
實作、測試與板上操作見 [FETCH_THREE_SLOTS.md](FETCH_THREE_SLOTS.md)。
新版已完成實板量測，結果見 [COREMARK_BOARD_FETCH_THREE_SLOTS.md](COREMARK_BOARD_FETCH_THREE_SLOTS.md)。

## Benchmark 選擇

| 選項 | 本專案的用途 |
| --- | --- |
| EEMBC CoreMark | 已移植。整數運算、linked list、matrix、state machine，官方 CRC 驗證；適合第一個可重現 CPU 基準。 |
| Embench-IoT | 後續的多 workload 套件。以無 OS、minimal libc 為設計前提，補足加密、壓縮、排序、字串等不同程式型態。 |
| SPEC CPU | 目前不採用。SPEC CPU2026 的工具鏈與執行環境是 OS 系統，SPECrate 至少 2 GB/copy，SPECspeed 至少 64 GB，與目前 RV32IM bare-metal／512 KiB linker 配置不相符。 |

來源：[CoreMark 官方 README](https://github.com/eembc/coremark/blob/main/README.md)、
[CoreMark bare-metal porting](https://github.com/eembc/coremark/blob/main/barebones_porting.md)、
[Embench 官方 README](https://github.com/embench/embench-iot)、
[SPEC CPU2026 system requirements](https://www.spec.org/cpu2026/docs/system-requirements.html)。

CoreMark 的標準資料大小是 2000 bytes，小於本板 8 KiB D-cache。因此它不能單獨
代表大工作集／DDR 效能。Embench 候選包括 `crc32`、`matmult-int`、`nettle-aes`、
`nettle-sha256`、`huffbench`、`sglib-combined`、`slre`；目前尚未移植這些 workload。
選取子集時只報各 workload 的結果，不把子集稱為完整 Embench 綜合分數。

## 官方原始碼與移植範圍

`benchmarks/coremark/upstream/` 保留原始六個核心檔案，沒有修改演算法、驗證常數或資料大小。
固定版本為官方 repository commit `1f483d5b8316753a742cbf5590caf5bd0a4e4777`，
檔案 SHA256 與來源見 `benchmarks/coremark/UPSTREAM.json`，每次建置都檢查。
五個 `core_*.c` 也通過上游 MD5；該 commit 的上游 `coremark.h` 本身與其 MD5 清單
不符，因此 header 以固定 commit 與 SHA256 核對，沒有為了通過檢查而改 header。
保留上游 LICENSE、README 與檔頭；port 與 UART 支援放在獨立的 `port/`。

Port 使用單一 context、static memory、volatile 官方 seeds、RV32IM/ILP32、-O2。
`HAS_FLOAT=0`，timer 需要的 64-bit 除法連結同一 toolchain 的 rv32im/ilp32 libgcc。
沒有增加 CSR 指令，也沒有依賴 OS、malloc、檔案系統或完整 libc。

Timer 讀取正在 RUNNING 的 PMU cycles，使用 high-low-high retry 避免進位撕裂，
再依 PMU core_hz 換成 microseconds。32-bit microsecond 差值可涵蓋約 71 分鐘，
足夠一般正式執行；沒有把模擬短執行偽裝成 10 秒。

## 先在板上跑標準基準

```powershell
make coremark
```

產生：

- `build_perf/coremark_performance_auto.mem`
- `build_perf/coremark_validation_auto.mem`
- 各自的 `.mem.json`，記錄 compiler、CFLAGS、libgcc、upstream commit、映像 SHA256。

兩支使用官方兩組 seeds；`ITERATIONS=0` 讓官方框架依實際 timer 校準執行次數。
每支執行前先按板子 Reset，COM5 換成你的實際 serial port：

```powershell
python tools/run_perf.py --port COM5 --baud 115200 --delay 3 --mem build_perf/coremark_performance_auto.mem --expect-return 0 --timeout 300 --out-dir build_perf/coremark_board/baseline_performance
```

第一支結束後，再按一次 Reset：

```powershell
python tools/run_perf.py --port COM5 --baud 115200 --delay 3 --mem build_perf/coremark_validation_auto.mem --expect-return 0 --timeout 300 --out-dir build_perf/coremark_board/baseline_validation
```

計時迴圈需要至少 10 秒，整個 main 還包含校準、初始化與報告，通常要等待數十秒。
不是一秒內返回的 smoke 測試。現有 PMU bitstream 可以執行這個 port；上板前不需要
為 CoreMark 額外增加計時周邊。新程式也能讀舊 PMU 的 control read=0，顯示 overlap OFF。

成功輸出應有：

- main `COMPLETED`、return 0。
- `CoreMark kernel: ... s, ... iterations; CRC: PASS`。
- 合格時間執行顯示 kernel iterations/s、per MHz；短執行顯示 `Score: N/A`。
- `Fetch overlap: OFF/ON (hardware-reported)`，辨識實際燒錄的模式。

上游 main 即使 CRC／時間檢查失敗仍回傳 0，所以 host 另外驗證三個 CRC，不能只看 return。
官方規則還要求兩組 seeds 均驗證通過、每次足夠時間及完整揭露編譯／記憶體配置；
工具的時間合格標記不等於官方認證或已完成對外提交。

## 全程 main 與標準計時要同時保留

- PMU 的 main 報告：包含初始化、官方自動校準、驗證與 main 內的 UART 輸出，
  保持原先 `(call retirement, outer return retirement]` 定義。
- CoreMark kernel 時間：官方 `start_time()` 到 `stop_time()`，只用這段算
  iterations/s；不使用整個 main 的時間冒充 benchmark 分數。
- CoreMark 的 UART 輪詢／時間值格式化會讓全 main 指令數隨硬體速度稍有不同。
  程式映像與 timed kernel 的迭代演算法保持相同，先比較 normalized kernel throughput。

目前 cache／分支／各類等待統計涵蓋整個 main，含 timed kernel 之外的程式，
不能直接當成 kernel 自己的等待分布；kernel 的時間差用同映像 A/B 實驗確認。

## 取指實驗：同拍交接與三槽位

目前 baseline `if_pending=1` 時不發新請求，命中 I-cache 仍要等回應 handshake 後的
下一拍才發送下一筆。低 miss rate 與高 frontend_wait 同時存在，因此「增加 cache
容量」未必能處理這段固定命中取指間隔。

新參數 `FETCH_OVERLAP_EN`：

- 0：保留 baseline request spacing，預設值仍為 0。
- 1：三個有序取指槽位，允許同拍回應與接受新請求；命中可連續查詢，
  不同 line 可在 I-cache／L2 查詢與主回填之間重疊。詳見三槽位設計文件。
  先前僅保留一筆 outstanding 的同拍版本已被此模式取代。

實驗也暴露出 redirect 與 I-cache response production 同拍的取消邊界問題。
已讓 kill 在 response 生產當拍有最終優先權，避免把舊路徑回應送入 pipeline，並新增
`icache_redirect_race_tb` 覆蓋生產邊界、held response 取消與改向後正常取指。

`performance_monitor` 的 `0x40010010` 寫入仍是 ARM/CLEAR；讀取回傳 feature flags，
bit0 表示 overlap，bit1 表示三槽位與 L2 hit-under-miss，新啟用模式為 `0x3`。
這個位址在舊 PMU 可讀且回傳 0，新 firmware 與舊 bitstream 相容。
原 schema=1 的報告允許可選 `features` 欄位，舊紀錄仍可解析。

對於正式 A/B，兩版使用相同的更新後 RTL／redirect 修正，只切換 overlap 參數。
在 `board_top` 的 top-level generic 設 `FETCH_OVERLAP_EN=0` 建 baseline，再設 1 建改良版，
保持 clock/cache/MIG/編譯器及 `.mem` 不變，兩版各自完成板級 implementation/timing 檢查。
每次重新燒錄後按 Reset、上傳相同映像，保存至不同 out-dir，並核對硬體回報 OFF → ON。
此處沒有代替使用者產生或燒錄整板 bitstream。

## 正確比較

```powershell
python tools/compare_coremark.py <baseline的JSON完整路徑> <overlap的JSON完整路徑>
```

工具要求相同映像 SHA256、頻率、I/D/L2 容量、官方 seed/data 配置、CRC 通過，
且硬體 flags 只差取指設定（舊模式 bit0，三槽模式 bit0+bit1）。預設要求兩次 timed kernel 都至少 10 秒。
自動校準可能選不同迭代次數，使用 `kernel_time/iterations` 正規化，不能直接比總秒數。
若更改頻率，應另做系統級比較，使用 `time=cycles/frequency`，不能只拿 CPI 當速度。

不要把 frontend_wait、memory_wait、multiply_wait 相加當成損失時間；它們會重疊。
本實驗以受控硬體開關及同一映像的時間差判斷改善，不把 frontend_wait 的約 80%
全部解釋成可消除的取指成本。CoreMark 也顯示明顯的迭代乘法等待，後續可用獨立
DSP／乘法器實驗驗證，但這次沒有同時改乘法器、cache policy 或容量。

## 模擬驗證與限制

```powershell
make coremark-tb
python tools/run_perf_verification.py --skip-build --fetch-overlap --seeds 1 --out-dir build_perf/fetch_overlap_regression
```

短 RTL 版本使用一次迭代驗證兩組官方 CRC，A/B 切換相同 ELF 映像，並包含 random
MIG backpressure。它沒有跑滿 10 秒，僅用於 CRC、資料路徑與相對時間分析，不報
正式 CoreMark 分數。上游短跑會印出「必須至少 10 秒」訊息，這個限制沒有被刪掉。

`tools/synth_fetch_comparison.tcl` 對兩模式做 CPU/L1 standalone synthesis，
`USE_MIG=0` 以外部 L2 port 取代板級 DDR；因此不代替完整 MIG/board timing closure。
實際數據與驗證結果記錄於 [STANDARD_BENCHMARK_RESULTS.md](STANDARD_BENCHMARK_RESULTS.md)。
