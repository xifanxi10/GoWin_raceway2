# Build the visualisation co-processor project.
#   gw_sh board_b/build.tcl        (from the repository root)
#   gw_sh build.tcl                (from board_b)
# Produces board_b/impl/pnr/board_b.fs.  Does not program the device.
set root [file normalize [file dirname [info script]]]
cd $root
open_project [file join $root board_b.gprj]
set_option -top_module viz_top
set_option -verilog_std sysv2017
set_option -global_freq 50
set_option -gen_text_timing_rpt 1
set_option -gen_verilog_sim_netlist 1
# E2 shares CPU/SSPI; keep the same GPIO policy as the audio board.
set_option -use_cpu_as_gpio 1
set_option -use_sspi_as_gpio 1
set_option -use_i2c_as_gpio 1
set_option -use_jtag_as_gpio 0
set_option -use_mspi_as_gpio 0
run all
