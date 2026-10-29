`timescale 1ns/1ps
// icache_top.v - Thin wrapper around i_cache with a simple fetch interface.
// - Ties off flush/invalidate for now.
// - Exposes the L2 refill interface to the outside world.

module icache_top #(
  parameter FETCH_OVERLAP_EN = 0,
  parameter ADDR_WIDTH  = 32,
  parameter L2_DATA_W   = 64,
  parameter CACHE_BYTES = 65536,
  parameter LINE_BYTES  = 64,
  parameter NUM_WAYS    = 2,
  parameter OFFSET_BITS = 6,
  parameter INDEX_BITS  = 9,
  parameter TAG_BITS    = (ADDR_WIDTH - OFFSET_BITS - INDEX_BITS),
  parameter UNC_BASE    = 32'h0000_0000,
  parameter UNC_MASK    = 32'h0000_0000
) (
  input                   clk,
  input                   rst_n,
  output                  perf_lookup_o,
  output                  perf_miss_o,

  // Fetch request/response
  input                   fetch_req_valid_i,
  input  [ADDR_WIDTH-1:0] fetch_req_addr_i,
  input                   fetch_req_kill_i,
  output                  fetch_req_ready_o,

  output                  fetch_resp_valid_o,
  input                   fetch_resp_ready_i,
  output [31:0]           fetch_resp_inst_o,
  output [ADDR_WIDTH-1:0] fetch_resp_pc_o,
  output                  fetch_resp_err_o,

  // L2 interface
  output                  l2_req_valid,
  input                   l2_req_ready,
  output [ADDR_WIDTH-1:0] l2_req_addr,
  output [1:0]            l2_req_cmd,
  output [2:0]            l2_req_size,
  output [7:0]            l2_req_len,

  input                   l2_rsp_valid,
  output                  l2_rsp_ready,
  input  [L2_DATA_W-1:0]  l2_rsp_data,
  input                   l2_rsp_last,
  input                   l2_rsp_err,
  output                  probe_valid,
  input                   probe_ready,
  output [31:0]           probe_addr,
  input                   probe_rsp_valid,
  output                  probe_rsp_ready,
  input                   probe_rsp_hit,
  input [511:0]           probe_rsp_line
);

  wire ic_flush_ack;
  wire ic_inv_ack;

  wire base_perf_lookup_o;
  wire base_perf_miss_o;
  wire base_fetch_req_ready_o;
  wire base_fetch_resp_valid_o;
  wire [31:0] base_fetch_resp_inst_o;
  wire [ADDR_WIDTH-1:0] base_fetch_resp_pc_o;
  wire base_fetch_resp_err_o;
  wire base_l2_req_valid;
  wire [ADDR_WIDTH-1:0] base_l2_req_addr;
  wire [1:0] base_l2_req_cmd;
  wire [2:0] base_l2_req_size;
  wire [7:0] base_l2_req_len;
  wire base_l2_rsp_ready;

  i_cache #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .CACHE_BYTES(CACHE_BYTES),
    .LINE_BYTES (LINE_BYTES),
    .NUM_WAYS   (NUM_WAYS),
    .OFFSET_BITS(OFFSET_BITS),
    .INDEX_BITS (INDEX_BITS),
    .TAG_BITS   (TAG_BITS),
    .L2_DATA_W  (L2_DATA_W),
    .UNC_BASE   (UNC_BASE),
    .UNC_MASK   (UNC_MASK)
  ) u_icache (
    .clk           ((FETCH_OVERLAP_EN == 0) ? clk : 1'b0),
    .rst_n         (rst_n && (FETCH_OVERLAP_EN == 0)),
    .perf_lookup_o (base_perf_lookup_o),
    .perf_miss_o   (base_perf_miss_o),

    .if_req_valid  ((FETCH_OVERLAP_EN == 0) && fetch_req_valid_i),
    .if_req_addr   (fetch_req_addr_i),
    .if_req_ready  (base_fetch_req_ready_o),
    .if_req_kill   (fetch_req_kill_i),

    .if_resp_valid (base_fetch_resp_valid_o),
    .if_resp_ready (fetch_resp_ready_i),
    .if_resp_inst  (base_fetch_resp_inst_o),
    .if_resp_pc    (base_fetch_resp_pc_o),
    .if_resp_err   (base_fetch_resp_err_o),

    .ic_flush_req  (1'b0),
    .ic_flush_ack  (ic_flush_ack),
    .ic_inv_valid  (1'b0),
    .ic_inv_all    (1'b0),
    .ic_inv_index  ({INDEX_BITS{1'b0}}),
    .ic_inv_way    (1'b0),
    .ic_inv_ack    (ic_inv_ack),

    .l2_req_valid  (base_l2_req_valid),
    .l2_req_ready  (l2_req_ready),
    .l2_req_addr   (base_l2_req_addr),
    .l2_req_cmd    (base_l2_req_cmd),
    .l2_req_size   (base_l2_req_size),
    .l2_req_len    (base_l2_req_len),

    .l2_rsp_valid  (l2_rsp_valid),
    .l2_rsp_ready  (base_l2_rsp_ready),
    .l2_rsp_data   (l2_rsp_data),
    .l2_rsp_last   (l2_rsp_last),
    .l2_rsp_err    (l2_rsp_err)
  );

  generate if (FETCH_OVERLAP_EN != 0) begin : GEN_OVERLAP
    i_cache_overlap #(.ADDR_WIDTH(ADDR_WIDTH), .CACHE_BYTES(CACHE_BYTES),
      .INDEX_BITS(INDEX_BITS), .TAG_BITS(TAG_BITS), .UNC_BASE(UNC_BASE), .UNC_MASK(UNC_MASK)) u_slots (
      .clk(clk), .rst_n(rst_n), .perf_lookup_o(perf_lookup_o), .perf_miss_o(perf_miss_o),
      .if_req_valid(fetch_req_valid_i), .if_req_addr(fetch_req_addr_i),
      .if_req_ready(fetch_req_ready_o), .if_req_kill(fetch_req_kill_i),
      .if_resp_valid(fetch_resp_valid_o), .if_resp_ready(fetch_resp_ready_i),
      .if_resp_inst(fetch_resp_inst_o), .if_resp_pc(fetch_resp_pc_o), .if_resp_err(fetch_resp_err_o),
      .l2_req_valid(l2_req_valid), .l2_req_ready(l2_req_ready), .l2_req_addr(l2_req_addr),
      .l2_req_cmd(l2_req_cmd), .l2_req_size(l2_req_size), .l2_req_len(l2_req_len),
      .l2_rsp_valid(l2_rsp_valid), .l2_rsp_ready(l2_rsp_ready), .l2_rsp_data(l2_rsp_data),
      .l2_rsp_last(l2_rsp_last), .l2_rsp_err(l2_rsp_err),
      .probe_valid(probe_valid), .probe_ready(probe_ready), .probe_addr(probe_addr),
      .probe_rsp_valid(probe_rsp_valid), .probe_rsp_ready(probe_rsp_ready),
      .probe_rsp_hit(probe_rsp_hit), .probe_rsp_line(probe_rsp_line));
  end else begin : GEN_BASELINE
    assign perf_lookup_o = base_perf_lookup_o;
    assign perf_miss_o = base_perf_miss_o;
    assign fetch_req_ready_o = base_fetch_req_ready_o;
    assign fetch_resp_valid_o = base_fetch_resp_valid_o;
    assign fetch_resp_inst_o = base_fetch_resp_inst_o;
    assign fetch_resp_pc_o = base_fetch_resp_pc_o;
    assign fetch_resp_err_o = base_fetch_resp_err_o;
    assign l2_req_valid = base_l2_req_valid;
    assign l2_req_addr = base_l2_req_addr;
    assign l2_req_cmd = base_l2_req_cmd;
    assign l2_req_size = base_l2_req_size;
    assign l2_req_len = base_l2_req_len;
    assign l2_rsp_ready = base_l2_rsp_ready;
    assign probe_valid = 1'b0;
    assign probe_addr = 32'd0;
    assign probe_rsp_ready = 1'b0;
  end endgenerate

endmodule
