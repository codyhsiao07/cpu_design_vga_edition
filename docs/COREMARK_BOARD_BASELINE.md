# CoreMark 實板基準：新乘法器，Fetch overlap OFF

紀錄日期：2026-10-28，Asia/Taipei。這份結果是後續取指／I-cache 實驗使用的基準。
使用者確認本次已燒錄新乘法器；硬體 PMU 回報取指 overlap 關閉。
本輪只保存量測紀錄，未更動 RTL。

2026-10-29 的新版 ON 實板比較已另存於
[COREMARK_BOARD_FETCH_THREE_SLOTS.md](COREMARK_BOARD_FETCH_THREE_SLOTS.md)；本文件繼續保存 OFF 對照基準。

## 固定條件

- 核心頻率：50,000,000 Hz；UART：COM5、115200 baud。
- I/D/L2：8192/8192/16384 bytes；features=0（Fetch overlap OFF）。
- 新乘法器：目前專案的 radix-4 Booth、17 輪；版本由使用者確認。
- 官方 CoreMark，2000-byte static data、單一 context、兩組官方 seeds。
- GCC 15.2.0、RV32IM/ILP32、-O2；完整 flags、upstream commit 保存在原始 JSON。
- 自動校準後兩組正式 kernel 都為 400 iterations，超過 10 秒，CRC PASS。
- performance 完成紀錄：2026-10-28 23:07:20 UTC+8。
- validation 完成紀錄：2026-10-28 23:08:18 UTC+8。

`features` 沒有編碼乘法器版本；新版另以 bit1 辨識三槽位。沒有取得 bitstream 檔案 hash。
硬體版本標籤以使用者提供的實板資訊為準，其餘條件與數據由 UART/JSON 核對。

## 新基準數據

| 指標 | performance | validation |
| --- | ---: | ---: |
| 狀態／main return／答案檢查 | COMPLETED／0／PASS | COMPLETED／0／PASS |
| main cycles | 836,043,356 | 837,282,280 |
| main retired instructions | 148,527,273 | 148,641,347 |
| main 時間 | 16.720867120 s | 16.745645600 s |
| main CPI | 5.628888 | 5.632903 |
| main IPC | 0.177655 | 0.177528 |
| CoreMark kernel 時間 | 13.056705 s | 13.076375 s |
| kernel iterations | 400 | 400 |
| kernel iterations/s | 30.635601 | 30.589517 |
| iterations/s/MHz | 0.612712 | 0.611790 |
| 官方 CRC | PASS | PASS |

CoreMark 的效能數值取 performance 種子組；validation 是另一組官方資料的驗證結果，
不將兩者平均成新的分數。這是保存的實板量測，未宣稱已提交官方認證。
main 含校準、初始化、驗證與 benchmark 內輸出；kernel 吞吐量只使用正式計時區間。

完整 main 事件計數：

| 計數器 | performance | validation |
| --- | ---: | ---: |
| I-cache lookup／miss | 151,353,445／21,642 | 151,400,150／21,640 |
| D-load／miss | 27,900,748／77 | 28,131,871／76 |
| D-store／miss | 7,228,213／1,230 | 7,180,023／1,225 |
| 條件分支／方向預測失誤 | 27,391,059／2,050,328 | 27,485,856／2,053,418 |
| frontend_wait | 666,162,358 | 667,168,022 |
| memory_wait | 176,159,464 | 177,073,124 |
| load_use_wait | 4,595,954 | 4,687,946 |
| multiply_wait | 86,257,422 | 86,257,422 |
| divide_wait | 5,379 | 5,313 |

frontend_wait 占全部 main cycles 分別為 79.680360%、79.682568%。
各等待計數會重疊，不能相加成互斥的時間分布。

## 與舊乘法器實板紀錄比較

同種子組的新舊兩次使用相同 firmware SHA256；核心頻率、cache 容量、features、
400 iterations 與 CRC 均相符。每種子／硬體版本目前各保存一次實板執行。

| 指標 | performance | validation |
| --- | ---: | ---: |
| 舊 kernel 時間 | 14.184226 s | 14.203896 s |
| 新 kernel 時間 | 13.056705 s | 13.076375 s |
| kernel 時間縮短 | 7.9491% | 7.9381% |
| kernel 吞吐提升 | 8.6356% | 8.6226% |
| main cycles 減少 | 71,881,031 | 71,881,107 |
| multiply_wait 減少 | 71,881,185 | 71,881,185 |
| multiply_wait 降幅 | 45.4545% | 45.4545% |

main cycles 的減少量與乘法等待減少量很接近，支持此次提升主要來自乘法器。
相同映像仍可能因計時值格式化、UART 輪詢等框架路徑有少量不同的退休指令數，
不能要求整段 main 的退休數完全相等。兩組的 cache miss、D-load/store 與分支失誤
次數保持一致，官方 CRC 也一致。

公式：時間縮短=`1-new_time/old_time`；吞吐提升=`old_time/new_time-1`。
兩種百分比的分母不同，不能混用。

## 原始資料保存

已將原本 ignored `build_perf/` 中的新舊四次量測複製至
[benchmarks/results/coremark_board_20261028/](../benchmarks/results/coremark_board_20261028/)，
每次各有原始 JSON、UART、CSV，共 12 份捕獲檔；沒有覆寫原本紀錄。

- `new_multiplier_performance.*`、`new_multiplier_validation.*`：目前有效基準。
- `old_multiplier_performance.*`、`old_multiplier_validation.*`：歷史對照。
- `manifest.json`：每份捕獲檔的 SHA256、原始位置、比較數據與版本證據範圍。

保存時重新解析四份原始 UART，metadata、全部 counters、CoreMark benchmark 欄位
都與 JSON 完全一致；新舊同組的映像 hash 與平台 metadata 也完全一致。

兩支 firmware SHA256：

- performance：`0176c81e3d6cb93542098189eee26e0ecf26f6d8cb624b240c6828358b56c4ff`
- validation：`a325fb689195551d31496420f87a17d2d183eeb7e1582a4d51f97ef5f3637ded`

後續取指實驗固定使用新乘法器，以本次 OFF 結果對照 ON／新取指架構，保留相同
頻率、cache、firmware 與各種子組，分開保存結果。TB 的逐拍等待拆分仍見
[FRONTEND_PROFILE_RESULTS.md](FRONTEND_PROFILE_RESULTS.md)，不與實板計數混為同一份量測。
