# 三槽位取指驗證結果（2026-10-29）

使用目前 radix-4 Booth 乘法器，比較 `FETCH_OVERLAP_EN=0` 與 `1`。
OFF feature flags=0；新版 ON=3。I/D/L2 容量同為 8192/8192/16384 bytes。
來源、實作與使用方式見 [FETCH_THREE_SLOTS.md](FETCH_THREE_SLOTS.md)。

## CoreMark 同映像 A/B

官方 performance／validation 各固定一次迭代；每種各跑 deterministic 與 random memory delay。
8/8 個完整系統測試均 return=0、官方 CRC PASS、UART TX 解碼與 PMU snapshot 檢查通過。
模擬使用 100 MHz，這些短程結果不滿 10 秒，不是正式 CoreMark 分數，也不是實板結果。

| 官方配置 | 記憶體延遲 | OFF kernel | ON kernel | 時間減少 |
|---|---|---:|---:|---:|
| performance | deterministic | 16,373 µs | 9,935 µs | 39.321% |
| performance | random seed 1 | 16,375 µs | 9,937 µs | 39.316% |
| validation | deterministic | 16,391 µs | 9,960 µs | 39.235% |
| validation | random seed 1 | 16,393 µs | 9,962 µs | 39.230% |

不把兩種官方 seed 的 throughput 平均成一個分數。後續實板量測已另存於
[COREMARK_BOARD_FETCH_THREE_SLOTS.md](COREMARK_BOARD_FETCH_THREE_SLOTS.md)，performance 每迭代時間減少 39.42%。
已確認乘法器 SHA256 仍為 `2e7455a63f0374f482cbe7b0133eada6a0e7dd36e899741aa1353ce4b2e13551`。

## 定向 TB 與 CPU 回歸

`fetch_slots_tb` 以真實 L2/arbiter 與 DDR 模型，跑八個延遲種子，全部通過：

- A 等 DDR2、B 命中 L2、C 命中 I-cache；B/C 完成時 CPU response 仍等待 A。
- 三條同 line 的指令只讀一條 line（四次 DDR 128-bit command）。
- 三槽全滿時同拍 pop/push；ready=0 時 response 保持。
- 命中串流連續 32 條，第一條回應後每拍交付一條。
- 環狀槽位重用、同 set 的回填替換、redirect 與未完成舊回填。
- burst 首拍錯誤、共用回填的所有等待者都得到錯誤、完整排空與成功重試。
- 300 次 redirect／槽位重用，獨立 FIFO oracle 檢查每條 PC 與指令資料。

專用 `fetch_dependencies` 在 deterministic + random seed 1/2 都通過，
每次 main 恰好退休 31 條，獨立 RV32IM oracle 的 PC／暫存器寫入全部吻合。
新三槽 request/response scoreboard 與 pending 計數也通過。

完整 CPU 回歸使用 smoke/count/tail/alu/branch/array_small/array_large/muldiv/stress，
各 deterministic + random seed 1/2；新增 fetch_dependencies 另跑同三組種子。
每次比對 main 全部退休 PC 與暫存器寫入、PMU 起訖、UART 與凍結快照。
30/30 次全部通過，總計逐條比對 794,850 條 main 區間退休指令。
彙整結果保存在下方原始資料資料夾。
九個既有映像保留了舊版不含可選 features 欄位的 UART 格式，亦驗證向下相容；
其 RTL 明確以 `PERF_FETCH_OVERLAP` 編譯。新增 dependency 與所有 CoreMark 映像都回報 features=3。

另通過 baseline I-cache redirect race TB、原有 L2/arbiter TB 與 13 個 Python 工具測試。

## Vivado 2020.2 合成

Artix-7 `xc7a100tcsg324-1`，`FAST_SYNTH`，20 ns 時脈，out-of-context synthesis + opt。
CPU+L1 的檢查使用 USE_MIG=0、USE_VGA=0；L2 額外獨立合成。
四組皆無 synthesis error、無 critical warning，未推導 latch。

| 範圍 | 模式 | LUT | FF | BRAM tiles | 估計 WNS |
|---|---|---:|---:|---:|---:|
| CPU+L1 | OFF | 12,431 | 7,670 | 16 | +4.252 ns |
| CPU+L1 | ON | 13,355 | 7,702 | 32 | +4.975 ns |
| L2 | OFF | 5,850 | 3,047 | 0 | +13.289 ns |
| L2 | ON | 8,400 | 3,617 | 0 | +12.267 ns |

兩模式的 cache 邏輯容量相同；實體 RAM/LUT 的映射與打包不同。
L2 在這次合成中使用 LUT memory，沒有推導為 BRAM，不能把 report 的 BRAM=0 解讀為沒有 L2。
DRC 仍有 OOC 電壓設定與 CPU RAM reset/control 類警告，完整報告已保存。
這些是未 place/route 的估計，不是整板 MIG timing closure；也沒有在本次產生或燒錄整板 bitstream。

## 原始資料

可追蹤的捕獲與合成報告：
[benchmarks/results/fetch_three_slots_20261029](../benchmarks/results/fetch_three_slots_20261029/)。
含八組 CoreMark JSON／CSV／UART／simulator transcript、A/B summary、合成 utilization/timing/DRC，
另含 30 組 CPU JSON／UART／simulator transcript、八組定向 TB 輸出，
以及 RTL SHA256 與各檔案來源／SHA256 manifest。

本機完整執行輸出位於 `build_perf/fetch_slots/`（Git ignored），
包括完整退休 traces、逐次 test log 與可重跑的 simulator images。
新功能的定向測試可用 `make fetch-slots-tb` 重跑。
