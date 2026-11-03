create_clock -name sys_clk -period 20.000 [get_ports {clk}]
# Asynchronous UART/button pins feed only these FIRST synchronizer flops.
# The first -> second flop and every protocol/register path remain timed.
set_false_path -from [get_ports {pressure_rx}] -to [get_pins {link/pressure_uart/rx_meta_s0/D}]
set_false_path -from [get_ports {ctrl_rx}] -to [get_pins {link/control_uart/rx_meta_s0/D}]
set_false_path -from [get_ports {reset_button}] -to [get_pins {button_meta_s0/D}]
# CTRL_TX is an asynchronous UART output, not source-synchronous to sys_clk.
# Bound clock-to-pad delay to 20 ns; no invented MCU setup/hold requirement.
set_max_delay 20.000 -from [get_clocks {sys_clk}] -to [get_ports {ctrl_tx}]
