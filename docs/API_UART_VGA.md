# UART 與 VGA API 說明

本文件說明目前專案提供給 bare-metal C 程式使用的 UART 與 VGA 介面。這些介面都是透過 memory-mapped I/O，也就是 MMIO，直接讀寫固定記憶體位址來控制硬體。

這些 API 適用於本專案的 RV32IM bare-metal 程式，不是一般作業系統中的標準 C I/O API。因此目前不能把它理解成 Windows/Linux 上的 `printf()`、`scanf()` 或檔案 I/O。

## 使用方式總覽

目前有兩種使用方式：

1. 直接讀寫 MMIO 位址。
2. 使用專案已經封裝好的 C helper API。

一般建議使用第二種方式，也就是使用專案提供的 helper API。

| 功能 | 要 include 的 header | 編譯時要一起帶入的 source | 適用 top |
| --- | --- | --- | --- |
| UART 文字輸出、輸入、launcher helper | `game/games_shared_ui.h` | `game/games_shared_ui.c` | `board_top.v`、`board_top_vga.v` |
| VGA framebuffer | `game/vga_fb.h` | `game/vga_fb.c` | `board_top_vga.v` |

如果你的 C 檔案放在 `game/` 目錄內，可以直接：

```c
#include "games_shared_ui.h"
#include "vga_fb.h"
```

如果你的 C 檔案不在 `game/` 目錄內，例如放在 `OS/`，編譯時要加 include path：

```powershell
APP_DEFINES="-DGAME_USE_UART -Igame"
```

其中：

- `-DGAME_USE_UART`：讓 `games_shared_ui.c` 使用硬體 UART MMIO。
- `-Igame`：讓 compiler 找得到 `game/games_shared_ui.h` 和 `game/vga_fb.h`。

## MMIO 位址表

目前 UART 與 VGA 的軟體可見位址如下：

| 位址 | 讀寫方向 | 功能 |
| --- | --- | --- |
| `0x4000_0000` | write | UART TX data。寫入最低有效 byte 會送出一個 UART 字元。 |
| `0x4000_0004` | read | UART TX status。bit 0 = 1 代表 TX 可以接收下一個 byte。 |
| `0x4000_0008` | read | UART RX data。低 8 bit 是收到的 byte。讀取後會 pop 掉目前 byte。 |
| `0x4000_000C` | read | UART RX status。bit 0 = RX valid，bit 1 = RX overrun。讀取 status 會清除 overrun。 |
| `0x4000_0010` | read | launcher button status。bit 0 = button pressed。 |
| `0x4000_0014` | write | launcher soft reset request。寫入 bit 0 = 1 會觸發返回 launcher/reset 流程。 |
| `0x5000_0000` | read/write | VGA framebuffer 起始位址。 |
| `0x5000_7FFC` | read/write | VGA framebuffer control register。 |

UART MMIO 在 `board_top.v` 和 `board_top_vga.v` 都可以使用。VGA MMIO 需要 SoC 啟用 `USE_VGA=1`，目前對應的板級 top 是 `board_top_vga.v`。

## 直接使用 UART MMIO

如果只是要寫很小的測試程式，可以不使用 helper API，直接用 `volatile` 指標讀寫 MMIO。

一定要使用 `volatile`，避免 compiler 把硬體存取最佳化掉。

```c
#define UART_TX_DATA   (*(volatile unsigned int *)0x40000000u)
#define UART_TX_STATUS (*(volatile unsigned int *)0x40000004u)
#define UART_RX_DATA   (*(volatile unsigned int *)0x40000008u)
#define UART_RX_STATUS (*(volatile unsigned int *)0x4000000Cu)

static void uart_putc(char ch)
{
    while ((UART_TX_STATUS & 1u) == 0u) {
    }
    UART_TX_DATA = (unsigned int)(unsigned char)ch;
}

static int uart_getc_nonblocking(void)
{
    if ((UART_RX_STATUS & 1u) == 0u) {
        return -1;
    }
    return (int)(UART_RX_DATA & 0xFFu);
}

int main(void)
{
    uart_putc('H');
    uart_putc('i');
    uart_putc('\n');

    for (;;) {
        int ch = uart_getc_nonblocking();
        if (ch >= 0) {
            uart_putc((char)ch);
        }
    }
}
```

這種方式適合 UART bring-up 或非常小的測試，例如 `uart_smoke.S`。

## UART helper API

UART helper API 實作在：

```text
game/games_shared_ui.h
game/games_shared_ui.c
```

使用時要 include：

```c
#include "games_shared_ui.h"
```

編譯時要一起帶入：

```text
game/games_shared_ui.c
```

如果 C 檔案不在 `game/` 目錄內，還要加：

```powershell
APP_DEFINES="-DGAME_USE_UART -Igame"
```

### UART helper 函式與最小範例

以下範例都假設已經 include：

```c
#include "games_shared_ui.h"
```

#### `int ui_tx_ready(void)`

用途：檢查 UART TX 是否可以送下一個 byte。非 0 代表 ready。

```c
if (ui_tx_ready()) {
    ui_putc('A');
}
```

通常不需要自己呼叫它，因為 `ui_putc()` 內部已經會等待 TX ready。只有在你想做非阻塞輸出時才需要用。

#### `void ui_putc(char ch)`

用途：輸出一個字元。若輸出 `\n`，會自動先送 `\r`，形成 CRLF。

```c
ui_putc('O');
ui_putc('K');
ui_putc('\n');
```

#### `void ui_puts(const char *text)`

用途：輸出一整個 C 字串，直到遇到 `'\0'`。

```c
ui_puts("System booted\n");
```

這是目前最常用的簡易文字輸出 API，可用來取代一部分 `printf()` 的用途。

#### `void ui_put_uint(unsigned int value)`

用途：以十進位輸出 unsigned integer。

```c
unsigned int score = 12345u;

ui_puts("score=");
ui_put_uint(score);
ui_putc('\n');
```

目前只支援 unsigned 十進位輸出，不支援 `%x`、`%d`、格式化寬度等完整 `printf()` 功能。

#### `void ui_clear_screen(void)`

用途：輸出 ANSI clear-screen escape sequence，讓 UART terminal 清畫面。

```c
ui_clear_screen();
ui_puts("Main menu\n");
```

注意：這需要你的 UART terminal 支援 ANSI escape sequence。若 terminal 不支援，可能只會看到特殊字元。

#### `void ui_home_cursor(void)`

用途：輸出 ANSI home-cursor escape sequence，將 UART terminal 游標移回左上角。

```c
ui_home_cursor();
ui_puts("Frame counter: ");
ui_put_uint(frame_count);
```

適合做簡單 terminal dashboard。

#### `int ui_read_byte_blocking(void)`

用途：等待 UART 收到一個 byte 後回傳。這是阻塞式讀取。

```c
ui_puts("Press any key...\n");
int ch = ui_read_byte_blocking();
ui_puts("You pressed: ");
ui_putc((char)ch);
ui_putc('\n');
```

如果沒有輸入，CPU 會停在這個函式裡等待。

#### `int ui_read_byte_nonblocking(void)`

用途：非阻塞式讀取 UART input。如果有資料就回傳 byte，沒有資料就回傳 `-1`。

```c
int ch = ui_read_byte_nonblocking();
if (ch >= 0) {
    ui_puts("rx=");
    ui_putc((char)ch);
    ui_putc('\n');
}
```

適合遊戲主迴圈，因為它不會讓畫面更新停住。

#### `void ui_drain_input(void)`

用途：清掉目前 pending 的 UART input，避免舊按鍵影響下一個畫面或下一場遊戲。

```c
ui_puts("Starting new game...\n");
ui_drain_input();
```

#### `void ui_drain_input_limited(unsigned int max_reads)`

用途：最多清掉 `max_reads` 個 pending input byte。

```c
ui_drain_input_limited(32u);
```

如果擔心 UART input 很多，使用 limited 版本可以避免清 input 花太久。

#### `void ui_input_barrier(void)`

用途：在進入新的互動流程前，清掉一批舊 input。它是較高層級的 input drain helper。

```c
ui_puts("Press WASD to move\n");
ui_input_barrier();
```

常用在 menu 進入 game、game reset、或切換畫面前。

#### `int ui_to_lower(int ch)`

用途：將 ASCII 大寫字母轉成小寫；非大寫字母則原樣回傳。

```c
int ch = ui_read_byte_blocking();
ch = ui_to_lower(ch);

if (ch == 'w') {
    ui_puts("move up\n");
}
```

這可以讓 `W` 和 `w` 都被視為同一個控制鍵。

#### `void ui_set_input_policy(ui_input_policy_t policy)`

用途：設定 UART input 過濾策略。

```c
ui_set_input_policy(UI_INPUT_POLICY_FILTER_DOUBLE_Q);
```

例如遊戲中不希望玩家誤按一次 `q` 就離開，可以使用 double-q policy。

#### `int ui_launcher_button_pressed(void)`

用途：讀取 launcher button 是否按下。非 0 代表按下。

```c
if (ui_launcher_button_pressed()) {
    ui_puts("launcher button is pressed\n");
}
```

這個功能主要用於 `board_top_vga.v`，因為實體 launcher button input 是接在 VGA top。

#### `void ui_launcher_sync_button_state(void)`

用途：同步目前 launcher button 狀態，避免剛進入畫面時把既有按下狀態誤判成新事件。

```c
ui_launcher_sync_button_state();
```

通常在進入 game loop 前呼叫一次。

#### `void ui_launcher_ignore_button_polls(unsigned int polls)`

用途：暫時忽略 launcher button 一段 polling 次數。

```c
ui_launcher_ignore_button_polls(60u);
```

適合在剛切換場景後使用，避免切換瞬間殘留的按鍵狀態造成連續觸發。

#### `void ui_launcher_wait_button_release(void)`

用途：等待 launcher button 釋放並穩定。

```c
ui_puts("Release button to continue\n");
ui_launcher_wait_button_release();
```

適合在按下 button 觸發某動作後，等待使用者放開按鍵。

#### `int ui_launcher_menu_requested(void)`

用途：偵測 launcher menu request 的 rising edge。回傳非 0 代表偵測到新的 menu request。

```c
if (ui_launcher_menu_requested()) {
    ui_puts("return to launcher\n");
    ui_launcher_request_menu();
}
```

這比直接讀 `ui_launcher_button_pressed()` 更適合主迴圈，因為它只在按下的瞬間觸發一次。

#### `void ui_launcher_request_menu(void)`

用途：透過 MMIO `0x4000_0014` 要求 SoC 進入 launcher/reset 流程。

```c
ui_puts("request launcher menu\n");
ui_launcher_request_menu();
```

在硬體 UART 模式下，這個函式會寫入 launcher reset MMIO，然後停在無窮迴圈等待硬體 reset 流程。

### UART input policy

`ui_set_input_policy()` 可以設定以下策略：

| Policy | 說明 |
| --- | --- |
| `UI_INPUT_POLICY_NORMAL` | 正常回傳輸入。 |
| `UI_INPUT_POLICY_IGNORE_Q` | 忽略 `q` 輸入。 |
| `UI_INPUT_POLICY_FILTER_DOUBLE_Q` | 第一次按 `q` 只提示，第二次按 `q` 才真的回傳 `q`。 |

### UART helper 範例

假設新增檔案：

```text
OS/uart_echo_demo.c
```

內容：

```c
#include "games_shared_ui.h"

int main(void)
{
    ui_puts("UART echo demo\n");
    ui_puts("Type characters. Press q to stop echoing.\n");

    for (;;) {
        int ch = ui_read_byte_blocking();
        if (ch == 'q') {
            ui_puts("\nquit\n");
            break;
        }
        ui_puts("rx=");
        ui_putc((char)ch);
        ui_putc('\n');
    }

    for (;;) {
    }
}
```

編譯成 `.mem`：

```powershell
make mem SRC=OS/uart_echo_demo.c EXTRA_SRCS="game/games_shared_ui.c" OUT_NAME=uart_echo_demo MEM_OUT=TEST_FILES/mem_uart_echo_demo.mem APP_DEFINES="-DGAME_USE_UART -Igame"
```

## VGA framebuffer API

VGA framebuffer API 實作在：

```text
game/vga_fb.h
game/vga_fb.c
```

使用時要 include：

```c
#include "vga_fb.h"
```

編譯時要一起帶入：

```text
game/vga_fb.c
```

如果你的程式同時需要 UART helper 和 VGA，通常會一起帶入：

```text
game/games_shared_ui.c game/vga_fb.c
```

VGA framebuffer 需要使用 `board_top_vga.v`。如果 FPGA top 使用的是 `board_top.v`，則 VGA MMIO 區域不會啟用。

### Framebuffer 格式

| 項目 | 數值 |
| --- | --- |
| 邏輯解析度 | `160 x 120` |
| 每個 pixel 顏色 | 4-bit color index |
| 可用顏色值 | `0x0` 到 `0xF` |
| framebuffer base | `0x5000_0000` |
| buffer stride | `0x0000_4000` |
| control register | `0x5000_7FFC` |

目前 framebuffer 是 double buffering：

| Buffer | 起始位址 |
| --- | --- |
| Buffer 0 | `0x5000_0000` |
| Buffer 1 | `0x5000_0000 + 0x4000` |

Control register 的行為：

- 寫入 bit 0：要求 VGA 顯示 buffer 0 或 buffer 1。
- 讀取 bit 0：VGA 端目前看到的 display buffer。
- 讀取 bit 1：CPU 端目前要求顯示的 buffer。
- 硬體會在 frame boundary 切換顯示 buffer。

### VGA API 函式與最小範例

以下範例都假設已經 include：

```c
#include "vga_fb.h"
```

#### `void vga_fb_clear(unsigned char color)`

用途：將目前 draw buffer 全部填成同一個 4-bit 顏色。

```c
vga_fb_clear(0u);   // 清成顏色 0
vga_fb_present();   // 顯示清完的 buffer
```

常用在重畫整個畫面前。

#### `void vga_fb_put_pixel(unsigned int x, unsigned int y, unsigned char color)`

用途：在 `(x, y)` 畫一個 pixel。超出 `160x120` 範圍會被忽略。

```c
vga_fb_put_pixel(10u, 20u, 15u);
vga_fb_present();
```

`color` 只使用低 4 bit，因此有效顏色範圍是 `0x0` 到 `0xF`。

#### `void vga_fb_fill_rect4(unsigned int x, unsigned int y, unsigned int w, unsigned int h, unsigned char color)`

用途：畫一個矩形。`x` 和 `w` 必須是 4 的倍數，不符合時會直接忽略。

```c
vga_fb_fill_rect4(16u, 24u, 32u, 12u, 4u);
vga_fb_present();
```

正確範例：

```c
vga_fb_fill_rect4(20u, 10u, 40u, 8u, 2u);  // x=20, w=40 都是 4 的倍數
```

錯誤範例：

```c
vga_fb_fill_rect4(21u, 10u, 39u, 8u, 2u);  // 會被忽略
```

#### `void vga_fb_set_draw_buffer(unsigned int index)`

用途：選擇 CPU 目前要畫到 buffer 0 或 buffer 1。

```c
vga_fb_set_draw_buffer(0u);
vga_fb_clear(0u);
vga_fb_present();
```

`index` 只使用最低 bit，所以 `0` 選 buffer 0，`1` 選 buffer 1。

#### `void vga_fb_present(void)`

用途：要求 VGA 顯示目前 draw buffer。

```c
vga_fb_set_draw_buffer(0u);
vga_fb_clear(0u);
vga_fb_fill_rect4(40u, 40u, 24u, 16u, 12u);
vga_fb_present();
```

`vga_fb_present()` 只提出切換要求，實際 VGA 端會在 frame boundary 切換。

#### `int vga_fb_present_sync(void)`

用途：呼叫 present，並等待 VGA 端切換到目標 buffer。成功回傳 `1`，timeout 回傳 `0`。

```c
vga_fb_clear(0u);
vga_fb_fill_rect4(40u, 40u, 24u, 16u, 12u);

if (!vga_fb_present_sync()) {
    // timeout，可選擇用 UART 印出 debug 訊息
}
```

如果你希望畫面切換較穩定，優先使用 `vga_fb_present_sync()`。

#### `void vga_fb_swap_draw_buffer(void)`

用途：在 buffer 0 和 buffer 1 之間切換目前 draw buffer。

```c
vga_fb_swap_draw_buffer();
vga_fb_clear(0u);
vga_fb_fill_rect4(12u, 12u, 20u, 20u, 5u);
vga_fb_present_sync();
```

這常用於 animation 或 game loop，避免直接在目前顯示中的 buffer 上畫圖。

#### `unsigned int vga_fb_draw_buffer_index(void)`

用途：回傳 CPU 目前正在畫的 buffer index。

```c
unsigned int draw = vga_fb_draw_buffer_index();
ui_puts("draw buffer=");
ui_put_uint(draw);
ui_putc('\n');
```

若要使用 `ui_puts()` 和 `ui_put_uint()`，記得額外 include `games_shared_ui.h` 並連結 `game/games_shared_ui.c`。

#### `unsigned int vga_fb_display_buffer_index(void)`

用途：回傳目前 VGA 端正在顯示的 buffer index。

```c
unsigned int display = vga_fb_display_buffer_index();
ui_puts("display buffer=");
ui_put_uint(display);
ui_putc('\n');
```

這可以用來 debug double buffering 是否照預期切換。

### VGA 範例

假設新增檔案：

```text
OS/vga_rect_demo.c
```

內容：

```c
#include "vga_fb.h"
#include "games_shared_ui.h"

int main(void)
{
    unsigned int x = 0;

    ui_puts("VGA rectangle demo\n");

    vga_fb_set_draw_buffer(0u);
    vga_fb_clear(0u);
    vga_fb_fill_rect4(16u, 16u, 48u, 24u, 4u);
    vga_fb_fill_rect4(80u, 20u, 40u, 40u, 2u);
    vga_fb_present_sync();

    for (;;) {
        vga_fb_swap_draw_buffer();
        vga_fb_clear(0u);
        vga_fb_fill_rect4(x & 0x7Cu, 50u, 24u, 16u, 12u);
        vga_fb_present_sync();
        x = (x + 4u) % 136u;
        ui_short_pause(30000u);
    }
}
```

編譯：

```powershell
make mem SRC=OS/vga_rect_demo.c EXTRA_SRCS="game/games_shared_ui.c game/vga_fb.c" OUT_NAME=vga_rect_demo MEM_OUT=TEST_FILES/mem_vga_rect_demo.mem APP_DEFINES="-DGAME_USE_UART -Igame"
```

FPGA top 建議使用：

```text
board_top_vga.v
```

## UART 輸入搭配 VGA 輸出範例

以下範例使用 UART 鍵盤輸入控制 VGA 上的方塊。

```c
#include "vga_fb.h"
#include "games_shared_ui.h"

int main(void)
{
    unsigned int x = 72u;
    unsigned int y = 56u;

    ui_puts("Use WASD to move the VGA block.\n");
    ui_input_barrier();

    for (;;) {
        int ch = ui_read_byte_nonblocking();

        if (ch == 'a' && x >= 4u) {
            x -= 4u;
        } else if (ch == 'd' && x < 148u) {
            x += 4u;
        } else if (ch == 'w' && y > 0u) {
            y -= 1u;
        } else if (ch == 's' && y < 112u) {
            y += 1u;
        }

        vga_fb_swap_draw_buffer();
        vga_fb_clear(0u);
        vga_fb_fill_rect4(x, y, 12u, 8u, 14u);
        vga_fb_present_sync();
        ui_short_pause(15000u);
    }
}
```

編譯：

```powershell
make mem SRC=OS/vga_uart_block_demo.c EXTRA_SRCS="game/games_shared_ui.c game/vga_fb.c" OUT_NAME=vga_uart_block_demo MEM_OUT=TEST_FILES/mem_vga_uart_block_demo.mem APP_DEFINES="-DGAME_USE_UART -Igame"
```

## 限制與注意事項

- 這些 API 是 bare-metal API，不是標準 C library 的 `stdio`。
- `ui_puts()` 和 `ui_put_uint()` 只能取代一小部分 `printf()` 用途。
- `ui_read_byte_blocking()` 和 `ui_read_byte_nonblocking()` 是 byte-level UART input，不是完整 `scanf()`。
- 目前 VGA API 是 framebuffer primitive，還沒有共用的文字/字型 API。部分遊戲檔案內有各自的文字繪製函式，但還沒有整理成共用 library。
- `vga_fb_fill_rect4()` 的 `x` 和 `w` 必須是 4 的倍數，因為 framebuffer packing 以 4 pixels 為一組。
- `board_top.v` 適合 UART-only 程式。
- 如果程式會存取 `0x5000_0000` VGA framebuffer，FPGA top 應使用 `board_top_vga.v`。
- 實體 launcher button input 目前接在 `board_top_vga.v`；軟體也可以透過 MMIO `0x4000_0014` 發出 launcher reset request。
