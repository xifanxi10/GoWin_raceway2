# CORE SYNTHESIS ESTIMATE ONLY. 50 MHz matches the default RTL parameter.
# This does NOT assert the physical board oscillator is 50 MHz.
# No package pins, external IO timing, PLL or board reset timing are claimed.
create_clock -name core_assumed_50mhz -period 20.000 [get_ports {clk}]
