`timescale 1ns/1ps
module frontend_profile_monitor_tb;
  reg clk=0;always #5 clk=~clk;
  reg rst_n=0,running=0,done=0,id_valid=0,pending=0,blocked=0,stall=0;
  reg mem_stall=0,ex_stall=0,data_stall=0,req=0,resp=0,ready=1;
  reg redirect=0,lookup=0,hit=0,miss_busy=0,retired=0,control=0;
  reg [31:0] req_pc=0,resp_pc=0,target_pc=0,lookup_pc=0,pc=0,target=0;
  reg [63:0] expected_cycles=0,expected_instructions=0,expected_frontend=0;
  reg [63:0] expected_categories[0:3],expected_joint[0:15];
  integer i;
  wire finalized;
  frontend_profile_monitor #(.ITERATIONS(2)) dut(
    .clk(clk),.rst_n(rst_n),.main_running(running),.main_done(done),
    .pmu_cycles(expected_cycles),.pmu_instructions(expected_instructions),.pmu_frontend(expected_frontend),
    .id_valid(id_valid),.if_pending(pending),.req_blocked(blocked),.stall_id(stall),
    .mem_stall(mem_stall),.ex_stall(ex_stall),.data_stall(data_stall),
    .req_hs(req),.req_pc(req_pc),.req_epoch(8'd0),
    .resp_valid(resp),.resp_ready(ready),.resp_pc(resp_pc),
    .redirect(redirect),.ex_redirect(redirect),.id_redirect(1'b0),.redirect_pc(target_pc),
    .lookup(lookup),.lookup_pc(lookup_pc),.lookup_epoch(8'd0),.lookup_hit(hit),.miss_busy(miss_busy),
    .retire_valid(retired),.retire_ctrl(control),.retire_pc(pc),.retire_target(target),
    .kernel_pc(32'h1000),.loop_marker_pc(32'h1010),.finalized(finalized));
  // Expected categories/masks are specified by each independent scenario,
  // including future miss/cancel outcomes that the observer has not seen yet.
  task tick;
    input integer category,mask;
    begin
      @(posedge clk);
      if(running) begin
        expected_cycles=expected_cycles+1;
        if(retired) expected_instructions=expected_instructions+1;
        if(category>=0) begin
          expected_frontend=expected_frontend+1;
          expected_categories[category]=expected_categories[category]+1;
          expected_joint[mask]=expected_joint[mask]+1;
        end
      end
      #1;@(negedge clk);
    end
  endtask
  task request;
    input [31:0] address;
    begin req=1;req_pc=address;pending=0;resp=0;lookup=0;tick(-1,0);req=0;pending=1;end
  endtask
  task complete;
    begin pending=0;resp=0;lookup=0;end
  endtask
  initial begin
    for(i=0;i<4;i=i+1) expected_categories[i]=0;
    for(i=0;i<16;i=i+1) expected_joint[i]=0;
    tick(-1,0);rst_n=1;running=1;
    retired=1;control=1;pc='h100;target='h1000;tick(-1,0);
    pc='h1010;target='h2000;tick(-1,0);retired=0;control=0;
    // Hit lookup + ready/valid handoff, including retrospective prelookup sample.
    request('h2000);tick(0,0);
    lookup=1;lookup_pc='h2000;hit=1;tick(0,0);
    lookup=0;resp=1;resp_pc='h2000;tick(0,8);complete;
    // An occupied ID held by the backend is not frontend_wait.
    id_valid=1;stall=1;mem_stall=1;tick(-1,0);id_valid=0;stall=0;mem_stall=0;
    // Miss, then backend overlaps both pre-response and already-ready response.
    request('h3000);tick(1,4);
    lookup=1;lookup_pc='h3000;hit=0;tick(1,4);
    lookup=0;miss_busy=1;stall=1;mem_stall=1;tick(2,5);
    miss_busy=0;resp=1;resp_pc='h3000;ready=0;tick(2,13);
    stall=0;mem_stall=0;ready=1;tick(1,12);complete;
    // Cancellation before a tag decision attributes the earlier work to squash.
    request('h4000);tick(3,2);
    redirect=1;target_pc='h5000;tick(3,2);
    redirect=0;pending=0;tick(-1,0);
    // Recovery includes the target's lookup/miss; backend retains first priority.
    request('h5000);tick(3,6);
    lookup=1;lookup_pc='h5000;hit=0;tick(3,6);
    lookup=0;resp=1;resp_pc='h5000;ready=0;stall=1;mem_stall=1;tick(2,15);
    ready=1;stall=0;mem_stall=0;tick(3,14);complete;
    retired=1;control=1;pc='h1010;target='h2000;tick(-1,0);retired=0;control=0;
    // Last request crosses iterate/main end; commit only after its outcome resolves.
    request('h6000);tick(0,0);
    lookup=1;lookup_pc='h6000;hit=1;tick(0,0);lookup=0;
    retired=1;control=1;pc='h10fc;target='h104;tick(0,0);retired=0;control=0;
    running=0;done=1;tick(-1,0);
    if(finalized) $fatal(1,"finalized before pending samples resolved");
    resp=1;resp_pc='h6000;tick(-1,0);
    if(!finalized) $fatal(1,"profile was not finalized");
    for(i=0;i<4;i=i+1)
      if(dut.categories[i]!=expected_categories[i]) $fatal(1,"wrong category %0d",i);
    for(i=0;i<16;i=i+1)
      if(dut.joint[i]!=expected_joint[i]) $fatal(1,"wrong joint mask %0d",i);
    $display("PASS: frontend_profile_monitor_tb hit, miss, overlaps, cancellation, recovery, scope and end-boundary cases");
    $finish;
  end
  initial begin #100000;$fatal(1,"unit timeout");end
endmodule
