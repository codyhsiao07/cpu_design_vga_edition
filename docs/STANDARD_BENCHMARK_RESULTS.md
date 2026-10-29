# CoreMark 與取指改良驗證紀錄

日期：2026-10-28。此文件的 CoreMark 數據來自短 RTL 模擬，沒有跑滿官方要求的
10 秒，不是正式 CoreMark 分數，也不是已量到的 FPGA 提升。板上操作與正式 A/B
步驟見 [STANDARD_BENCHMARKS.md](STANDARD_BENCHMARKS.md)。

新乘法器的正式長時間實板執行已另記於
[COREMARK_BOARD_BASELINE.md](COREMARK_BOARD_BASELINE.md)，後續取指實驗以該 OFF 基準比較。
以下保留先前短 RTL 取指 A/B 的歷史紀錄。

2026-10-29 三槽位／hit-under-miss 的新版驗證見
[FETCH_THREE_SLOTS_RESULTS.md](FETCH_THREE_SLOTS_RESULTS.md)，與本文先前單筆同拍交接實驗分開記錄。

## 固定條件

- 官方 CoreMark commit：`1f483d5b8316753a742cbf5590caf5bd0a4e4777`，核心原始碼未修改。
- xPack GCC 15.2.0，RV32IM/ILP32、-O2、static memory、2000 bytes、單一 context。
- I/D/L2 = 8/8/16 KiB；TB core_hz = 100 MHz，UART = 2 Mbaud。
- 同一 seed 組的 A/B 使用完全相同 `.mem`，兩版均含 redirect 取消修正，只切換
  `FETCH_OVERLAP_EN=0/1`；最終 UART 報告由硬體分別回報 features=0/1。
- 本次 timed kernel 為 1 iteration；工具正確顯示 `timing_qualified=false`，分數為 N/A。

## 最終 A/B 結果

| 官方 seed 組 | Baseline kernel | Overlap kernel | 執行時間縮短 | 吞吐倍率 | CRC |
| --- | ---: | ---: | ---: | ---: | --- |
| performance：0, 0, 0x66 | 17,783 us | 16,061 us | 9.6834% | 1.107216 | 兩版 PASS |
| validation：0x3415, 0x3415, 0x66 | 17,800 us | 16,081 us | 9.6573% | 1.106896 | 兩版 PASS |

Performance 的 list/matrix/state CRC 為 `e714/1fd7/8e3a`；validation 為
`e3c1/0747/8d84`。兩組都由實際 UART TX pin 解碼後交給 host 驗證。

最終映像 SHA256：

- performance：`0e97eaad1576e3824b3faf73c412bef44cd54f3aa13209e07beff73375f45cae`
- validation：`fe86833e06ac73fc8e9a869929da5aeb06c2958344c49c230b003fc69a8b453b`

這是 `*_1.mem` 的 hash；板上自動校準使用 `*_auto.mem`，映像不同，應以它自己的
manifest 核對，不能與短版交叉比較。

完整 main 的數據另列，避免混同 timed kernel：

| 指標 | performance baseline | performance overlap |
| --- | ---: | ---: |
| main cycles | 2,313,981 | 2,130,516 |
| main retired instructions | 397,669 | 404,653 |
| main CPI | 5.818862 | 5.265044 |
| I-cache lookup／miss | 403,890／240 | 477,870／242 |
| D-load／miss | 58,603／76 | 58,603／76 |
| D-store／miss | 16,841／1,230 | 16,841／1,230 |
| frontend wait | 1,842,211 | 1,649,434 |
| memory wait | 441,700 | 446,352 |
| multiply wait | 313,566 | 313,566 |

main 包含初始化、驗證、計時讀取與 UART 文字格式化／輪詢；UART busy polling
在較快 CPU 上可能退休更多指令。因此整段 main 的指令數不必相等，也不能把其等待
分布當成單獨 timed kernel 的等待分布。原先的 main 起訖與退休計數定義沒有改變。

I-cache miss 很少，但 hit 仍有請求交接間隔；這支持測試取指吞吐的方向。
受控開關確實改善 kernel 時間，證實這段取指間隔是瓶頸之一。frontend、memory、
multiply wait 彼此會重疊，不能加總，也不能把約 80% frontend wait 全數解釋成
可消除成本。迭代乘法可作下一個獨立實驗；本次沒有同步改乘法器或 cache policy。

## 正確性與重現產物

- 官方兩組 seed × baseline/overlap × deterministic/random MIG backpressure：
  8/8 次完整系統 CRC 驗證通過，產物 `build_perf/coremark_ab_fixed/`。
  這批在加入報告 features 欄位前執行；kernel 時間為 performance 17,782→16,060 us、
  validation 17,800→16,080 us，random seed 的相對改善一致。
- 加入硬體 features 後再跑最終 deterministic 4/4 次：performance 產物
  `build_perf/coremark_final_performance/`，validation 產物 `build_perf/coremark_final/`。
  彙整 `build_perf/coremark_final_summary.json`；兩組 `comparison.json`／
  `validation_comparison.json` 也通過同映像、頻率、cache、CRC、flags 的公平比較檢查。
- Overlap 的 9 支效能程式 × deterministic/random seed：18/18 次通過，
  `build_perf/fetch_overlap_fixed/summary.json`。以獨立 RV32IM interpreter 逐條核對
  PC/register writes，核對退休計數，並解碼 UART、檢查報告期間 counter 凍結。
- Overlap 的原有系統回歸：28/28 項通過，
  `build_perf/fetch_overlap_legacy_fixed/summary.csv`。
- `icache_redirect_race_tb` 通過：redirect 與 response 生產同拍、held response
  取消、改向後新請求均覆蓋。這修正了改良實驗中實際發現的舊路徑回應問題。
- `performance_monitor_tb` 通過，包含 feature flags、量測邊界、連續退休、freeze、
  MMIO、fault、64-bit carry、reset。
- Python 工具測試 9/9 通過，新增標準 CRC、短跑禁止分數、10 秒時間門檻、
  可選 hardware flags 與不同迭代次數的正規化比較。

最終 performance 模擬曾因與 Vivado 同時執行碰到 host 300 秒逾時，當時未完成的
輸出不作成功結果；放寬模擬 host timeout 至 900 秒後完整重跑並通過。RTL 的
20,000,000-cycle watchdog 及斷言保持啟用。

```powershell
make coremark-tb
python tools/run_perf_verification.py --skip-build --fetch-overlap --seeds 1 --out-dir build_perf/fetch_overlap_regression
```

## 綜合範圍

Vivado 2020.2、xc7a100tcsg324-1，`icache_pipeline_top` standalone synthesis +
opt_design，`USE_MIG=0`、`USE_VGA=0`、`UART_BOOT_EN=0`：

| 資源 | Baseline | Overlap |
| --- | ---: | ---: |
| Slice LUT | 12,409 | 12,378 |
| FF | 7,671 | 7,670 |
| Block RAM tile | 16 | 16 |
| DSP | 0 | 0 |

兩版均無 synthesis error／critical warning，無 latch。DRC 仍有 CFGBVS、BRAM
非同步控制與顯示數量上限警告；OOC clock 也有 HD.CLK_SRC 未指定警告。
資源差異是這次綜合的結果，不作普遍面積改善承諾。產物在
`build_perf/fetch_synthesis/variant_0/`、`variant_1/`，含 utilization、DRC 與 DCP。

這次沒有執行完整 board/MIG 的 place-and-route，也沒有取得完整板級 timing/CDC
報告，不能據此宣稱改良版已達到板上 50 MHz。兩版實際 FPGA 時間差與正式
CoreMark 的取指 overlap OFF/ON 實板比較仍待依操作文件量測。

CoreMark 工作集只有 2000 bytes，能放入目前 D-cache。後續要用不同程式型態
補足結論，可再移植 Embench-IoT 的多個 workload；DDR／cache 容量與寫入策略
另以超過 cache 的工作集做獨立實驗，避免只為一支 benchmark 最佳化。
