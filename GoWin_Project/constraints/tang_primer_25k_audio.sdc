create_clock -name sys_clk -period 20.000 [get_ports {clk}]
create_generated_clock -name audio_clk -source [get_ports {clk}] -multiply_by 29 -divide_by 59 [get_pins {audio/clocks/pll/CLKOUT0}]

# UART and S1 are asynchronous external inputs.  Only the first synchronizer
# flop is excluded; all protocol and audio paths remain timed.
set_false_path -from [get_ports {pressure_rx}] -to [get_pins {link/pressure_uart/rx_meta_s0/D}]
set_false_path -from [get_ports {ctrl_rx}] -to [get_pins {link/control_uart/rx_meta_s0/D}]
set_false_path -from [get_ports {reset_button}] -to [get_pins {button_meta_s0/D}]

# The bundled-data mailboxes use a request/acknowledge handshake between the
# 50 MHz protocol clock and the independent PLL audio clock.  Their payload
# bits are held until acknowledgement, so ordinary clock-to-clock setup/hold
# analysis is not applicable; the synchronizer flops remain in the netlist.
set_false_path -from [get_clocks {sys_clk}] -to [get_clocks {audio_clk}]
set_false_path -from [get_clocks {audio_clk}] -to [get_clocks {sys_clk}]

# CTRL_TX is an asynchronous UART output; constrain clock-to-pad delay without
# inventing an MCU setup/hold relationship.
set_max_delay 20.000 -from [get_clocks {sys_clk}] -to [get_ports {ctrl_tx}]

# External flute buttons: first synchronizer stage only.
set_false_path -from [get_ports {flute_key_n[0]}] -to [get_pins {audio/flute_voices[0].button/key_meta_s0/D}]
set_false_path -from [get_ports {flute_key_n[1]}] -to [get_pins {audio/flute_voices[1].button/key_meta_s0/D}]
set_false_path -from [get_ports {flute_key_n[2]}] -to [get_pins {audio/flute_voices[2].button/key_meta_s0/D}]
set_false_path -from [get_ports {flute_key_n[3]}] -to [get_pins {audio/flute_voices[3].button/key_meta_s0/D}]
