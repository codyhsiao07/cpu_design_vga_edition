# main 全程效能監測與 UART 報告

這是可選的 bare-metal 效能模式，使用非 VGA 的 `board_top`。硬體記錄
`main()` 及其所有被呼叫函式的執行，最外層呼叫返回後凍結計數，啟動碼再透過
UART 傳送報告。C 程式不必呼叫 begin/end，也不需要 CSR 或完整 libc。

## 先準備 FPGA

1. 使用更新後的主線 RTL，top 選 `board_top`，board XDC 維持
   `Nexys-A7-100T-Master.xdc`，DDR2 MIG、Clock Wizard 與 MIG XDC 維持原設定。
2. 在 Vivado **Design Sources** 加入新的 `performance_monitor.v`。更新
   `icache_pipeline_top.v`、`icache_top.v`、`icache.v`、`dcache.v`、`hazard_unit.v`。
   不要把 `performance_monitor_tb.v`、`performance_system_tb.v` 加入 synthesis。
3. 重新執行 synthesis、implementation、timing/CDC 檢查並產生 bitstream。
4. 確認 `board_top.UART_CLK_HZ` 等於 MIG 實際 `ui_clk`。板級預設為 50 MHz；
   CPU/cache/UART 同時使用這個時脈，報告時間也使用這個參數換算。
5. 燒入新 bitstream。舊 bitstream 沒有這個 MMIO 裝置，不能執行效能映像。

RTL 預設 synthesis 使用 FAST_SYNTH：I/D/L2 = 8/8/16 KiB；設置
`PRODUCTION_BUILD` 時為 64/128/256 KiB。不要只根據檔頭註解猜容量，報告會列出
實際編譯配置。Standalone PMU synthesis 僅檢查監測器可綜合性，不代替整板時序驗證。

## 建立並執行測試映像

在 repository 根目錄執行：

```powershell
make perf-suite
```

映像產生於 `build_perf/perf_*.mem`；每個映像旁有 `.mem.json` 建置紀錄。
**每次測試先按板上的 reset，讓 UART bootloader 重新待命**。更換 C 程式不必
重新燒 bitstream，但不能把第二個映像直接送給已經離開 bootloader 的 CPU。

例如執行小陣列測試，請把 COM7 改成實際 COM port：

```powershell
python tools/run_perf.py --port COM7 --baud 115200 --delay 3.0 --mem build_perf/perf_array_small.mem --expect-return 0
```

工具沿用原有上傳格式與分塊節奏，送完後持續等待完整報告。預設等待 120 秒；
可用 `--timeout 600` 等待較長的程式。它不會自動操作板子的 reset。

若尚未安裝 UART 套件，先執行 `python -m pip install pyserial`。

終端機顯示 cycles、instructions、CPI/IPC、執行秒數、cache miss rate、條件分支
方向預測失誤率及等待 cycles。輸出位於 `build_perf/results/`：

- `.uart.txt`：原始 UART 接收內容，逾時也會保留。
- `.json`：原始 64-bit 整數、衍生比例、頻率、cache 配置、映像 SHA256、建置資訊。
- `.csv`：單次結果，方便匯入試算表。多次測試各自保存，不覆寫舊結果。

`COMPLETED` 表示正常返回。`--expect-return` 才會額外判定答案 PASS/FAIL；省略時
顯示 `not checked`。非零回傳值不自動視為失敗，例如 smoke 的正確回傳值為 17。
答案不符時工具回傳 exit code 1；通訊、逾時或格式錯誤回傳 2。

既有 `uart_send_mem.py --interactive` 也能上傳效能映像及接收原始報告，適合需要
鍵盤輸入的程式；新工具 `run_perf.py` 本身不轉送鍵盤輸入。

## 測試程式清單

| 名稱／映像（省略 `build_perf/perf_` 與 `.mem`） | 正確 main 回傳值 | 內容 |
| --- | --- | --- |
| `smoke` | `17` | 既有 `OS/main.c`，最小 main，精確 2 條退休指令。 |
| `count` | `42` | 精確 35 條；NOP、寫 x0、store、load-use、迴圈、乘除法、錯路徑 store、巢狀返回、長 EX 期間 memory/MMIO 不重送。 |
| `tail` | `43` | 精確 3 條；main 尾跳至另一函式，再直接返回啟動碼。 |
| `alu` | `0` | 固定輸入的 xorshift/ALU 運算與 reference checksum。 |
| `branch` | `0` | 固定種子的資料相依分支、巢狀函式與提早返回。 |
| `array_small` | `0` | 128 個 word，先初始化，再循序加總兩輪。 |
| `array_large` | `0` | 8192 個 word，32 KiB；與小陣列比較 cache/記憶體行為。 |
| `muldiv` | `0x2800c0de` | 既有 test28，八種 RV32M 指令。 |
| `stress` | `0x3100c0de` | test31 的 bounded 單輪返回版本，含 DDR、dirty eviction、RV32M、branch、JALR。 |

`count` 的系統 TB 會刻意延長 store、load、UART store 期間的 EX 停頓，各 80 拍，
檢查 memory 不重送、UART 字元 H 只傳一次；這個 TB 的 cycles 用於正確性驗證，
不是板上效能基準。

陣列大小要相對於報告的 cache 容量解讀。32 KiB 超過 FAST_SYNTH 的 L1 D/L2，
但放得進 production D-cache。若要在 production 配置測試較大的 working set，
可改用 `PERF_ARRAY_WORDS=65536`（256 KiB），並留意 linker 的 512 KiB 總空間。

`stress` 發現錯誤會停在原有 signature 診斷迴圈，不能當成正常完成；host 將逾時。
原本 test31、board-stress 的 signature／持續執行行為保留。

## 量測自己的程式

```powershell
make mem PERF=1 SRC=OS/main.c OUT_NAME=my_profile MEM_OUT=build_perf/my_profile.mem APP_DEFINES=
python tools/run_perf.py --port COM7 --mem build_perf/my_profile.mem --expect-return 17
```

多檔案程式仍使用 `EXTRA_SRCS`：

```powershell
make mem PERF=1 SRC=src/main.c EXTRA_SRCS="src/compute.c" OUT_NAME=my_app MEM_OUT=build_perf/my_app.mem APP_DEFINES="-Isrc"
```

`PERF=1` 自動選 `tools/perf_crt0.S`、連結 `tools/perf_report.c`，預設把 object 放在
`build_perf/<OUT_NAME>/`；不帶 `PERF=1` 時仍使用原有啟動碼。效能模式每次重編
object，避免變更 workload 巨集或編譯選項後誤用舊檔。請勿讓不同模式或不同來源
使用同一個自行指定的 `BUILD_DIR`。一般 Makefile 原有的同 basename object 限制仍適用。

初始化程式之外的資料來源必須固定。計算結果必須真的用於回傳值／checksum，
並用反組譯確認 workload 沒被最佳化刪除。若在 main 內讀取 UART、等待輸入、
初始化大陣列或自行輸出文字，這些成本都屬於 main，會一併量測。

## 精確起訖與退休定義

啟動碼先以 MMIO 設定 `__perf_main_call` 與 `__perf_main_return` 的實際位址，再 ARM。
呼叫使用固定 32-bit `jal ra, main`，避免偽指令展開／relaxation 改變標記意義。

- 開始：`__perf_main_call` 這條控制轉移指令退休，ARMED → RUNNING。
  當拍不累加 cycles／instructions。
- 結束：RUNNING 期間，一條控制轉移指令的實際目的地為
  `__perf_main_return`，並成功退休。當拍仍累加，再轉為 DONE，所有數據保持。
- 所以區間為 `(call 退休, 最外層返回退休]`。若起訖發生於第 100、135 拍，
  cycles 為 35。呼叫 main 的指令不列入指令數，最後的返回指令列入。
- main 的 prologue/epilogue、內部初始化、所有被呼叫函式均列入；一般函式返回
  不停止，尾呼叫可正確結束。main 不返回就沒有正常完成報告。
- Pipeline 可以重疊取指／執行；首條 main 指令部分取指活動可能早於 call 退休。
  這是退休邊界的時間，不是強制排空 pipeline 後的首次取指延遲。

每個有效指令實例只退休一次：包括 branch、store、JAL/JALR、實際 NOP、寫入 x0。
Bubble、被 flush 的指令不退休。乘除法無論等待幾拍只算一條；連續兩拍有效退休
各算一條。同 PC 的迴圈各次執行各計一次，不能用 PC 去重或 valid 上升沿計數。

Load 等待成功的資料回應；store 等待 D-cache/MMIO 回應。Store 在 cache 完成後
即可退休；不強制 flush 髒資料到 DDR。`mem_consumed_q` 防止 EX/MEM 因較新的
長延遲 EX 指令被保持時，重複退休／寫回較舊的指令。

## 指標的解讀

| 欄位 | 定義 |
| --- | --- |
| `cycles` | RUNNING 每個 core clock +1，結束拍包含。 |
| `instructions` | RUNNING 每次有效退休 +1，包含沒有 register write 的指令。 |
| `ic_access/ic_miss` | I-cache 原始 cacheable tag lookup／其中的 miss；不重算 refill replay。含推測取指。 |
| `dc_load/dc_load_miss` | D-cache 原始 load lookup／miss，MMIO 不經 D-cache。 |
| `dc_store/dc_store_miss` | D-cache 原始 store lookup／miss；store miss 為 no-write-allocate。 |
| `branches/branch_misses` | 退休的條件分支／其中方向預測錯誤；不把 JAL/JALR 算入分母。 |
| `frontend_wait` | ID 沒有效指令，且有 outstanding fetch 或取指請求被阻擋的拍數。 |
| `memory_wait` | MEM stall 的拍數，包含 cache hit 處理、miss、MMIO 與交易收尾。 |
| `load_use_wait` | load-use 條件成立且沒有 MEM／乘除法 stall 掩蓋的 interlock 拍數。 |
| `multiply_wait/divide_wait` | EX 因乘法／除法或餘數運算等待的拍數。 |

Cache／等待事件按同一 clock 區間計數，分支與指令按退休計數。Cache 數據可能
包含最後被取消的推測活動，以及邊界附近的先行取指，不能直接等同退休指令數。
等待原因可能重疊，不能相加當成總損失 cycles。CPI = cycles/instructions，
IPC = instructions/cycles，時間 = cycles/core_hz。分母為零的比例顯示 N/A。

## MMIO 規格

新增 `0x4001_0000..0x4001_0FFF`，由 SoC 本地解碼並繞過 D-cache。
要求 word 對齊；寫入要求完整 4-byte strobe。無效位址、唯讀寫入、非法 command、
RUNNING 期間的設定寫入會回傳錯誤。

| Offset | 讀寫 | 用途 |
| --- | --- | --- |
| `0x000` | R | ID `0x50455246`。 |
| `0x004` | R | 狀態：0=IDLE、1=ARMED、2=RUNNING、4=DONE、8=ABORTED。 |
| `0x008` | RW | 起始 call 的 PC。 |
| `0x00C` | RW | 最外層呼叫的返回位址。 |
| `0x010` | RW | 寫：1=清零並 ARM、2=清零並回 IDLE；讀：feature flags，bit0=fetch overlap。舊版讀值為 0。 |
| `0x014` | R | core_hz，來自 SoC 的 UART_CLK_HZ 參數。 |
| `0x018/01C/020` | R | I/D/L2 cache bytes。 |
| `0x024` | R | Schema version=1。 |
| `0x100 + 8*n` | R | 第 n 個 counter 的 low32；下一個 word 為 high32。 |

counter 順序與上方報告一致，共 15 個：cycles、instructions、ic_access、ic_miss、
dc_load、dc_load_miss、dc_store、dc_store_miss、branches、branch_misses、
frontend_wait、memory_wait、load_use_wait、multiply_wait、divide_wait。

DONE 狀態的 high/low 讀取一致；RUNNING 期間的兩次讀取不是原子快照，報告程式
只在 main 返回後讀取。ARMED/RUNNING 期間遇到取指／資料回應錯誤轉 ABORTED，
保留部分數據；不保證出錯或卡死的 CPU 能自行輸出 UART 報告。Reset 清除監測器。

## Testbench 與重現

```powershell
make perf-tb
```

包含 host parser/oracle 單元測試、PMU unit TB，以及 9 個程式的 deterministic 與
兩個 random-backpressure seed 全系統執行，共 27 次。全系統包含 CPU、I/D cache、
L2、MIG 模型；從實際 UART TX pin 解碼，不以 TX 輸入資料代替接收驗證。

- PMU unit TB：起訖包含關係、連續退休、巢狀返回、快照不變、非法 MMIO、執行中
  re-arm 拒絕、fault、64-bit 進位／高低讀取及 reset。
- 系統 TB：獨立 clock/retirement scoreboard；報告執行全程檢查所有 counter 不變。
- Python RV32IM oracle：從 startup 建立 register/BSS 狀態，比對量測區間每一條 PC
  及 register write；不做重複值消除。再核對 UART 的 instructions、branches 與回傳值。

快速或指定配置：

```powershell
python tools/run_perf_verification.py --cases smoke,count,tail --seeds 1
python tools/run_perf_verification.py --cases smoke,count,muldiv --seeds 1 --production --out-dir build_perf/production_verification
python tools/run_perf_verification.py --skip-build
```

驗證產物位於 `build_perf/verification/`：每次的 `.trace`、`.uart.txt`、`.log`、
`.json`、`.csv`，以及 `summary.json`。TB 為加速模擬使用 100 MHz/2 Mbaud，這不改變
板級 50 MHz/115200 baud 設定。模擬 DDR 延遲與實板 MIG 不同，cycles 不要求相等。

離線重讀任何原始 UART 報告（不需要 serial 套件）：

```powershell
python tools/run_perf.py --from-log build_perf/verification/count_seed0.uart.txt --expect-return 42
```

`tools/synth_perf_monitor.tcl` 可做 Artix-7 PMU standalone synthesis；完整板級
implementation 與實板穩定性仍須使用你的 Vivado/MIG 專案驗證。

本次實際執行結果見 [PERFORMANCE_VERIFICATION.md](PERFORMANCE_VERIFICATION.md)。

正式 workload 與修改前後比較見 [STANDARD_BENCHMARKS.md](STANDARD_BENCHMARKS.md)。
