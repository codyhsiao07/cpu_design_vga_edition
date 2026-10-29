`timescale 1ns/1ps
// Simulation observer only: no drives/forces into the DUT.
// Pending-request histograms are committed after hit/miss/squash is known.
module frontend_profile_monitor #(
  parameter ITERATIONS=3,
  parameter SCOPES=ITERATIONS+2
)(
  input clk, rst_n, main_running, main_done,
  input [63:0] pmu_cycles, pmu_instructions, pmu_frontend,
  input id_valid, if_pending, req_blocked, stall_id,
  input mem_stall, ex_stall, data_stall,
  input req_hs, input [31:0] req_pc, input [7:0] req_epoch,
  input resp_valid, resp_ready, input [31:0] resp_pc,
  input redirect, ex_redirect, id_redirect, input [31:0] redirect_pc,
  input lookup, input [31:0] lookup_pc, input [7:0] lookup_epoch,
  input lookup_hit, miss_busy,
  input retire_valid, retire_ctrl,
  input [31:0] retire_pc, retire_target, kernel_pc, loop_marker_pc,
  output reg finalized=0
);
  // scopes: 0 main, 1 iterate(), 2.. individual outer iterations.
  // joint mask: bit0 backend, bit1 redirect-associated, bit2 confirmed miss,
  //             bit3 raw response valid. Categories: hit=0, miss=1, back=2, redir=3.
  reg [63:0] cycles[0:SCOPES-1], instructions[0:SCOPES-1];
  reg [63:0] frontend[0:SCOPES-1], categories[0:SCOPES*4-1];
  reg [63:0] joint[0:SCOPES*16-1], buffered[0:SCOPES*8-1];
  reg [63:0] backend_mem[0:SCOPES-1], backend_ex[0:SCOPES-1];
  reg [63:0] backend_data[0:SCOPES-1];
  reg [63:0] redirects_ex[0:SCOPES-1], redirects_id[0:SCOPES-1];
  reg [63:0] clean_gaps[0:64], hit_latencies[0:64];
  reg [63:0] wall_cycle=0, buffered_main=0;
  reg txn_active=0, txn_known=0, txn_miss=0, txn_measured=0;
  reg txn_available=0;
  reg [31:0] txn_pc=0;
  reg [7:0] txn_epoch=0;
  reg [63:0] txn_cycle=0;
  reg recovery=0;
  reg [31:0] recovery_target=0;
  reg kernel_active=0;
  reg [31:0] kernel_return=0;
  integer iteration=-1, kernel_calls=0, loop_markers=0;
  reg previous_req_measured=0, gap_obstructed=0;
  reg [63:0] previous_req_cycle=0;
  reg [63:0] requests=0, completions_hit=0, completions_miss=0, squashed=0;
  reg [63:0] latency_hit_sum=0, latency_miss_sum=0;
  reg [63:0] latency_miss_max=0, latency=0, gap=0;
  integer fd, option_read, a, b;
  reg [8*512-1:0] profile_path;
  wire fe_wait = !id_valid && (if_pending || req_blocked);
  wire response_hs = resp_valid && resp_ready && !redirect;

  task commit;
    input integer scope, mask;
    input [63:0] amount;
    integer category;
    begin
      if(mask & 1) category=2;
      else if(mask & 2) category=3;
      else if(mask & 4) category=1;
      else category=0;
      categories[scope*4+category]=categories[scope*4+category]+amount;
      joint[scope*16+mask]=joint[scope*16+mask]+amount;
    end
  endtask

  task sample_scope;
    input integer scope;
    integer mask;
    begin
      cycles[scope]=cycles[scope]+1;
      if(retire_valid) instructions[scope]=instructions[scope]+1;
      if(ex_redirect) redirects_ex[scope]=redirects_ex[scope]+1;
      if(id_redirect) redirects_id[scope]=redirects_id[scope]+1;
      if(fe_wait) begin
        frontend[scope]=frontend[scope]+1;
        if(stall_id && mem_stall) backend_mem[scope]=backend_mem[scope]+1;
        if(stall_id && ex_stall) backend_ex[scope]=backend_ex[scope]+1;
        if(stall_id && data_stall) backend_data[scope]=backend_data[scope]+1;
        // Buffer B/R/response-valid; the miss bit is filled in retrospectively.
        mask=(stall_id ? 1 : 0) | ((recovery || redirect) ? 2 : 0) |
             (resp_valid ? 4 : 0);
        if(txn_active) begin
          buffered[scope*8+mask]=buffered[scope*8+mask]+1;
          if(scope==0) buffered_main=buffered_main+1;
        end else begin
          // Usually a target request blocked while a cancelled miss drains.
          if(!stall_id && !recovery && !redirect && !miss_busy)
            $fatal(1,"frontend wait without an attributable request/state");
          commit(scope,(mask&3) | (miss_busy ? 4 : 0) | ((mask&4)<<1),64'd1);
        end
      end
    end
  endtask

  task finish_transaction;
    input cancelled;
    integer s,m,mask;
    reg [63:0] amount;
    begin
      for(s=0;s<SCOPES;s=s+1) begin
        for(m=0;m<8;m=m+1) begin
          amount=buffered[s*8+m];
          if(amount!=0) begin
            if(!cancelled && !txn_known)
              $fatal(1,"completed measured request without tag decision");
            mask=(m&3) | (cancelled ? 2 : 0) |
                 ((txn_known && txn_miss) ? 4 : 0) | ((m&4)<<1);
            commit(s,mask,amount);
            if(s==0) buffered_main=buffered_main-amount;
            buffered[s*8+m]=0;
          end
        end
      end
      txn_active=0;
    end
  endtask

  task dump_profile;
    integer s,m;
    reg [63:0] total;
    begin
      if(cycles[0]!=pmu_cycles || instructions[0]!=pmu_instructions ||
         frontend[0]!=pmu_frontend)
        $fatal(1,"frontend observer does not match all three PMU counters");
      if(kernel_active || kernel_calls!=1 || loop_markers!=ITERATIONS)
        $fatal(1,"incorrect iterate/loop scope: calls=%0d markers=%0d",kernel_calls,loop_markers);
      fd=$fopen(profile_path,"w");
      if(!fd) $fatal(1,"cannot open frontend profile output");
      $fdisplay(fd,"schema 1");
      $fdisplay(fd,"iterations %0d",ITERATIONS);
      for(s=0;s<SCOPES;s=s+1) begin
        total=0;
        for(m=0;m<4;m=m+1) total=total+categories[s*4+m];
        if(total!=frontend[s]) $fatal(1,"category partition mismatch scope=%0d",s);
        total=0;
        for(m=0;m<16;m=m+1) total=total+joint[s*16+m];
        if(total!=frontend[s]) $fatal(1,"joint histogram mismatch scope=%0d",s);
        $fdisplay(fd,"scope %0d %0d %0d %0d",s,cycles[s],instructions[s],frontend[s]);
        for(m=0;m<4;m=m+1)
          $fdisplay(fd,"category %0d %0d %0d",s,m,categories[s*4+m]);
        for(m=0;m<16;m=m+1)
          $fdisplay(fd,"joint %0d %0d %0d",s,m,joint[s*16+m]);
        $fdisplay(fd,"backend %0d %0d %0d %0d",s,backend_mem[s],backend_ex[s],backend_data[s]);
        $fdisplay(fd,"redirects %0d %0d %0d",s,redirects_ex[s],redirects_id[s]);
      end
      $fdisplay(fd,"requests %0d %0d %0d %0d",requests,completions_hit,completions_miss,squashed);
      $fdisplay(fd,"latencies %0d %0d %0d",latency_hit_sum,latency_miss_sum,latency_miss_max);
      for(m=0;m<=64;m=m+1) begin
        $fdisplay(fd,"gap %0d %0d",m,clean_gaps[m]);
        $fdisplay(fd,"hit_latency %0d %0d",m,hit_latencies[m]);
      end
      $fclose(fd);
      finalized=1;
      $display("PASS: frontend_profile_monitor exact PMU partition: %0d / %0d cycles",frontend[0],cycles[0]);
    end
  endtask

  initial begin
    profile_path="build_perf/frontend.profile.txt";
    option_read=$value$plusargs("FRONTEND_PROFILE=%s",profile_path);
    for(a=0;a<SCOPES;a=a+1) begin
      cycles[a]=0;instructions[a]=0;frontend[a]=0;
      backend_mem[a]=0;backend_ex[a]=0;backend_data[a]=0;
      redirects_ex[a]=0;redirects_id[a]=0;
    end
    for(a=0;a<SCOPES*4;a=a+1) categories[a]=0;
    for(a=0;a<SCOPES*8;a=a+1) buffered[a]=0;
    for(a=0;a<SCOPES*16;a=a+1) joint[a]=0;
    for(a=0;a<=64;a=a+1) begin clean_gaps[a]=0;hit_latencies[a]=0;end
  end

  always @(posedge clk) begin
    if(!rst_n) begin
      txn_active=0;recovery=0;kernel_active=0;iteration=-1;
      previous_req_measured=0;gap_obstructed=0;
    end else if(!finalized) begin
      wall_cycle=wall_cycle+1;
      if(stall_id || redirect || miss_busy || (lookup && !lookup_hit)) gap_obstructed=1;
      // Ignore a stale-epoch lookup left behind by a cancelled request.
      if(txn_active && lookup && lookup_pc==txn_pc && lookup_epoch==txn_epoch) begin
        txn_known=1;txn_miss=!lookup_hit;
      end
      if(txn_active && resp_valid && resp_pc==txn_pc && !redirect && !txn_available) begin
        txn_available=1;
        if(txn_measured) begin
          latency=wall_cycle-txn_cycle;
          if(txn_known && txn_miss) begin
            latency_miss_sum=latency_miss_sum+latency;
            if(latency>latency_miss_max) latency_miss_max=latency;
          end else if(txn_known) begin
            latency_hit_sum=latency_hit_sum+latency;
            hit_latencies[latency<64 ? latency : 64]=hit_latencies[latency<64 ? latency : 64]+1;
          end
        end
      end
      if(main_running) begin
        sample_scope(0);
        if(kernel_active) begin
          sample_scope(1);
          if(iteration>=0) sample_scope(iteration+2);
        end
      end
      if(redirect) begin
        if(txn_active) begin
          if(txn_measured) squashed=squashed+1;
          finish_transaction(1'b1);
        end
        recovery=1;recovery_target=redirect_pc;
      end else if(response_hs) begin
        if(!txn_active || resp_pc!=txn_pc) $fatal(1,"unmatched fetch response");
        if(txn_measured) begin
          if(txn_miss) completions_miss=completions_miss+1;
          else completions_hit=completions_hit+1;
        end
        finish_transaction(1'b0);
        if(recovery) begin
          if(resp_pc!=recovery_target) $fatal(1,"response is not last redirect target");
          recovery=0;
        end
      end
      if(req_hs) begin
        if(txn_active) $fatal(1,"observer expects baseline single outstanding fetch");
        if(main_running && previous_req_measured && !gap_obstructed) begin
          gap=wall_cycle-previous_req_cycle;
          clean_gaps[gap<64 ? gap : 64]=clean_gaps[gap<64 ? gap : 64]+1;
        end
        previous_req_cycle=wall_cycle;previous_req_measured=main_running;gap_obstructed=0;
        txn_active=1;txn_known=0;txn_miss=0;txn_available=0;
        txn_measured=main_running;txn_pc=req_pc;txn_epoch=req_epoch;txn_cycle=wall_cycle;
        if(main_running) requests=requests+1;
      end
      // Same interval convention as PMU: exclude call retirement, include return.
      if(main_running && retire_valid && retire_ctrl && retire_target==kernel_pc) begin
        if(kernel_active) $fatal(1,"nested iterate call");
        kernel_active=1;kernel_return=retire_pc+4;iteration=-1;kernel_calls=kernel_calls+1;
      end else if(kernel_active && retire_valid && retire_ctrl && retire_target==kernel_return) begin
        kernel_active=0;
      end else if(kernel_active && retire_valid && retire_pc==loop_marker_pc) begin
        iteration=iteration+1;loop_markers=loop_markers+1;
        if(iteration>=ITERATIONS) $fatal(1,"too many iteration markers");
      end
      // A request crossing main's end may resolve later; retain its old samples.
      if(main_done && buffered_main==0) dump_profile;
    end
  end
endmodule
