# 效能監測驗證紀錄

日期：2026-10-28。此紀錄涵蓋本機 RTL 模擬、standalone PMU synthesis，
以及使用者自行燒錄後的 smoke、count、array_small 實板測試。
操作與計數定義見 [PERFORMANCE_MONITOR.md](PERFORMANCE_MONITOR.md)。

## 結果

- PMU unit TB 通過：起訖、連續退休、巢狀返回、結束當拍計入、快照保持、MMIO 錯誤、fault、64-bit 進位與 reset。
- 27/27 次完整系統測試通過：9 支程式，各 deterministic 加兩個 random-backpressure seed。
- 6/6 次 production cache 配置測試通過：smoke、count、muldiv，各 deterministic 加一個 random seed。
- 28/28 項原有 deterministic 系統回歸、9/9 次 test29/30/31 random-stall 回歸通過。
- 16/16 項原有子系統／工具檢查通過，含 UART MMIO、bootloader、分支 redirect、I/D/L2、VGA 與乘除法。
- 7/7 項新 Python 工具測試通過，含報告格式、64-bit 數值、signed return、JSON/CSV、RV32M 邊界、serial 分段接收與逾時保留原始資料。
- `board_top` 的 Icarus synthesis-mode elaboration 通過；新增訊號無 implicit net。
- Vivado 2020.2 對 `performance_monitor` 的 xc7a100tcsg324-1 standalone synthesis/opt_design 通過：954 LUT、1028 FF、0 BRAM。此數字只涵蓋 PMU，不包含 SoC 內的退休 sideband。

## 完整系統數據

I/D/L2 = 8/8/16 KiB，TB core_hz = 100 MHz、UART = 2 Mbaud。
表格為模擬 cycles，不是板上量測；`count` 額外注入三段 EX hold，各 80 拍。

| 程式 | 退休指令數（所有 seed 一致） | cycles deterministic | cycles seed 1 | cycles seed 2 |
| --- | ---: | ---: | ---: | ---: |
| smoke | 2 | 9 | 9 | 9 |
| count | 35 | 577 | 579 | 578 |
| tail | 3 | 14 | 14 | 14 |
| alu | 5,132 | 21,108 | 21,111 | 21,111 |
| branch | 5,504 | 24,855 | 24,864 | 24,859 |
| array_small | 2,319 | 12,175 | 12,212 | 12,207 |
| array_large | 147,470 | 784,569 | 787,658 | 787,643 |
| muldiv | 91 | 944 | 952 | 957 |
| stress | 104,363 | 477,016 | 477,776 | 477,700 |

每次逐條核對量測區間的 PC 與 register write，含沒有 register write 的指令，
不消除重複值。cycles/instructions/branches 再與 TB 獨立 interval scoreboard 核對；
從實際 UART TX pin 解碼的報告再與 reference 比對。報告執行期間全部 15 個 counter 維持不變。

`count` 恰有 4 次 D-load、4 次 D-store、4 條條件分支及 3 次方向預測失誤，UART H 恰好一個。
另做 mutation check：只在 ignored build 目錄建立移除 MEM consumed gating 的 RTL 副本；
相同 forced-hold TB 會報 `completed memory payload re-issued`，確認檢查可以抓到重送錯誤。

## 產物與重現

- 最終完整系統：`build_perf/final_verification/`，含 summary.json、各次 trace/UART/JSON/CSV/log。
- Production：`build_perf/production_final/`。
- 舊系統回歸：`build_perf/legacy_final/`、`build_perf/random_legacy_final/`。
- 子系統：`build_perf/subsystem_final/`。
- PMU synthesis：`build_perf/synth/utilization.rpt`、`performance_monitor.dcp`、`vivado.log`。
- Mutation：`build_perf/mutation/mutation.log`，這是預期失敗的負向測試。

```powershell
make perf-tb
python tools/run_perf_verification.py --skip-build --cases smoke,count,muldiv --production --seeds 1 --out-dir build_perf/production_final
```

新建置的 `.mem.json` 記錄編譯器版本、CFLAGS、來源及映像 SHA256。
本次 compiler 為 xPack RISC-V GCC 15.2.0；workload 使用 rv32im/ilp32、-O2。

本次也修正既有 test28 的錯誤參考 checksum：八個指定 RV32M 結果的 XOR 為
`0x42DC3CA2`，原常數 `0x140AA3A0` 會讓正確執行也回傳 FAIL。修正後 DUT 與
獨立 RV32IM interpreter 逐條一致，main 回傳 `0x2800C0DE`。

## 實板 smoke 測試

使用者於 2026-10-28 自行燒錄新版 bitstream，經 COM5 執行 `perf_smoke`，
終端機截圖與保存的 JSON/UART 紀錄一致：

| 項目 | 結果 |
| --- | --- |
| 狀態／答案檢查 | COMPLETED／PASS |
| main 回傳值 | `0x00000011`（17） |
| 退休指令數／cycles | 2／9 |
| 報告核心頻率／執行時間 | 50 MHz／180 ns |
| I/D/L2 | 8/8/16 KiB |
| I-cache | 2 次 lookup、0 miss |
| 前端等待 | 6 cycles |

原始產物：`build_perf/results/perf_smoke_20261028T074854551303Z.json`，
以及同名 `.uart.txt`、`.csv`。映像 SHA256 與建置 manifest 相符。
這確認最小 main 的實板執行、結束快照與 UART 報告路徑。

## 實板 count 測試

使用者經 COM5 執行 `perf_count`，截圖與保存的報告一致，狀態 COMPLETED、答案 PASS。

| 項目 | 實板結果 |
| --- | --- |
| main 回傳值 | `0x0000002a`（42） |
| 退休指令數／cycles | 35／598 |
| 報告核心頻率／執行時間 | 50 MHz／11.96 us |
| I-cache lookup／miss | 38／2 |
| D-load／miss | 4／1 |
| D-store／miss | 4／3 |
| 條件分支／方向預測失誤 | 4／3 |
| frontend／memory wait | 555／157 cycles |
| load-use／multiply／divide wait | 1／66／66 cycles |

保存的原始 UART 在報告前恰有一個 H；35 條指令、4 次 D-load、4 次 D-store、
4 條條件分支及 3 次方向預測失誤均符合定向程式的預期。
原始產物：`build_perf/results/perf_count_20261028T075235560902Z.json` 與同名 UART/CSV。
這次為正常實板執行，沒有 TB 的三段 80 拍 EX hold；因此不要求與 TB cycles 相等。
等待計數可能重疊，不能相加。

## 實板小陣列測試

使用者經 COM5 執行 `perf_array_small`，狀態 COMPLETED、答案 PASS；
保存報告的映像 SHA256 與目前建置映像一致。

| 項目 | 實板結果 |
| --- | --- |
| main 回傳值／退休指令數 | 0／2,319 |
| cycles／執行時間（50 MHz） | 12,954／259.08 us |
| CPI／IPC | 5.586028／0.179018 |
| I-cache lookup／miss | 2,322／2 |
| D-load／miss | 256／9（3.515625%） |
| D-store／miss | 128／128（100%） |
| 條件分支／方向預測失誤 | 384／6（1.5625%） |
| frontend／memory／load-use wait | 10,247／3,469／256 cycles |

陣列包含 128 個 32-bit word（512 bytes），先初始化，再讀取加總兩輪。
因此預期有 128 次 store 與 256 次 load；退休指令數、memory 次數與分支次數
皆與獨立指令模型相符。D-cache 為 no-write-allocate，初始化的 store miss 不會
配置 cache line，因此 100% store miss 符合此程式及目前寫入策略。
512-byte 陣列小於 8 KiB D-cache，多數重複讀取命中快取。

原始產物：`build_perf/results/perf_array_small_20261028T075632480213Z.json` 與同名 UART/CSV。
大陣列的後續實板結果記錄如下；其他效能程式仍待實板測試。

## 實板大陣列測試

使用者經 COM5 執行 `perf_array_large`，狀態 COMPLETED、答案 PASS，
main 回傳 0；截圖與保存的 JSON 一致。

| 項目 | 實板結果 |
| --- | --- |
| 退休指令數／cycles | 147,470／856,846 |
| 執行時間（50 MHz）／CPI | 17.13692 ms／5.810307 |
| I-cache lookup／miss | 147,473／2 |
| D-load／miss | 16,384／1,026（6.262207%） |
| D-store／miss | 8,192／8,192（100%） |
| 條件分支／方向預測失誤 | 24,576／6 |
| frontend／memory／load-use wait | 684,796／266,760／16,384 cycles |

陣列包含 8,192 個 32-bit word（32 KiB），超過 8 KiB D-cache，先初始化，
再讀取加總兩輪。100% store miss 與 no-write-allocate 策略一致；兩輪連續讀取
每條 64-byte cache line 約 miss 一次，因此不能將 6.26% load miss 解讀成任意
工作集都能維持很低 miss rate。frontend 與 memory wait 會重疊，不能相加。

原始產物：`build_perf/results/perf_array_large_20261028T075903183041Z.json` 與同名 UART/CSV。
至此 smoke、count、小陣列、大陣列均已有實板紀錄。下一階段改用官方 CoreMark，
詳見 [STANDARD_BENCHMARKS.md](STANDARD_BENCHMARKS.md)；標準 benchmark 的實板結果仍待取得。

## 板級實作範圍

在你的 Vivado/MIG 專案加入 `performance_monitor.v` 並更新整合 RTL，重新完成整板
synthesis、implementation 與 timing/CDC 檢查，再產生 bitstream。開發驗證階段沒有
代替使用者產生或燒錄整板 bitstream；後續 smoke 實板結果單獨記錄於上節。
此紀錄未取得使用者專案的完整板級 timing/CDC 報告。
