create_clock -name sys_clk -period 20.000 [get_ports {clk}]

# The three I2S inputs and the reset button are asynchronous.  Their only
# destination is the first synchroniser flop inside i2s_rx / viz_top, so a
# port-level false path removes exactly that one hop.  Everything downstream
# (shift registers, bit counter, timeout counter) is still timed sys_clk to
# sys_clk.  Naming the internal flops here would break as soon as the
# synthesiser renames them, which is what happened with rx/*_meta_s0.
set_false_path -from [get_ports {i2s_bclk}]
set_false_path -from [get_ports {i2s_lrc}]
set_false_path -from [get_ports {i2s_sd}]
set_false_path -from [get_ports {reset_button}]

# UART TX: one 50 MHz period to the pad.  The 2 Mbps bit period is 500 ns, so
# 20 ns is a delay bound, not a rate constraint; it keeps the pad from being
# placed far away from the transmitter flop.
set_max_delay 20.000 -to [get_ports {viz_tx}]
