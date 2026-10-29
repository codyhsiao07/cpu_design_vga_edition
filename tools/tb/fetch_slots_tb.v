`timescale 1ns/1ps
// Independent FIFO oracle + real L2/arbiter + a latency-controlled DDR model.
module fetch_slots_tb;
  reg clk=0; always #5 clk=~clk;
  reg rst_n=0, req=0, kill=0, ready=1;
  reg [31:0] addr=0;
  wire req_ready, rsp, err;
  wire [31:0] pc, inst;
  wire iv, ir, rv, rr, last, re;
  wire [31:0] ia;
  wire [1:0] cmd;
  wire [2:0] size;
  wire [7:0] len;
  wire [63:0] rd;
  wire pv, pr, prv, prr, ph;
  wire [31:0] pa;
  wire [511:0] pl;
  reg dv=0; wire dr, drv, dl;
  reg [31:0] da=0;
  wire [26:0] app_addr;
  wire [2:0] app_cmd;
  wire app_en;
  reg [127:0] app_rd_data=0;
  reg app_rd_valid=0;
  reg app_rdy=1, gate_a=0;
  reg pending=0;
  reg [26:0] pending_addr;
  integer delay_count=0, ticks=0, seed=1, unused;
  integer accepted=0, delivered=0, cancelled=0, reads=0, simultaneous=0, max_count=0;
  integer exp_head=0, exp_tail=0;
  reg hit_stream=0;
  integer stream_received=0, stream_last=0;
  reg [31:0] expected[0:8191];
  reg expected_err[0:8191];
  reg expect_fault=0;
  reg held=0; reg [64:0] held_payload;
  reg lower_held=0; reg [44:0] lower_payload;
  function [31:0] pattern;
    input [31:0] a;
    begin pattern=32'h13570000 ^ (a & 32'h07ffffff); end
  endfunction
  i_cache_overlap #(.CACHE_BYTES(256),.INDEX_BITS(1),.TAG_BITS(25)) dut (
    .clk(clk),.rst_n(rst_n),.if_req_valid(req),.if_req_addr(addr),.if_req_ready(req_ready),.if_req_kill(kill),
    .if_resp_valid(rsp),.if_resp_ready(ready),.if_resp_inst(inst),.if_resp_pc(pc),.if_resp_err(err),
    .l2_req_valid(iv),.l2_req_ready(ir),.l2_req_addr(ia),.l2_req_cmd(cmd),.l2_req_size(size),.l2_req_len(len),
    .l2_rsp_valid(rv),.l2_rsp_ready(rr),.l2_rsp_data(rd),.l2_rsp_last(last),.l2_rsp_err(re),
    .probe_valid(pv),.probe_ready(pr),.probe_addr(pa),.probe_rsp_valid(prv),.probe_rsp_ready(prr),
    .probe_rsp_hit(ph),.probe_rsp_line(pl));
  l2_cache_top #(.FETCH_OVERLAP_EN(1)) l2 (
    .clk(clk),.rst(!rst_n),.init_calib_complete(1'b1),
    .i_req_valid(iv),.i_req_ready(ir),.i_req_cmd(cmd),.i_req_addr(ia),.i_req_size(size),.i_req_len(len),
    .i_req_wdata(64'd0),.i_req_wstrb(8'd0),.i_req_uncached(1'b0),
    .i_rsp_valid(rv),.i_rsp_ready(rr),.i_rsp_rdata(rd),.i_rsp_last(last),.i_rsp_err(re),
    .d_req_valid(dv),.d_req_ready(dr),.d_req_cmd(2'd0),.d_req_addr(da),.d_req_size(3'd3),.d_req_len(8'd7),
    .d_req_wdata(64'd0),.d_req_wstrb(8'd0),.d_req_uncached(1'b0),
    .d_rsp_valid(drv),.d_rsp_ready(1'b1),.d_rsp_last(dl),
    .app_addr(app_addr),.app_cmd(app_cmd),.app_en(app_en),.app_rd_data(app_rd_data),
    .app_rd_data_end(1'b1),.app_rd_data_valid(app_rd_valid),.app_rdy(app_rdy),.app_wdf_rdy(1'b1),
    .probe_valid(pv),.probe_ready(pr),.probe_addr(pa),.probe_rsp_valid(prv),.probe_rsp_ready(prr),
    .probe_rsp_hit(ph),.probe_rsp_line(pl));

  always @(posedge clk) if(rst_n) begin
    ticks=ticks+1;
    if(ticks>30000) $fatal(1,"timeout");
    if(dut.count>3) $fatal(1,"queue overflow");
    if(dut.count>max_count) max_count=dut.count;
    if(lower_held && (!iv || {ia,cmd,size,len}!==lower_payload)) $fatal(1,"lower request changed while stalled/redirected");
    lower_held=iv && !ir; lower_payload={ia,cmd,size,len};
    if(held && !kill && (!rsp || {err,pc,inst}!==held_payload)) $fatal(1,"response changed under backpressure");
    held=rsp && !ready && !kill; held_payload={err,pc,inst};
    if(kill) begin cancelled=cancelled+exp_tail-exp_head; exp_head=exp_tail; end
    else begin
      if(rsp && ready) begin
        if(exp_head==exp_tail || pc!==expected[exp_head] ||
           inst!==(expected_err[exp_head]?32'h13:pattern(pc)) || err!==expected_err[exp_head])
          $fatal(1,"ordered response mismatch expected=%h pc=%h inst=%h err=%b",expected[exp_head],pc,inst,err);
        exp_head=exp_head+1; delivered=delivered+1;
        if(hit_stream) begin
          if(stream_received>0 && ticks-stream_last!=1) $fatal(1,"hit stream has a delivery bubble");
          stream_received=stream_received+1; stream_last=ticks;
        end
      end
      if(req && req_ready) begin
        expected[exp_tail]=addr; exp_tail=exp_tail+1; accepted=accepted+1;
        expected_err[exp_tail-1]=expect_fault;
        if(rsp && ready) simultaneous=simultaneous+1;
      end
    end
    app_rd_valid<=0;
    if(app_en && app_rdy && app_cmd==1) begin
      if(pending) $fatal(1,"unexpected second DDR command");
      pending<=1; pending_addr<=app_addr; delay_count<=3+($random(seed)&7); reads=reads+1;
    end
    if(pending && !(gate_a && pending_addr<64)) begin
      if(delay_count!=0) delay_count<=delay_count-1;
      else begin
        app_rd_data<={pattern(pending_addr+12),pattern(pending_addr+8),pattern(pending_addr+4),pattern(pending_addr)};
        app_rd_valid<=1; pending<=0;
      end
    end
  end
  task send;
    input [31:0] a;
    begin
      @(negedge clk); req=1; addr=a;
      @(posedge clk); while(!req_ready) @(posedge clk);
      @(negedge clk); req=0;
    end
  endtask
  task drain;
    begin
      while(exp_head!=exp_tail) @(negedge clk);
      repeat(3) @(negedge clk);
    end
  endtask
  task redirect;
    begin
      @(negedge clk); kill=1;
      @(negedge clk); kill=0;
    end
  endtask
  integer start_reads, n;
  initial begin
    unused=$value$plusargs("SEED=%d",seed);
    repeat(4) @(negedge clk); rst_n=1;
    // Warm C in I$, and B only in L2, entirely through public interfaces.
    send(32'h80000080); drain;
    @(negedge clk); dv=1; da=32'h80000040;
    @(posedge clk); while(!dr) @(posedge clk);
    @(negedge clk); dv=0;
    wait(drv && dl); @(negedge clk);
    gate_a=1;
    send(32'h80000000); send(32'h80000040); send(32'h80000080);
    wait(pending && pending_addr<64);
    repeat(35) @(negedge clk);
    if(dut.count!=3 || dut.q_state[2]!=3 || dut.q_state[0]!=3 || rsp)
      $fatal(1,"B L2 hit and C I$ hit must complete before A DDR response");
    $display("PASS A DDR / B L2 / C I$: younger results buffered, head blocked");
    gate_a=0; drain;

    // Three words on one cold line must cause exactly one 4-command DDR fill.
    start_reads=reads;
    send(32'h80000100); send(32'h80000104); send(32'h80000108); drain;
    if(reads-start_reads!=4) $fatal(1,"same-line requests were not merged");
    $display("PASS same-line merge: three instructions, one line fill");

    // Fill the queue, then recycle a full head on the response edge.
    ready=0;
    send(32'h80000100); send(32'h80000104); send(32'h80000108);
    wait(rsp); repeat(5) @(negedge clk);
    if(req_ready) $fatal(1,"accepted fourth request while full/stalled");
    @(negedge clk); ready=1; req=1; addr=32'h8000010c;
    #1; if(!req_ready || !rsp) $fatal(1,"full queue cannot pop/push together");
    @(negedge clk); req=0; drain;
    $display("PASS full queue: response A and request D on the same edge");
    // Warm all-hit stream: after startup latency, deliver one word every cycle.
    hit_stream=1;
    @(negedge clk); req=1;
    for(n=0;n<32;n=n+1) begin
      addr=32'h80000100+((n%16)*4);
      @(posedge clk); while(!req_ready) @(posedge clk);
      @(negedge clk);
    end
    req=0; drain; hit_stream=0;
    if(stream_received!=32) $fatal(1,"hit stream lost words");
    $display("PASS warm hit throughput: 32 ordered words, one response per clock");

    // Redirect while an old DDR transaction is outstanding; reuse slots now,
    // continue draining the old response, and never deliver a cancelled PC.
    send(32'h80000200); send(32'h80000240); send(32'h80000280);
    wait(l2.u_core.state==5); // S_MISS_WAITRD
    redirect;
    send(32'h80000100); send(32'h80000104); drain;
    repeat(120) @(negedge clk);
    // Ring wrap, same-set replacements, intermittent backend stalls/redirects.
    for(n=0;n<160;n=n+1) begin
      if(n%13==0) begin ready=0; repeat(4) @(negedge clk); ready=1; end
      send(32'h80000000+((n*68)%2048));
      if(n%17==0) redirect;
    end
    drain;
    // A burst error is sticky for ALL coalesced waiters and is not installed
    // into I$. Consume the whole burst before allowing the next main request.
    l2.dbg_i_err_once=1; expect_fault=1;
    send(32'h80010000); send(32'h80010004); send(32'h80010008); drain;
    expect_fault=0;
    send(32'h80010000); drain;
    $display("PASS failed fill: all waiters fault, retry succeeds without poisoned I$ line");
    // Slot reuse is independent of an eight-bit epoch counter wrapping.
    for(n=0;n<300;n=n+1) begin
      send(32'h80010000+((n%16)*4)); redirect;
    end
    send(32'h80010000); drain;
    if(max_count!=3 || simultaneous==0 || cancelled==0 || accepted!=delivered+cancelled)
      $fatal(1,"missing required coverage or lost requests");
    $display("PASS: fetch_slots_tb accepted=%0d delivered=%0d cancelled=%0d simultaneous=%0d",accepted,delivered,cancelled,simultaneous);
    $finish;
  end
endmodule
