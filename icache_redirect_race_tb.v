`timescale 1ns/1ps
// A redirect on the response-production edge must cancel that response.
module icache_redirect_race_tb;
  reg clk=0;always #5 clk=~clk;
  reg rst_n=0,req=0,kill=0,ready=1;
  reg [31:0] addr=0;
  wire req_ready,valid,err;
  wire [31:0] pc,inst;
  wire lv,lr;wire [31:0] la;wire[1:0]lc;wire[2:0]ls;wire[7:0]ll;
  integer i;
  i_cache #(.CACHE_BYTES(256),.INDEX_BITS(1),.TAG_BITS(25)) dut(
    .clk(clk),.rst_n(rst_n),.if_req_valid(req),.if_req_addr(addr),.if_req_ready(req_ready),
    .if_req_kill(kill),.if_resp_valid(valid),.if_resp_ready(ready),.if_resp_inst(inst),
    .if_resp_pc(pc),.if_resp_err(err),.ic_flush_req(1'b0),.ic_flush_ack(),
    .ic_inv_valid(1'b0),.ic_inv_all(1'b0),.ic_inv_index(1'b0),.ic_inv_way(1'b0),.ic_inv_ack(),
    .l2_req_valid(lv),.l2_req_ready(1'b1),.l2_req_addr(la),.l2_req_cmd(lc),
    .l2_req_size(ls),.l2_req_len(ll),.l2_rsp_valid(1'b0),.l2_rsp_ready(lr),
    .l2_rsp_data(64'd0),.l2_rsp_last(1'b0),.l2_rsp_err(1'b0));
  task tick;begin @(posedge clk);#1;end endtask
  task request;
    input[31:0] a;
    begin @(negedge clk);addr=a;req=1;#1;if(!req_ready)$fatal(1,"request blocked");
      tick;@(negedge clk);req=0;
    end
  endtask
  task response;
    input[31:0] a;
    integer t;
    begin
      t=0;while(!valid && t<10)begin tick;t=t+1;end
      if(!valid || pc!=a || inst!=32'h13 || err)$fatal(1,"missing/wrong response");
    end
  endtask
  initial begin
    tick;tick;@(negedge clk);rst_n=1;
    // Prime a hit line to target the precise pipeline edge, independent of refill latency.
    dut.valid_way0[0]=1;dut.tag_way0[0]=0;
    for(i=0;i<16;i=i+1)dut.data_way0[0][i*32+:32]=32'h13;
    request(0);tick;
    @(negedge clk);
    if(!dut.s2_valid || !dut.hit)$fatal(1,"test did not reach response-production edge");
    kill=1;tick;
    if(valid)$fatal(1,"redirect-cycle response escaped epoch cancellation");
    @(negedge clk);kill=0;repeat(3)tick;
    if(valid)$fatal(1,"stale response reappeared");
    // A target request after the redirect still completes normally.
    request(4);response(4);
    // Cancel an already produced, back-pressured response too.
    @(negedge clk);ready=0;kill=1;tick;
    if(valid)$fatal(1,"held response survived redirect");
    @(negedge clk);kill=0;ready=1;
    request(8);response(8);
    $display("PASS: icache_redirect_race_tb production-edge and held-response cancellation");
    $finish;
  end
  initial begin #10000;$fatal(1,"timeout");end
endmodule
