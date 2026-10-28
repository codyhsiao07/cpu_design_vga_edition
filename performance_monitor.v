`timescale 1ns/1ps
// Main-call profiler. The interval is (call retirement, outer return retirement].
// Cache/stall events are clock-window activity, including speculative fetches.
module performance_monitor #(
  parameter integer CORE_HZ = 50_000_000,
  parameter integer IC_BYTES = 8192,
  parameter integer DC_BYTES = 8192,
  parameter integer L2_BYTES = 16384,
  parameter [31:0] FEATURE_FLAGS = 0
)(
  input clk, input rst_n,
  input req_valid, input req_we,
  input [11:0] req_addr, input [31:0] req_wdata, input [3:0] req_wstrb,
  output ready, output rsp_valid, output reg [31:0] rdata, output err,
  input retire_valid, input [31:0] retire_pc,
  input retire_ctrl, input [31:0] retire_target,
  input retire_branch, input retire_branch_miss,
  // bit 0..12: I lookup/miss, D load/miss, D store/miss,
  // frontend/memory/load-use/multiply/divide wait.
  input [10:0] events,
  input fault,
  output reg [3:0] status
);
  localparam IDLE=4'h0, ARMED=4'h1, RUNNING=4'h2, DONE=4'h4, ABORTED=4'h8;
  reg [31:0] start_pc, return_pc;
  // 0 cycles, 1 instructions, 2..7 cache, 8..9 branches, 10..14 waits.
  reg [63:0] counters [0:14];
  integer i;
  integer index;
  reg addr_ok;
  wire aligned = (req_addr[1:0] == 0);
  wire writable = req_addr == 12'h008 || req_addr == 12'h00c || req_addr == 12'h010;
  wire command_ok = req_addr != 12'h010 || req_wdata == 1 || req_wdata == 2;
  assign ready = req_valid;
  assign rsp_valid = req_valid;
  assign err = req_valid && (!aligned || !addr_ok ||
      (req_we && (!writable || req_wstrb != 4'hf || status == RUNNING || !command_ok)));
  wire write_fire = req_valid && req_we && !err;
  wire start_event = status == ARMED && retire_valid && retire_ctrl && retire_pc == start_pc;
  wire stop_event = status == RUNNING && retire_valid && retire_ctrl && retire_target == return_pc;

  always @* begin
    rdata = 0;
    addr_ok = 1;
    index = 0;
    case (req_addr)
      12'h000: rdata = 32'h50455246; // "PERF"
      12'h004: rdata = {28'd0, status};
      12'h008: rdata = start_pc;
      12'h00c: rdata = return_pc;
      12'h010: rdata = FEATURE_FLAGS; // read capabilities; writes remain ARM/CLEAR
      12'h014: rdata = CORE_HZ;
      12'h018: rdata = IC_BYTES;
      12'h01c: rdata = DC_BYTES;
      12'h020: rdata = L2_BYTES;
      12'h024: rdata = 1; // register/event schema
      default: begin
        if (req_addr >= 12'h100 && req_addr < 12'h178 && aligned) begin
          index = (req_addr - 12'h100) >> 3;
          rdata = req_addr[2] ? counters[index][63:32] : counters[index][31:0];
        end else addr_ok = 0;
      end
    endcase
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      status <= IDLE;
      start_pc <= 0;
      return_pc <= 0;
      for (i=0; i<15; i=i+1) counters[i] <= 0;
    end else begin
      if (start_event) status <= RUNNING;
      if (status == RUNNING) begin
        counters[0] <= counters[0] + 64'd1;
        if (retire_valid) counters[1] <= counters[1] + 64'd1;
        for (i=0; i<6; i=i+1)
          if (events[i]) counters[i+2] <= counters[i+2] + 64'd1;
        if (retire_valid && retire_branch) begin
          counters[8] <= counters[8] + 64'd1;
          if (retire_branch_miss) counters[9] <= counters[9] + 64'd1;
        end
        for (i=6; i<11; i=i+1)
          if (events[i]) counters[i+4] <= counters[i+4] + 64'd1;
        if (stop_event) status <= DONE;
      end
      // Fault has priority over completion; partial counts are not a successful run.
      if (fault && (status == ARMED || status == RUNNING)) status <= ABORTED;
      if (write_fire) begin
        case (req_addr)
          12'h008: start_pc <= req_wdata;
          12'h00c: return_pc <= req_wdata;
          12'h010: begin
            status <= req_wdata == 1 ? ARMED : IDLE;
            for (i=0; i<15; i=i+1) counters[i] <= 0;
          end
        endcase
      end
    end
  end
endmodule
