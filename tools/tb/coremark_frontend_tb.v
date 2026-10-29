`timescale 1ns/1ps
// Baseline-only wrapper: reuse the unchanged full system and UART scoreboard.
module coremark_frontend_tb;
  parameter ITERATIONS=3;
  performance_system_tb system();
  reg [31:0] kernel_pc,loop_pc;
  integer options;
  wire finalized;
  initial begin
    if(!$value$plusargs("KERNEL_PC=%h",kernel_pc)) $fatal(1,"missing KERNEL_PC");
    if(!$value$plusargs("LOOP_PC=%h",loop_pc)) $fatal(1,"missing LOOP_PC");
    #1;
    if(system.tb.dut.FETCH_OVERLAP_EN!=0) $fatal(1,"frontend analysis requires overlap OFF");
  end
  frontend_profile_monitor #(.ITERATIONS(ITERATIONS)) observer(
    .clk(system.tb.dut.core_clk),.rst_n(system.tb.dut.core_rst_n),
    .main_running(system.tb.dut.perf_status==2),.main_done(system.tb.dut.perf_status==4),
    .pmu_cycles(system.tb.dut.u_perf.counters[0]),
    .pmu_instructions(system.tb.dut.u_perf.counters[1]),
    .pmu_frontend(system.tb.dut.u_perf.counters[10]),
    .id_valid(system.tb.dut.id_valid),.if_pending(system.tb.dut.if_pending),
    .req_blocked(system.tb.dut.req_blocked),.stall_id(system.tb.dut.stall_id),
    .mem_stall(system.tb.dut.mem_stall),.ex_stall(system.tb.dut.ex_stall_o),
    .data_stall(system.tb.dut.u_hdu.stall_for_data),
    .req_hs(system.tb.dut.fetch_req_hs),.req_pc(system.tb.dut.fetch_req_addr),
    .req_epoch(system.tb.dut.u_icache.u_icache.kill_toggle),
    .resp_valid(system.tb.dut.fetch_resp_valid),.resp_ready(system.tb.dut.fetch_resp_ready),
    .resp_pc(system.tb.dut.fetch_resp_pc),
    .redirect(system.tb.dut.fe_redirect_valid),.ex_redirect(system.tb.dut.redirect_valid),
    .id_redirect(system.tb.dut.id_pred_redirect_valid),.redirect_pc(system.tb.dut.fe_redirect_pc),
    .lookup(system.tb.dut.perf_i_lookup),
    .lookup_pc(system.tb.dut.u_icache.u_icache.s2_pc),
    .lookup_epoch(system.tb.dut.u_icache.u_icache.s2_kill_tag),
    .lookup_hit(system.tb.dut.u_icache.u_icache.hit),
    .miss_busy(system.tb.dut.u_icache.u_icache.state!=0),
    .retire_valid(system.tb.dut.retire_valid),.retire_ctrl(system.tb.dut.retire_ctrl),
    .retire_pc(system.tb.dut.retire_pc),.retire_target(system.tb.dut.retire_target),
    .kernel_pc(kernel_pc),.loop_marker_pc(loop_pc),.finalized(finalized)
  );
endmodule
