`timescale 1ns/1ps
// Reuse the full pipeline + caches + L2 + MIG model. Receive the actual TX pin.
module performance_system_tb;
  icache_pipeline_tb #(.PERF_MODE(1)) tb();
  defparam tb.dut.UART_CLK_HZ = 100_000_000;
  defparam tb.dut.UART_BAUD = 2_000_000; // 50 core clocks/bit, simulation only
`ifdef PERF_FETCH_OVERLAP
  defparam tb.dut.FETCH_OVERLAP_EN = 1;
`endif
  integer trace_fd, uart_fd, n, bit_index;
  integer elapsed=0, retired=0, branch_count=0;
  reg frozen=0;
  reg [63:0] snapshot [0:14];
  reg [7:0] rx_byte;
  reg [8*128-1:0] line=0;
  reg [8*256-1:0] trace_path, uart_path;
  integer hold_enable;
  initial begin
    trace_path="build_perf/retire.trace"; uart_path="build_perf/uart.txt";
    n=$value$plusargs("PERF_TRACE=%s",trace_path);
    n=$value$plusargs("PERF_UART=%s",uart_path);
    trace_fd=$fopen(trace_path,"w"); uart_fd=$fopen(uart_path,"w");
    if (!trace_fd || !uart_fd) $fatal(1,"cannot open performance outputs");
  end
  always @(posedge tb.dut.core_clk) begin
    if (tb.dut.core_rst_n) begin
      if (tb.dut.ifetch_err_o || tb.dut.mem_err_event)
        $fatal(1,"CPU memory/fetch error");
      if (tb.dut.mem_consumed_q && tb.dut.dmem_req_o)
        $fatal(1,"completed memory payload re-issued while EX/MEM held");
      if (tb.dut.perf_status == 2) begin
        elapsed=elapsed+1;
        if (tb.dut.retire_valid) begin
          retired=retired+1;
          if(tb.dut.retire_branch) branch_count=branch_count+1;
          $fdisplay(trace_fd,"%08x %0d %0d %08x",tb.dut.retire_pc,
                    tb.dut.rf_we,tb.dut.rf_waddr,tb.dut.rf_wdata);
        end
      end
    end
  end
  // Deliberately extend EX backpressure across a completed store, load and UART
  // store. This exercises the consumed flag even with the serialized frontend.
  initial begin
    hold_enable=0;
    n=$value$plusargs("PERF_HOLD_MEM=%d",hold_enable);
    if(hold_enable != 0) begin
      wait(tb.dut.perf_status == 2);
      wait(tb.dut.u_mem.new_req && tb.dut.mem_mem_write);
      @(negedge tb.dut.core_clk); force tb.dut.ex_stall_o=1'b1;
      repeat(80) @(negedge tb.dut.core_clk);
      release tb.dut.ex_stall_o;
      wait(tb.dut.u_mem.new_req && tb.dut.mem_mem_read);
      @(negedge tb.dut.core_clk); force tb.dut.ex_stall_o=1'b1;
      repeat(80) @(negedge tb.dut.core_clk);
      release tb.dut.ex_stall_o;
      wait(tb.dut.u_mem.new_req && tb.dut.mem_mem_write && tb.dut.mem_alu_result == 32'h40000000);
      @(negedge tb.dut.core_clk); force tb.dut.ex_stall_o=1'b1;
      repeat(80) @(negedge tb.dut.core_clk);
      release tb.dut.ex_stall_o;
    end
  end
  always @(negedge tb.dut.core_clk) begin
    if (tb.dut.core_rst_n && tb.dut.perf_status == 4) begin
      if (!frozen) begin
        if (tb.dut.u_perf.counters[0] != elapsed ||
            tb.dut.u_perf.counters[1] != retired ||
            tb.dut.u_perf.counters[8] != branch_count)
          $fatal(1,"counter/independent interval scoreboard mismatch");
        for(n=0;n<15;n=n+1) snapshot[n]=tb.dut.u_perf.counters[n];
        frozen=1;
      end else begin
        for(n=0;n<15;n=n+1)
          if(snapshot[n] !== tb.dut.u_perf.counters[n])
            $fatal(1,"snapshot changed while report executes");
      end
    end
  end
  initial begin
    wait(tb.dut.core_rst_n);
    forever begin
      @(negedge tb.uart_tx);
      repeat(75) @(posedge tb.dut.core_clk);
      #1;
      for(bit_index=0;bit_index<8;bit_index=bit_index+1) begin
        rx_byte[bit_index]=tb.uart_tx;
        repeat(50) @(posedge tb.dut.core_clk);
        #1;
      end
      if(tb.uart_tx !== 1'b1) $fatal(1,"UART stop bit error");
      $fwrite(uart_fd,"%c",rx_byte);
      line={line[8*127-1:0],rx_byte};
      if(rx_byte == 10) begin
        if(line == "[PERF_END]\n") begin
          if(!frozen || retired == 0) $fatal(1,"report before completion");
          $fclose(trace_fd); $fclose(uart_fd);
          $display("PASS: performance_system_tb cycles=%0d instructions=%0d branches=%0d UART decoded and snapshot stable",elapsed,retired,branch_count);
          $finish;
        end
        line=0;
      end
    end
  end
endmodule
