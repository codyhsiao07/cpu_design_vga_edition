# Build a single C bare-metal RV32IM program into ELF/BIN/MEM for this repo.
# Usage:
#   make
#   make SRC=OS/my_os.c OUT_NAME=my_os MEM_OUT=TEST_FILES/mem_my_os.mem
#   make disasm
#   make run-sim
#   make clean

LOCAL_TOOLCHAIN_BIN ?= toolchain/xpack-riscv-none-elf-gcc/bin
DEFAULT_TOOLCHAIN_BIN ?= C:/riscv/xpack-riscv-none-elf-gcc/bin
ifneq ($(wildcard $(LOCAL_TOOLCHAIN_BIN)/riscv64-unknown-elf-gcc*),)
TOOLCHAIN_BIN ?= $(LOCAL_TOOLCHAIN_BIN)
else
TOOLCHAIN_BIN ?= $(DEFAULT_TOOLCHAIN_BIN)
endif

CC_PREFIX       ?= $(TOOLCHAIN_BIN)/riscv64-unknown-elf-
BINUTILS_PREFIX ?= $(TOOLCHAIN_BIN)/riscv-none-elf-
CC       := $(CC_PREFIX)gcc
OBJCOPY  := $(BINUTILS_PREFIX)objcopy
OBJDUMP  := $(BINUTILS_PREFIX)objdump
PYTHON   ?= python

GAME_DIR ?= game
SRC      ?= $(GAME_DIR)/game.c
EXTRA_SRCS ?=
CRT0     ?= tools/crt0.S
LDSCRIPT ?= tools/link_ddr.ld

BUILD_DIR ?= build_os
OUT_NAME  ?= game
MEM_OUT   ?= TEST_FILES/mem_game.mem

SIM_EXE       ?= icache_pipeline_tb.out
SIM_MAXCYCLES ?= 500000
SIM_EXPECT_RD ?= 8
SIM_EXPECT_VAL ?= 00000011
GAMES_MENU_EXTRA_SRCS := $(GAME_DIR)/games_shared_ui.c $(GAME_DIR)/game_tictactoe_menu.c $(GAME_DIR)/game_tictactoe_core.c $(GAME_DIR)/game_tetris_menu.c $(GAME_DIR)/game_tetris_core.c
TETRIS_VGA_EXTRA_SRCS := $(GAME_DIR)/games_shared_ui.c $(GAME_DIR)/vga_fb.c

APP_DEFINES ?= -DGAME_USE_UART
ARCH    ?= rv32im
CFLAGS  ?= -march=$(ARCH) -mabi=ilp32 -ffreestanding -nostdlib -O2 -Wall -Wextra $(APP_DEFINES)
LDFLAGS ?= -march=$(ARCH) -mabi=ilp32 -nostdlib -Wl,-T,$(LDSCRIPT) -Wl,-Map,$(BUILD_DIR)/$(OUT_NAME).map
LDLIBS ?=

# Opt-in main-call profiling; separate objects avoid reusing a normal crt0.
PERF ?= 0
ifeq ($(PERF),1)
CRT0 := tools/perf_crt0.S
BUILD_DIR = build_perf/$(OUT_NAME)
override EXTRA_SRCS += tools/perf_report.c
override CFLAGS += -mno-relax -msmall-data-limit=0
endif

SRC_BASE := $(notdir $(basename $(SRC)))
CRT0_OBJ := $(BUILD_DIR)/crt0.o
SRC_OBJ  := $(BUILD_DIR)/$(SRC_BASE).o
EXTRA_SRCS_STRIPPED := $(strip $(EXTRA_SRCS))
EXTRA_OBJS := $(foreach src,$(EXTRA_SRCS_STRIPPED),$(BUILD_DIR)/$(notdir $(basename $(src))).o)
ifeq ($(PERF),1)
# Profile options/workload sizes are often varied between runs. Always rebuild
# these small firmware objects so changed flags cannot silently reuse old code.
.PHONY: perf-rebuild
perf-rebuild:
$(CRT0_OBJ) $(SRC_OBJ) $(EXTRA_OBJS): perf-rebuild
endif
ELF      := $(BUILD_DIR)/$(OUT_NAME).elf
BIN      := $(BUILD_DIR)/$(OUT_NAME).bin
DISASM   := $(BUILD_DIR)/$(OUT_NAME).dis

.PHONY: help all check-tools print-config elf bin mem games-menu vga-games-menu tetris-vga gomoku-vga breakout-vga snake-vga mines-vga bomber-vga sokoban-vga pacman-vga chess-vga test29-independent-stress test30-control-side-effects test31-system-stress board-stress disasm run-sim uart-mmio-tb vga-subsystem-tb clean

.DEFAULT_GOAL := all

help:
	@echo "Targets:"
	@echo "  make / make all   : build MEM image ($(MEM_OUT))"
	@echo "  make elf          : build ELF ($(ELF))"
	@echo "  make bin          : build BIN ($(BIN))"
	@echo "  make mem          : build MEM ($(MEM_OUT))"
	@echo "  make games-menu   : build TEST_FILES/mem_games_menu.mem"
	@echo "  make vga-games-menu : build slot-based TEST_FILES/mem_vga_games_menu.mem"
	@echo "  make tetris-vga   : build TEST_FILES/mem_tetris_vga.mem"
	@echo "  make gomoku-vga   : build TEST_FILES/mem_gomoku_vga.mem"
	@echo "  make breakout-vga : build TEST_FILES/mem_breakout_vga.mem"
	@echo "  make snake-vga    : build TEST_FILES/mem_snake_vga.mem"
	@echo "  make mines-vga    : build TEST_FILES/mem_mines_vga.mem"
	@echo "  make bomber-vga   : build TEST_FILES/mem_bomber_vga.mem"
	@echo "  make sokoban-vga  : build TEST_FILES/mem_sokoban_vga.mem"
	@echo "  make pacman-vga   : build TEST_FILES/mem_pacman_vga.mem"
	@echo "  make chess-vga    : build TEST_FILES/mem_chess_vga.mem"
	@echo "  make test29-independent-stress : build TEST_FILES/mem_test29_independent_system_stress.mem"
	@echo "  make test30-control-side-effects : build TEST_FILES/mem_test30_control_side_effects.mem"
	@echo "  make test31-system-stress : build bounded simulation stress image"
	@echo "  make board-stress  : build continuous UART-reporting board stress image"
	@echo "  make perf-suite    : build nine main-profiling firmware images"
	@echo "  make perf-tb       : verify PMU, RV32IM retirement traces, and UART reports"
	@echo "  make coremark      : build official CoreMark auto-calibrated board images"
	@echo "  make coremark-tb   : short CRC/timing A/B simulation (not an official score)"
	@echo "  make disasm       : generate disassembly ($(DISASM))"
	@echo "  make run-sim      : run main TB with +MEMFILE=$(MEM_OUT)"
	@echo "  make uart-mmio-tb : run dedicated UART MMIO regression TB"
	@echo "  make vga-subsystem-tb : run VGA framebuffer/MMIO regression TB"
	@echo "  make clean        : remove build outputs"
	@echo ""
	@echo "Common overrides:"
	@echo "  GAME_DIR=game"
	@echo "  SRC=$(GAME_DIR)/game.c"
	@echo "  EXTRA_SRCS="
	@echo "  OUT_NAME=game"
	@echo "  MEM_OUT=TEST_FILES/mem_game.mem"
	@echo "  APP_DEFINES=-DGAME_USE_UART"
	@echo "  PERF=1             : profile all of main and report after return"
	@echo "  LOCAL_TOOLCHAIN_BIN=toolchain/xpack-riscv-none-elf-gcc/bin"
	@echo "  TOOLCHAIN_BIN=$(TOOLCHAIN_BIN)"
	@echo "  CC_PREFIX=$(CC_PREFIX)"
	@echo "  BINUTILS_PREFIX=$(BINUTILS_PREFIX)"
	@echo "  PYTHON=python"

all: mem

check-tools:
	@$(CC) --version
	@$(OBJCOPY) --version
	@$(OBJDUMP) --version
	@$(PYTHON) --version

print-config:
	@echo "SRC=$(SRC)"
	@echo "EXTRA_SRCS=$(EXTRA_SRCS)"
	@echo "CRT0=$(CRT0)"
	@echo "PERF=$(PERF)"
	@echo "LDSCRIPT=$(LDSCRIPT)"
	@echo "BUILD_DIR=$(BUILD_DIR)"
	@echo "OUT_NAME=$(OUT_NAME)"
	@echo "MEM_OUT=$(MEM_OUT)"
	@echo "APP_DEFINES=$(APP_DEFINES)"
	@echo "ARCH=$(ARCH)"
	@echo "LOCAL_TOOLCHAIN_BIN=$(LOCAL_TOOLCHAIN_BIN)"
	@echo "TOOLCHAIN_BIN=$(TOOLCHAIN_BIN)"
	@echo "CC_PREFIX=$(CC_PREFIX)"
	@echo "BINUTILS_PREFIX=$(BINUTILS_PREFIX)"
	@echo "SIM_EXE=$(SIM_EXE)"
	@echo "SIM_EXPECT_RD=$(SIM_EXPECT_RD)"
	@echo "SIM_EXPECT_VAL=$(SIM_EXPECT_VAL)"

$(BUILD_DIR):
	$(PYTHON) -c "import os; os.makedirs(r'$(BUILD_DIR)', exist_ok=True)"

$(CRT0_OBJ): $(CRT0) | $(BUILD_DIR)
	$(PYTHON) -c "import os; os.makedirs(r'$(BUILD_DIR)', exist_ok=True)"
	$(CC) $(CFLAGS) -c $< -o $@

$(SRC_OBJ): $(SRC) | $(BUILD_DIR)
	$(PYTHON) -c "import os; os.makedirs(r'$(BUILD_DIR)', exist_ok=True)"
	$(CC) $(CFLAGS) -c $< -o $@

define EXTRA_COMPILE_RULE
$(BUILD_DIR)/$(notdir $(basename $(1))).o: $(1) | $(BUILD_DIR)
	$(PYTHON) -c "import os; os.makedirs(r'$(BUILD_DIR)', exist_ok=True)"
	$(CC) $(CFLAGS) -c $$< -o $$@
endef

$(foreach src,$(EXTRA_SRCS_STRIPPED),$(eval $(call EXTRA_COMPILE_RULE,$(src))))

$(ELF): check-tools $(CRT0_OBJ) $(SRC_OBJ) $(EXTRA_OBJS) $(LDSCRIPT)
	$(PYTHON) -c "import os; os.makedirs(r'$(BUILD_DIR)', exist_ok=True)"
	$(CC) $(LDFLAGS) -o $@ $(CRT0_OBJ) $(SRC_OBJ) $(EXTRA_OBJS) $(LDLIBS)

elf: $(ELF)
	@echo "Built: $(ELF)"

$(BIN): $(ELF)
	$(OBJCOPY) -O binary $< $@

bin: $(BIN)
	@echo "Built: $(BIN)"

$(MEM_OUT): $(BIN)
	$(PYTHON) tools/bin_to_mem.py $< $@

mem: $(MEM_OUT)
	@echo "Built: $(MEM_OUT)"
ifeq ($(PERF),1)
	$(PYTHON) tools/write_perf_manifest.py --mem "$(MEM_OUT)" --source "$(SRC)" --flags "$(CFLAGS)" --compiler "$(CC)" --extra "$(EXTRA_SRCS)"
endif

games-menu:
	$(MAKE) GAME_DIR=$(GAME_DIR) SRC=$(GAME_DIR)/games_menu.c EXTRA_SRCS="$(GAMES_MENU_EXTRA_SRCS)" OUT_NAME=games_menu MEM_OUT=TEST_FILES/mem_games_menu.mem mem

vga-games-menu:
	$(PYTHON) tools/build_vga_slot_suite.py --out-mem TEST_FILES/mem_vga_games_menu.mem --out-bin build_os/vga_slot_suite/vga_games_menu_slots.bin --gcc $(CC) --objcopy $(OBJCOPY) --python $(PYTHON)

tetris-vga:
	$(MAKE) GAME_DIR=$(GAME_DIR) SRC=$(GAME_DIR)/Tetris_vga.c EXTRA_SRCS="$(TETRIS_VGA_EXTRA_SRCS)" OUT_NAME=tetris_vga MEM_OUT=TEST_FILES/mem_tetris_vga.mem mem

gomoku-vga:
	$(MAKE) GAME_DIR=$(GAME_DIR) SRC=$(GAME_DIR)/Gomoku_vga.c EXTRA_SRCS="$(TETRIS_VGA_EXTRA_SRCS)" OUT_NAME=gomoku_vga MEM_OUT=TEST_FILES/mem_gomoku_vga.mem mem

breakout-vga:
	$(MAKE) GAME_DIR=$(GAME_DIR) SRC=$(GAME_DIR)/Breakout_vga.c EXTRA_SRCS="$(TETRIS_VGA_EXTRA_SRCS)" OUT_NAME=breakout_vga MEM_OUT=TEST_FILES/mem_breakout_vga.mem mem

snake-vga:
	$(MAKE) GAME_DIR=$(GAME_DIR) SRC=$(GAME_DIR)/Snake_vga.c EXTRA_SRCS="$(TETRIS_VGA_EXTRA_SRCS)" OUT_NAME=snake_vga MEM_OUT=TEST_FILES/mem_snake_vga.mem mem

mines-vga:
	$(MAKE) GAME_DIR=$(GAME_DIR) SRC=$(GAME_DIR)/Mines_vga.c EXTRA_SRCS="$(TETRIS_VGA_EXTRA_SRCS)" OUT_NAME=mines_vga MEM_OUT=TEST_FILES/mem_mines_vga.mem mem

bomber-vga:
	$(MAKE) GAME_DIR=$(GAME_DIR) SRC=$(GAME_DIR)/Bomber_vga.c EXTRA_SRCS="$(TETRIS_VGA_EXTRA_SRCS)" OUT_NAME=bomber_vga MEM_OUT=TEST_FILES/mem_bomber_vga.mem mem

sokoban-vga:
	$(MAKE) GAME_DIR=$(GAME_DIR) SRC=$(GAME_DIR)/Sokoban_vga.c EXTRA_SRCS="$(TETRIS_VGA_EXTRA_SRCS)" OUT_NAME=sokoban_vga MEM_OUT=TEST_FILES/mem_sokoban_vga.mem mem

pacman-vga:
	$(MAKE) GAME_DIR=$(GAME_DIR) SRC=$(GAME_DIR)/Pacman_vga.c EXTRA_SRCS="$(TETRIS_VGA_EXTRA_SRCS)" OUT_NAME=pacman_vga MEM_OUT=TEST_FILES/mem_pacman_vga.mem mem

chess-vga:
	$(MAKE) GAME_DIR=$(GAME_DIR) SRC=$(GAME_DIR)/Chess_vga.c EXTRA_SRCS="$(TETRIS_VGA_EXTRA_SRCS)" OUT_NAME=chess_vga MEM_OUT=TEST_FILES/mem_chess_vga.mem mem

test29-independent-stress:
	$(MAKE) SRC=TEST_FILES/prog_test29_independent_system_stress.c OUT_NAME=test29_independent_system_stress MEM_OUT=TEST_FILES/mem_test29_independent_system_stress.mem APP_DEFINES= mem

test30-control-side-effects:
	$(MAKE) SRC=TEST_FILES/prog_test30_control_side_effects.S OUT_NAME=test30_control_side_effects MEM_OUT=TEST_FILES/mem_test30_control_side_effects.mem APP_DEFINES= mem

test31-system-stress:
	$(MAKE) BUILD_DIR=build_os/test31_sim SRC=TEST_FILES/prog_test31_system_stress.c OUT_NAME=test31_system_stress MEM_OUT=TEST_FILES/mem_test31_system_stress.mem APP_DEFINES=-DSTRESS_SIM mem

board-stress:
	$(MAKE) BUILD_DIR=build_os/board_stress SRC=TEST_FILES/prog_test31_system_stress.c OUT_NAME=board_stress MEM_OUT=TEST_FILES/mem_board_stress.mem APP_DEFINES= mem

$(DISASM): $(ELF)
	$(OBJDUMP) -D $< > $@

disasm: $(DISASM)
	@echo "Built: $(DISASM)"

run-sim: $(MEM_OUT)
	vvp $(SIM_EXE) +TEST=0 +MEMFILE=$(MEM_OUT) +ASSERT_EN=1 +MAXCYCLES=$(SIM_MAXCYCLES) +EXPECT_RD=$(SIM_EXPECT_RD) +EXPECT_VAL=$(SIM_EXPECT_VAL)

uart-mmio-tb: | $(BUILD_DIR)
	iverilog -g2005-sv -DFAST_SIM -i -o $(BUILD_DIR)/uart_mmio_tb.out -s uart_mmio_tb *.v
	vvp $(BUILD_DIR)/uart_mmio_tb.out

vga-subsystem-tb: | $(BUILD_DIR)
	iverilog -g2005-sv -o $(BUILD_DIR)/vga_subsystem_tb.out -s vga_subsystem_tb vga_subsystem_tb.v vga_subsystem.v clkdiv.v vga_640x480.v vga_initials.v
	vvp $(BUILD_DIR)/vga_subsystem_tb.out

.PHONY: perf-suite perf-tb
perf-suite:
	$(PYTHON) tools/run_perf_verification.py --build-only

perf-tb:
	$(PYTHON) -m unittest discover -s tools -p perf_tools_test.py -v
	$(PYTHON) -c "from pathlib import Path; Path('build_perf').mkdir(exist_ok=True)"
	iverilog -g2005-sv -s icache_redirect_race_tb -o build_perf/icache_redirect_race.out icache_redirect_race_tb.v icache.v
	vvp build_perf/icache_redirect_race.out
	$(PYTHON) tools/run_perf_verification.py

.PHONY: coremark coremark-short coremark-tb
coremark:
	$(PYTHON) tools/build_coremark.py
coremark-short:
	$(PYTHON) tools/build_coremark.py --iterations 1
coremark-tb:
	$(PYTHON) -m unittest discover -s tools -p perf_tools_test.py -v
	$(PYTHON) tools/run_coremark_verification.py

clean:
	$(PYTHON) -c "import shutil; shutil.rmtree(r'$(BUILD_DIR)', ignore_errors=True)"
	$(PYTHON) -c "import os; p=r'$(MEM_OUT)'; os.remove(p) if os.path.exists(p) else None"
	@echo "Cleaned build outputs."
