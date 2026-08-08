package require ::quartus::project
package require ::quartus::flow

if {[info exists ::env(K3V_PROJECT_ROOT)] && [file isdirectory $::env(K3V_PROJECT_ROOT)]} {
    set base_dir [file normalize $::env(K3V_PROJECT_ROOT)]
} else {
    set base_dir [file normalize [pwd]]
}

project_open -revision ap_core src/fpga/build/gba_pocket.qpf
set_global_assignment -name NUM_PARALLEL_PROCESSORS 4
execute_flow -compile
project_close

# project_open changes cwd to the project directory; restore it
cd $base_dir

# Run custom STA report for detailed timing path analysis.
file mkdir [file join $base_dir build_output reports]
post_message "Running custom STA report..."
if {[catch {qexec "quartus_sta -t scripts/sta_custom_report.tcl"} result]} {
    post_message -type warning "Custom STA report failed: $result"
} else {
    post_message "Custom STA completed successfully."
}

# Verify reports were generated
foreach f {build_output/reports/ap_core.sta.paths_setup.rpt
           build_output/reports/ap_core.sta.paths_hold.rpt
           build_output/reports/ap_core.sta.clock_summary.rpt} {
    if {[file exists $f]} {
        post_message "Report OK: $f"
    } else {
        post_message -type warning "Report MISSING: $f"
    }
}
