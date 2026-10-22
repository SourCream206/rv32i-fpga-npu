create_clock -name clk50 -period 20.000 [get_ports {MAX10_CLK1_50}]
create_generated_clock -name core_clk -source [get_ports {MAX10_CLK1_50}] -divide_by 2 [get_pins {core_clk|q}]
derive_clock_uncertainty
set_false_path -from [get_ports {KEY0}]
set_false_path -to [get_ports {LEDR[*]}]
