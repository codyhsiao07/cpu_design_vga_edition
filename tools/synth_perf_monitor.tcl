# Standalone synthesis sanity/resource check; not a board timing sign-off.
set out_dir "build_perf/synth"
if {$argc > 0} { set out_dir [lindex $argv 0] }
file mkdir $out_dir
read_verilog performance_monitor.v
synth_design -top performance_monitor -part xc7a100tcsg324-1 -mode out_of_context
create_clock -name core_clk -period 20.000 [get_ports clk]
opt_design
report_utilization -file [file join $out_dir utilization.rpt]
write_checkpoint -force [file join $out_dir performance_monitor.dcp]
puts "PASS: standalone performance_monitor synthesis"
