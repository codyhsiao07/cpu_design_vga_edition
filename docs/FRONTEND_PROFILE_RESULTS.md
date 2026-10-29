# CoreMark frontend_wait 實測紀錄

日期：2026-10-28。分類與重現方式見 [FRONTEND_PROFILE.md](FRONTEND_PROFILE.md)。
本輪只新增 observer/TB、分析工具及執行文件，沒有修改工作目錄的 CPU、I-cache、
hazard、PMU 或乘除法器。逐檔 SHA256 保存在各產物目錄，執行前後相同。

## 版本與適用範圍

開始 profiling 時，工作目錄已包含 `513a2bf` 的 radix-4 Booth 乘法器（17 輪）。
因此目前 RTL 的結果不能直接套成先前板上 frontend_wait=81.289% 的精確分配。
另外使用該提交之前的 32 輪乘法器，在 ignored build 目錄建立隔離副本作參照；
不 checkout、不覆寫目前 RTL，其餘 simulation sources 與 `.mem` 保持相同。

兩種觀測都使用官方兩組 seed、固定 3 iterations、overlap OFF，I/D/L2=8/8/16 KiB。
TB 為 100 MHz metadata、UART 2 Mbaud、MIG model。這是短 RTL profiling；板上為
50 MHz、115200 baud、自動校準後 400 iterations、實際 DDR，兩者不能直接替代。
特別是本輪 main 未包含自動校準，UART 文字輸出的權重也不同。

「核心函式」區間是 call iterate 退休之後，到 iterate return 退休當拍；
「每輪」由第一個 core_bench_list call 的退休 PC 分界。它們不是宣稱完全等同
官方 timer 的 MMIO 取樣點；第一輪前的函式 prologue 留在核心函式總計。

## 舊 32 輪乘法器參照

隔離副本取自 `dc3b419e2fa3d6dbd84cd6d2e36958ae61f09dd5:booth_multiplier.v`，
SHA256=`824035c9dbe0c7abaf4b81f548477908b74533f45f46a94f23e95d4736ef73ea`。
兩組官方 CRC 均 PASS，main return=0、features=0。其他 RTL 與下節目前版本相同，
每組兩版使用相同 firmware SHA256。

| 種子組／區間 | 全部 cycles | frontend_wait | 占全部 cycles |
| --- | ---: | ---: | ---: |
| performance main | 5,859,967 | 4,726,033 | 80.6495% |
| validation main | 5,866,124 | 4,731,145 | 80.6520% |
| performance 核心函式 | 5,323,524 | 4,330,317 | 81.3431% |
| validation 核心函式 | 5,330,215 | 4,335,805 | 81.3439% |

以 performance 核心函式的 frontend_wait 分配：

| 分類 | cycles | 占 frontend_wait | 占全部核心 cycles |
| --- | ---: | ---: | ---: |
| hit lookup／交接 | 1,963,598 | 45.3454% | 36.8853% |
| miss | 3,609 | 0.0833% | 0.0678% |
| 後端反壓 | 1,991,964 | 46.0004% | 37.4181% |
| redirect 關聯等待 | 371,146 | 8.5709% | 6.9718% |
| 合計 | 4,330,317 | 100% | 81.3431% |

validation 相同四類分別為 45.2706%、0.0810%、46.0762%、8.5722%，
與 performance 的方向一致。第一輪 miss 占 frontend_wait 約 0.19%；第二、三輪
均約 0.0300%。後兩輪其餘分類也接近，performance 的 hit 約 45.397%、
backend 約 46.009%、redirect 約 8.564%。

舊參照的 performance 核心函式中，有 1,701,708 拍 response 已有效，但後端不收，
占全部核心 cycles 的 31.9658%。這是直接的反壓證據；其中的確切可消除成本仍需
對應後端改良實驗。全部確認 miss 的 frontend 曝露為 5,016 拍，扣除與 backend
重疊的 288 拍、與 redirect 重疊的 1,119 拍，剩下主表的 3,609 拍。

整段 main 的分布也保留，避免用核心函式分布冒充 main：

| performance main 分類／frontend_wait | 舊 32 輪參照 | 目前 radix-4／17 輪 |
| --- | ---: | ---: |
| hit lookup／交接 | 45.6390% | 50.1417% |
| miss | 0.1138% | 0.1253% |
| 後端反壓 | 44.3382% | 38.8463% |
| redirect 關聯等待 | 9.9090% | 10.8866% |

舊參照的核心 frontend 81.3431% 接近先前板上的 main 81.2891%，但只是接近，
並非板上原始 400 輪逐拍紀錄已被拆分；區間、迭代次數、MIG model 與 bitstream
來源識別的限制仍適用。歷史來源另有 multiplier SHA，避免與目前工作目錄混用。

## 目前工作目錄：radix-4／17 輪

官方兩組 CRC 均 PASS，main return=0、features=0。整段 main 的三個獨立 observer
計數與 UART PMU 完全一致，四種分類的總和也完全一致：

| 種子組 | main cycles | main retired | main frontend_wait | 占 main cycles |
| --- | ---: | ---: | ---: | ---: |
| performance | 5,435,572 | 977,067 | 4,301,638 | 79.1386% |
| validation | 5,441,729 | 977,507 | 4,306,750 | 79.1430% |

核心函式結果，以 frontend_wait 作分母：

| 分類 | performance cycles | performance 比例 | validation cycles | validation 比例 |
| --- | ---: | ---: | ---: | ---: |
| hit lookup／交接 | 1,963,598 | 50.2521% | 1,962,845 | 50.1623% |
| miss | 3,609 | 0.0924% | 3,512 | 0.0898% |
| 後端反壓 | 1,569,144 | 40.1573% | 1,574,953 | 40.2494% |
| redirect 關聯等待 | 371,146 | 9.4983% | 371,675 | 9.4985% |
| frontend_wait 合計 | 3,907,497 | 100% | 3,912,985 | 100% |

performance 的核心函式共 4,900,704 cycles；上述四類改以全部核心 cycles 為分母，
分別為 40.0677%、0.0736%、32.0187%、7.5733%，合計 79.7334%。
兩種分母代表不同問題，不能把 50.25% 說成整支程式有一半時間都在 hit lookup。

第二、三輪結果接近，第一輪 miss 比較多：

| performance 迭代 | frontend／全部 cycles | hit／frontend | miss／frontend | backend／frontend | redirect／frontend |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 79.7717% | 50.1287% | 0.2100% | 40.1499% | 9.5114% |
| 2 | 79.7135% | 50.3140% | 0.0333% | 40.1596% | 9.4931% |
| 3 | 79.7142% | 50.3155% | 0.0333% | 40.1604% | 9.4908% |

validation 的第二、三輪也接近：hit 約 50.22%、miss 約 0.0332%、backend 約 40.25%、
redirect 約 9.49%，以上同樣以各輪 frontend_wait 作分母。

## 從重疊資料確認反壓與 miss

在目前 RTL 的 performance 核心函式：

- 1,278,888 拍是 response valid 已成立，但 stall_id=1。這是明確的後端不收，
  不是 I-cache 尚未提供指令；占全部核心 cycles 約 26.1%。
- 後端類的 MEM、EX、資料 hazard 曝露分別為 1,034,723、507,384、162,612 拍，
  原因會重疊，不能相加。
- 確認 miss 的全部 frontend 曝露為 5,016 拍，其中 288 與 backend 重疊、
  1,119 與 redirect 重疊，剩下 3,609 歸主表 miss。
- backend 與 redirect 的交集為 0，因此切換兩者的分類優先順序，這批結果不變。
- 核心函式有 23,015 次 EX recovery、101,098 次 ID 預測 taken redirect。
  這是事件次數，不是 cycles，也不等於所有事件的額外 penalty。

## 命中流程與請求間隔

排除兩筆請求間出現 stall_id、redirect 或 miss 狀態後，目前 RTL 的 performance
共 601,555 個乾淨 request 間隔，全部為 4 拍；validation 的 600,816 個也全部為 4 拍。
這是實際觀測，對應先前 RTL 的 T0 request、T2 拍後 response valid、T3 交接、
T4 下一筆 request。

所有 hit（包含其他干擾情境）的 response 首次可見時間，以取樣上升緣計算：
performance 有 976,743 筆為 3 拍、12 筆為 17 拍、6 筆為 34 拍；validation 分別為
977,186、13、4 筆。少數長樣本的具體原因尚未獨立追蹤，不能把這個未過濾的
histogram 直接解讀成純 tag/data array 固定延遲。
舊 32 輪參照的上述乾淨 request 間隔與 hit availability histogram 也完全相同。

主表 hit 類也不是全部都在等陣列讀取。performance 核心函式中，1,212,408 拍
尚未有 response，751,190 拍則 response 已有效且可以交接；兩者合計 1,963,598。
因此它更適合用來研究整條 fetch pipeline／交接吞吐，而不是單獨判定 SRAM 慢。

## 驗證證據

- Observer 定向 TB 通過，含回溯 miss／取消結果、反壓與 response、redirect 恢復、
  ID 有效時不計數及跨 main 結束的 pending request。
- 負向測試只改 ignored build 的 observer 副本，故意把 backend 分到 redirect。
  即使總和仍正確，獨立定向 TB 仍因 `wrong category 2` 失敗。
- 新 Python 分析測試 4/4 通過；與原 perf 工具一起執行共 13/13 通過。
- CoreMark 全系統仍保留原 CPU assertions、UART pin 解碼、PMU interval scoreboard、
  counter freeze 與官方 CRC 檢查。
- 兩組官方 seeds × 兩種已存在的乘法器版本共 4/4 次完整系統 profiling 通過。
  各次 main 的 cycles／退休數／frontend_wait 均精確對上 PMU；所有 scope 的
  四類加總精確等於 frontend_wait，16-bin histogram 也精確相符。
- 每次執行前後 36 個 root RTL 檔案 SHA256 相同；未修改工作目錄的架構。

目前 RTL 的產物在 `build_perf/frontend_profile/`，包含原始 `.profile.txt`、
JSON、分類 CSV、UART、trace、log、反組譯與 RTL hash。歷史參照放在獨立的
`build_perf/frontend_profile_original/`，並記錄實際使用的 multiplier commit/hash。

## 對 I-cache 決策的意義

目前看到的是固定 hit 請求間隔、真實後端反壓與控制流恢復混在 frontend_wait 中。
單純增加 cache 容量，對這支已高度命中的 CoreMark 缺少足夠支持。
若要研究取指架構，應把 request initiation interval、回應緩衝／交接、
多筆 in-flight 請求與 redirect 取消規則一起考量。

比例也會隨其他瓶頸變動：兩種乘法器版本的核心 hit 類都恰為 1,963,598 拍，
但占 frontend_wait 從 45.3454% 變成 50.2521%，原因是後端等待減少，分母縮小，
不能說 I-cache 因此變慢。本次既有兩版差異只作版本釐清，沒有新增乘法器改良。

本輪沒有實作任何新架構，也不把分類占比當成可直接消除的時間：redirect 類含
目標的正常取指，miss 類含原本的 lookup，backend 可能與 cache 等待重疊。
