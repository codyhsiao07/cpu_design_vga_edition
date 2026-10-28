# RV32IM / DDR / Cache 壓力測試

`TEST_FILES/prog_test31_system_stress.c` 是可同時用於 RTL simulation 與 FPGA
實板燒機的自我檢查程式。測試不依賴作業系統；發現錯誤時會保留 phase、index、
實際值與預期值，實板版本透過 UART 輸出結果。

## 測試內容

| Phase | 測試內容 |
| --- | --- |
| 1 | 32-bit DDR pattern，正向寫入、反向讀回。 |
| 2 | byte store/load pattern。 |
| 3 | halfword store/load pattern。 |
| 4 | cache line 尾端的 signed byte/halfword load。 |
| 5 | 4 個同 set 位址的 dirty D-cache/L2 eviction 與 writeback。 |
| 6 | RV32M 八種指令及除零、signed overflow 等邊界值。 |
| 7 | ALU/branch loop、固定 reference hash、function-pointer JALR。 |

測試使用 `0x8001_0000` 到約 `0x8007_1000` 的 DDR scratch 空間，因此不要和
其他會使用相同區域的 firmware 同時執行。

## RTL simulation

先建立 bounded simulation image：

```powershell
make test31-system-stress
```

執行 deterministic test：

```powershell
powershell -ExecutionPolicy Bypass -File tools/run_multiseed_regression.ps1 `
  -Tests "31" -SeedCount 1 -RandMem 0 -AssertEn 1 -MaxCycles 2000000
```

執行 randomized backpressure：

```powershell
powershell -ExecutionPolicy Bypass -File tools/run_multiseed_regression.ps1 `
  -Tests "31" -SeedStart 1 -SeedCount 5 -RandMem 1 -AssertEn 1 `
  -MaxCycles 2000000 -OutDir build_test31_random
```

simulation 只有在所有 phase 通過後才會寫出 `x10 = 0x3100C0DE`。

## FPGA 實板燒機

建立持續執行版本：

```powershell
make board-stress
```

產物為：

```text
TEST_FILES/mem_board_stress.mem
```

上傳並直接監看 UART：

```powershell
python uart_send_mem.py --port COM7 --baud 115200 `
  --mem TEST_FILES/mem_board_stress.mem --delay 3.0 --interactive
```

正常輸出：

```text
RV32IM DDR/cache stress starting
PASS round=00000000
PASS round=00000001
...
```

實板版本會一直執行，直到 reset 或斷電。建議至少跑 30 分鐘；若要做長時間
穩定性測試，可跑數小時並確認 round 持續增加。

錯誤輸出範例：

```text
FAIL phase=00000005 index=00000012 got=12345678 expected=C0110004
```

錯誤後程式會停止，並把 `0xDEAD31xx` 保留在 `x10`，其中低 8 bit 是 phase。

## 注意事項

- `UART_CLK_HZ` 必須和 Vivado `report_clocks` 中實際的 MIG `ui_clk` 相同。
- UART 暫時不可用時，測試程式的輸出有 timeout，不會因此停止 DDR/CPU 壓測。
- 這是功能與長時間穩定性測試，不等同 formal proof 或 Vivado timing/CDC sign-off。
