`timescale 1ns/1ps
module performance_monitor_tb;
  reg clk=0; always #5 clk=~clk;
  reg rst_n=0, req=0, we=0, rv=0, ctrl=0, branch=0, miss=0, fault=0;
  reg [11:0] addr=0;
  reg [31:0] data=0, pc=0, target=0;
  reg [3:0] strb=15;
  reg [10:0] events=0;
  wire ready, valid, err;
  wire [31:0] rdata;
  wire [3:0] status;
  performance_monitor #(.FEATURE_FLAGS(1)) dut(clk,rst_n,req,we,addr,data,strb,ready,valid,rdata,err,
                          rv,pc,ctrl,target,branch,miss,events,fault,status);
  task tick; begin @(posedge clk); #1; end endtask
  task write_reg;
    input [11:0] a; input [31:0] d;
    begin
      @(negedge clk); req=1; we=1; addr=a; data=d; #1;
      if (err || !ready || !valid) $fatal(1,"valid write rejected");
      tick; @(negedge clk); req=0; we=0;
    end
  endtask
  task read_check;
    input [11:0] a; input [31:0] d;
    begin
      @(negedge clk); req=1; we=0; addr=a; #1;
      if (err || rdata !== d) $fatal(1,"read %h got %h expected %h",a,rdata,d);
      @(negedge clk); req=0;
    end
  endtask
  initial begin
    tick; @(negedge clk); rst_n=1;
    write_reg(8,32'h100); write_reg(12,32'h200); write_reg(16,1);
    // A matching PC without a valid control retirement cannot start.
    @(negedge clk); pc='h100; ctrl=1; tick;
    if(status != 1) $fatal(1,"spurious start");
    @(negedge clk); rv=1; tick;
    if(status != 2 || dut.counters[0] != 0 || dut.counters[1] != 0)
      $fatal(1,"start boundary included");
    // Two consecutive retirements are two instructions, not one rising edge.
    @(negedge clk); ctrl=0; pc='h300; events='h7ff; tick;
    @(negedge clk); pc='h304; branch=1; miss=1; tick;
    // Nested return to a different target does not end main.
    @(negedge clk); ctrl=1; branch=0; target='h400; tick;
    if(status != 2) $fatal(1,"nested return stopped monitor");
    @(negedge clk); rv=0; events=0; tick;
    @(negedge clk); rv=1; target='h200; tick;
    if(status != 4 || dut.counters[0] != 5 || dut.counters[1] != 4 ||
       dut.counters[8] != 1 || dut.counters[9] != 1 || dut.counters[14] != 3)
      $fatal(1,"inclusive final cycle/instruction or event count incorrect");
    repeat(5) tick;
    if(dut.counters[0] != 5 || dut.counters[1] != 4) $fatal(1,"snapshot changed");
    read_check(12'h100,5); read_check(12'h108,4); read_check(12'h104,0);
    read_check(12'h010,1);
    // Invalid accesses and partial writes must not mutate configuration.
    @(negedge clk); req=1; we=1; addr=8; strb=1; #1;
    if(!err) $fatal(1,"partial write accepted");
    tick; @(negedge clk); req=0; strb=15;
    read_check(8,'h100);
    @(negedge clk); req=1; we=0; addr='h17c; #1;
    if(!err) $fatal(1,"unknown register accepted");
    @(negedge clk); addr='h101; #1;
    if(!err) $fatal(1,"unaligned read accepted");
    @(negedge clk); we=1; addr='h014; data=1; #1;
    if(!err) $fatal(1,"read-only write accepted");
    @(negedge clk); addr='h010; data=3; #1;
    if(!err) $fatal(1,"invalid command accepted");
    @(negedge clk); req=0; rv=0;
    write_reg(16,1);
    @(negedge clk); rv=1; pc='h100; target='h400; tick;
    @(negedge clk); req=1; we=1; addr=16; data=1; #1;
    if(!err) $fatal(1,"re-arm during running accepted");
    tick; @(negedge clk); req=0; we=0; rv=0; fault=1; tick;
    if(status != 8) $fatal(1,"fault not recorded");
    @(negedge clk); fault=0;
    write_reg(16,2);
    if(status != 0 || dut.counters[0] != 0) $fatal(1,"clear failed");
    // Exercise carry and both halves without waiting 2^32 clocks.
    write_reg(16,1);
    @(negedge clk); rv=1; ctrl=1; pc='h100; tick;
    @(negedge clk); rv=0; dut.counters[0]=64'hffffffff; tick;
    @(negedge clk); fault=1; tick;
    // fault cycle itself counts, so low half is now 1.
    read_check(12'h104,1); read_check(12'h100,1);
    @(negedge clk); rst_n=0; tick;
    if(status != 0 || dut.counters[0] != 0) $fatal(1,"reset failed");
    $display("PASS: performance_monitor_tb boundaries, consecutive retirements, freeze, MMIO, fault, carry, reset");
    $finish;
  end
  initial begin #100000; $fatal(1,"timeout"); end
endmodule
