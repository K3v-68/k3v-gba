# Custom STA report script for detailed timing path analysis.
#
# Run via:  quartus_sta -t scripts/sta_custom_report.tcl
#
# Generates setup/hold timing path reports and clock Fmax summary
# to build_output/reports/ for CI artifact collection.

# Prefer an explicit root because Quartus 21.1's Tcl runtime can misreport the
# current directory when the repository is below a Windows OneDrive reparse point.
if {[info exists ::env(K3V_PROJECT_ROOT)] && [file isdirectory $::env(K3V_PROJECT_ROOT)]} {
    set base_dir [file normalize $::env(K3V_PROJECT_ROOT)]
} else {
    set base_dir [file normalize [pwd]]
}
# file join is required for Windows drive roots. String concatenation turns a
# root such as R:\ into the illegal mixed-separator path R:\/src/...
set project_path [file join $base_dir src fpga build ap_core]
set report_dir   [file join $base_dir build_output reports]

file mkdir $report_dir

post_message "Base directory : $base_dir"
post_message "Project        : $project_path"
post_message "Report output  : $report_dir"

# Open project and set up timing analysis
project_open $project_path
create_timing_netlist
read_sdc
update_timing_netlist

# Generate detailed reports
set out_setup "$report_dir/ap_core.sta.paths_setup.rpt"
set out_setup_0c "$report_dir/ap_core.sta.paths_setup_current_0c.rpt"
set out_hold  "$report_dir/ap_core.sta.paths_hold.rpt"
set out_sum   "$report_dir/ap_core.sta.clock_summary.rpt"

post_message "Generating setup timing paths report..."
report_timing -setup -npaths 80 -detail full_path -file $out_setup

post_message "Generating 0C setup timing paths report..."
set_operating_conditions 8_slow_1100mv_0c
report_timing -setup -npaths 120 -detail full_path -file $out_setup_0c
set_operating_conditions 8_slow_1100mv_85c

post_message "Generating hold timing paths report..."
report_timing -hold  -npaths 40 -detail full_path -file $out_hold

post_message "Generating SDRAM write path report (sys_pll -> sdram_clk)..."
set out_sdram_wr "$report_dir/ap_core.sta.sdram_write.rpt"
report_timing -setup -npaths 10 -detail full_path \
  -to_clock sdram_clk \
  -file $out_sdram_wr

post_message "Generating SDRAM read path report (sdram_clk -> sys_pll)..."
set out_sdram_rd "$report_dir/ap_core.sta.sdram_read.rpt"
report_timing -setup -npaths 10 -detail full_path \
  -from_clock sdram_clk \
  -file $out_sdram_rd

set cram0_output_ports [get_ports { \
  cram0_a[*] cram0_adv_n cram0_ce0_n cram0_ce1_n cram0_clk cram0_cre \
  cram0_dq[*] cram0_lb_n cram0_oe_n cram0_ub_n cram0_we_n \
}]
set cram0_input_ports [get_ports {cram0_dq[*] cram0_wait}]

post_message "Generating CRAM0 output setup path report (clk_sys -> CRAM0 pins)..."
set out_cram0_out_setup "$report_dir/ap_core.sta.cram0_output_setup.rpt"
report_timing -setup -npaths 40 -detail full_path \
  -to $cram0_output_ports \
  -file $out_cram0_out_setup

post_message "Generating CRAM0 input setup path report (CRAM0 pins -> clk_sys)..."
set out_cram0_in_setup "$report_dir/ap_core.sta.cram0_input_setup.rpt"
report_timing -setup -npaths 40 -detail full_path \
  -from $cram0_input_ports \
  -file $out_cram0_in_setup

post_message "Generating CRAM0 output hold/min path report (clk_sys -> CRAM0 pins)..."
set out_cram0_out_hold "$report_dir/ap_core.sta.cram0_output_hold.rpt"
report_timing -hold -npaths 40 -detail full_path \
  -to $cram0_output_ports \
  -file $out_cram0_out_hold

post_message "Generating CRAM0 input hold/min path report (CRAM0 pins -> clk_sys)..."
set out_cram0_in_hold "$report_dir/ap_core.sta.cram0_input_hold.rpt"
report_timing -hold -npaths 40 -detail full_path \
  -from $cram0_input_ports \
  -file $out_cram0_in_hold

set sram_output_ports [get_ports {sram_a[*] sram_dq[*] sram_oe_n sram_we_n sram_ub_n sram_lb_n}]
set sram_input_ports [get_ports {sram_dq[*]}]

post_message "Generating SRAM snapshot output setup/max path report..."
set out_sram_out_setup "$report_dir/ap_core.sta.sram_output_setup.rpt"
report_timing -setup -npaths 40 -detail full_path \
  -to $sram_output_ports \
  -file $out_sram_out_setup

post_message "Generating SRAM snapshot input setup/max path report..."
set out_sram_in_setup "$report_dir/ap_core.sta.sram_input_setup.rpt"
report_timing -setup -npaths 40 -detail full_path \
  -from $sram_input_ports \
  -file $out_sram_in_setup

post_message "Generating SRAM snapshot output hold/min path report..."
set out_sram_out_hold "$report_dir/ap_core.sta.sram_output_hold.rpt"
report_timing -hold -npaths 40 -detail full_path \
  -to $sram_output_ports \
  -file $out_sram_out_hold

post_message "Generating SRAM snapshot input hold/min path report..."
set out_sram_in_hold "$report_dir/ap_core.sta.sram_input_hold.rpt"
report_timing -hold -npaths 40 -detail full_path \
  -from $sram_input_ports \
  -file $out_sram_in_hold

set snapshot_addr_source_regs [get_registers -nowarn {*|cart_save_snapshot|source_addr[*]}]
set snapshot_addr_destination_regs [get_registers -nowarn {*|snapshot_source_addr_sys[*]}]
set snapshot_data_source_regs [get_registers -nowarn {*|snapshot_source_data_sys[*]}]
set snapshot_data_destination_regs [get_registers -nowarn {*|cart_save_snapshot|source_halfword[*]}]

foreach {label collection} [list \
    "snapshot address source" $snapshot_addr_source_regs \
    "snapshot address destination" $snapshot_addr_destination_regs \
    "snapshot data source" $snapshot_data_source_regs \
    "snapshot data destination" $snapshot_data_destination_regs \
] {
    if {[get_collection_size $collection] == 0} {
        error "Required bundled CDC endpoint collection is empty: $label"
    }
}

post_message "Generating snapshot bundled CDC net-delay report..."
set out_snapshot_cdc_net_delay "$report_dir/ap_core.sta.snapshot_cdc_net_delay.rpt"
report_net_delay -nworst 40 -file $out_snapshot_cdc_net_delay

post_message "Generating clock Fmax summary..."
report_clock_fmax_summary -file $out_sum

# Verify outputs
foreach f [list \
    $out_setup $out_setup_0c $out_hold $out_sum \
    $out_sdram_wr $out_sdram_rd \
    $out_cram0_out_setup $out_cram0_in_setup \
    $out_cram0_out_hold $out_cram0_in_hold \
    $out_sram_out_setup $out_sram_in_setup \
    $out_sram_out_hold $out_sram_in_hold \
    $out_snapshot_cdc_net_delay \
] {
    if {[file exists $f]} {
        post_message "  OK: $f ([file size $f] bytes)"
    } else {
        post_message -type warning "  MISSING: $f"
    }
}

# Cleanup
delete_timing_netlist
project_close

post_message "Custom STA reports complete."
