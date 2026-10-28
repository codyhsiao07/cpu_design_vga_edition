# Standalone CPU + L1 synthesis check. USE_MIG=0 exposes external L2 ports;
# this deliberately does not claim full board/MIG implementation or timing closure.
set sources [list icache_pipeline_top.v performance_monitor.v icache_top.v icache.v \
  IF.v IFID_register.v ID.v IDEX_register.v EX.v booth_multiplier.v restoring_divider.v \
  EXMEM_register.v MEM.v MEMWB_register.v WB.v hazard_unit.v forward_unit.v dcache.v \
  L2_cache.v I_D_arbitration.v branch_predictor.v uart_rx.v uart_tx.v uart_bootloader.v]
if {[catch {
foreach variant {0 1} {
  set out_dir "build_perf/fetch_synthesis/variant_$variant"
  file mkdir $out_dir
  create_project -in_memory -part xc7a100tcsg324-1
  set_property verilog_define {SYNTHESIS FAST_SYNTH} [current_fileset]
  read_verilog $sources
  synth_design -top icache_pipeline_top -mode out_of_context -part xc7a100tcsg324-1 \
    -generic "USE_MIG=0 USE_VGA=0 UART_BOOT_EN=0 UART_CLK_HZ=50000000 FETCH_OVERLAP_EN=$variant"
  create_clock -name core_clk -period 20.000 [get_ports clk]
  opt_design
  report_utilization -file "$out_dir/utilization.rpt"
  report_drc -file "$out_dir/drc.rpt"
  write_checkpoint -force "$out_dir/core_no_mig.dcp"
  puts "PASS: standalone CPU/L1 synthesis FETCH_OVERLAP_EN=$variant"
  close_project
}
} message]} { puts stderr "FETCH SYNTHESIS FAILED: $message"; exit 1 }
exit 0
