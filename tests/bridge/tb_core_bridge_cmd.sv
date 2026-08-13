`timescale 1ns/1ps
`default_nettype none

module tb_core_bridge_cmd;
    localparam [31:0] HOST_STATUS_ADDR = 32'hF800_0000;
    localparam [31:0] HOST_PARAM0_ADDR = 32'hF800_0020;
    localparam [31:0] HOST_PARAM1_ADDR = 32'hF800_0024;
    localparam [31:0] HOST_PARAM2_ADDR = 32'hF800_0028;
    localparam [31:0] HOST_RESP0_ADDR  = 32'hF800_0040;
    localparam [31:0] HOST_RESP1_ADDR  = 32'hF800_0044;
    localparam [31:0] HOST_RESP2_ADDR  = 32'hF800_0048;
    localparam [31:0] TARGET_STATUS_ADDR = 32'hF800_1000;
    localparam [31:0] TARGET_PARAM_PTR_ADDR = 32'hF800_1004;
    localparam [31:0] TARGET_RESP_PTR_ADDR  = 32'hF800_1008;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    wire        reset_n;
    reg         bridge_endian_little = 1'b0;
    reg  [31:0] bridge_addr = 32'd0;
    reg         bridge_rd = 1'b0;
    wire [31:0] bridge_rd_data;
    reg         bridge_wr = 1'b0;
    reg  [31:0] bridge_wr_data = 32'd0;

    reg status_boot_done = 1'b0;
    reg status_setup_done = 1'b0;
    reg status_running = 1'b0;

    wire        dataslot_requestread;
    wire [15:0] dataslot_requestread_id;
    reg         dataslot_requestread_ack = 1'b1;
    reg  [1:0]  dataslot_requestread_result = 2'd0;
    wire        dataslot_requestwrite;
    wire [15:0] dataslot_requestwrite_id;
    wire [31:0] dataslot_requestwrite_size;
    reg         dataslot_requestwrite_ack = 1'b1;
    reg         dataslot_requestwrite_ok = 1'b1;
    wire        dataslot_update;
    wire [15:0] dataslot_update_id;
    wire [31:0] dataslot_update_size;
    wire        dataslot_allcomplete;

    wire [31:0] rtc_epoch_seconds;
    wire [31:0] rtc_date_bcd;
    wire [31:0] rtc_time_bcd;
    wire        rtc_valid;

    reg         savestate_supported = 1'b1;
    reg  [31:0] savestate_addr = 32'h4000_0000;
    reg  [31:0] savestate_size = 32'h0006_0D18;
    reg  [31:0] savestate_maxloadsize = 32'h0006_0D18;
    wire        savestate_start;
    reg         savestate_start_ack = 1'b0;
    reg         savestate_start_busy = 1'b0;
    reg         savestate_start_ok = 1'b0;
    reg         savestate_start_err = 1'b0;
    wire        savestate_load;
    reg         savestate_load_ack = 1'b0;
    reg         savestate_load_busy = 1'b0;
    reg         savestate_load_ok = 1'b0;
    reg         savestate_load_err = 1'b0;
    wire        osnotify_inmenu;

    reg  [9:0]  datatable_addr = 10'd0;
    reg         datatable_wren = 1'b0;
    reg  [31:0] datatable_data = 32'd0;
    wire [31:0] datatable_q;

    core_bridge_cmd dut (
        .clk(clk),
        .reset_n(reset_n),
        .bridge_endian_little(bridge_endian_little),
        .bridge_addr(bridge_addr),
        .bridge_rd(bridge_rd),
        .bridge_rd_data(bridge_rd_data),
        .bridge_wr(bridge_wr),
        .bridge_wr_data(bridge_wr_data),
        .status_boot_done(status_boot_done),
        .status_setup_done(status_setup_done),
        .status_running(status_running),
        .dataslot_requestread(dataslot_requestread),
        .dataslot_requestread_id(dataslot_requestread_id),
        .dataslot_requestread_ack(dataslot_requestread_ack),
        .dataslot_requestread_result(dataslot_requestread_result),
        .dataslot_requestwrite(dataslot_requestwrite),
        .dataslot_requestwrite_id(dataslot_requestwrite_id),
        .dataslot_requestwrite_size(dataslot_requestwrite_size),
        .dataslot_requestwrite_ack(dataslot_requestwrite_ack),
        .dataslot_requestwrite_ok(dataslot_requestwrite_ok),
        .dataslot_update(dataslot_update),
        .dataslot_update_id(dataslot_update_id),
        .dataslot_update_size(dataslot_update_size),
        .dataslot_allcomplete(dataslot_allcomplete),
        .rtc_epoch_seconds(rtc_epoch_seconds),
        .rtc_date_bcd(rtc_date_bcd),
        .rtc_time_bcd(rtc_time_bcd),
        .rtc_valid(rtc_valid),
        .savestate_supported(savestate_supported),
        .savestate_addr(savestate_addr),
        .savestate_size(savestate_size),
        .savestate_maxloadsize(savestate_maxloadsize),
        .osnotify_inmenu(osnotify_inmenu),
        .savestate_start(savestate_start),
        .savestate_start_ack(savestate_start_ack),
        .savestate_start_busy(savestate_start_busy),
        .savestate_start_ok(savestate_start_ok),
        .savestate_start_err(savestate_start_err),
        .savestate_load(savestate_load),
        .savestate_load_ack(savestate_load_ack),
        .savestate_load_busy(savestate_load_busy),
        .savestate_load_ok(savestate_load_ok),
        .savestate_load_err(savestate_load_err),
        .datatable_addr(datatable_addr),
        .datatable_wren(datatable_wren),
        .datatable_data(datatable_data),
        .datatable_q(datatable_q)
    );

    function automatic [31:0] byte_reverse(input [31:0] value);
    begin
        byte_reverse = {value[7:0], value[15:8], value[23:16], value[31:24]};
    end
    endfunction

    function automatic [31:0] bridge_word(input [31:0] semantic_value);
    begin
        bridge_word = bridge_endian_little ? byte_reverse(semantic_value) :
                                              semantic_value;
    end
    endfunction

    task automatic tick;
    begin
        @(posedge clk);
        #1;
    end
    endtask

    task automatic bridge_write_word(
        input [31:0] address,
        input [31:0] semantic_value
    );
    begin
        bridge_addr = address;
        bridge_wr_data = bridge_word(semantic_value);
        bridge_wr = 1'b1;
        tick();
        bridge_wr = 1'b0;
        tick();
    end
    endtask

    task automatic expect_bridge_read(
        input [31:0] address,
        input [31:0] semantic_value,
        input [255:0] label_text
    );
        reg [31:0] expected_bus_value;
    begin
        expected_bus_value = bridge_word(semantic_value);
        bridge_addr = address;
        bridge_rd = 1'b1;
        tick();
        if (bridge_rd_data !== expected_bus_value)
            $fatal(1, "%0s: got %08x expected %08x (addr=%08x rd_out=%08x endian=%b)",
                   label_text, bridge_rd_data, expected_bus_value, bridge_addr,
                   dut.bridge_rd_data_out, dut.endian_little_s);
        bridge_rd = 1'b0;
        tick();
    end
    endtask

    // For all commands exercised here the command leaves ST_PARSE immediately:
    // dataslot acknowledgements and savestate request acknowledgements are
    // asserted before the command is issued.
    task automatic start_host_command(input [15:0] command);
    begin
        bridge_write_word(HOST_STATUS_ADDR, {16'h434D, command});
        tick();
    end
    endtask

    task automatic finish_host_command(
        input [15:0] result,
        input [255:0] label_text
    );
    begin
        tick();
        expect_bridge_read(HOST_STATUS_ADDR, {16'h4F4B, result}, label_text);
    end
    endtask

    task automatic immediate_host_command(
        input [15:0] command,
        input [15:0] result,
        input [255:0] label_text
    );
    begin
        start_host_command(command);
        finish_host_command(result, label_text);
    end
    endtask

    initial begin
        // Match Cyclone V power-up-zero behavior for registers that the generic
        // APF reference block leaves without source-level initializers.
        dut.hstate = 4'd0;
        dut.tstate = 2'd0;
        dut.host_cmd_start = 1'b0;
        dut.status_setup_done_1 = 1'b0;
        dut.target_0 = 32'd0;
        dut.bridge_rd_data_out = 32'd0;
        repeat (5) tick();

        // Host status and reset commands.
        immediate_host_command(16'h0000, 16'd1, "booting status");
        status_boot_done = 1'b1;
        immediate_host_command(16'h0000, 16'd2, "setup status");
        status_running = 1'b1;
        immediate_host_command(16'h0000, 16'd4, "running status");
        status_running = 1'b0;

        immediate_host_command(16'h0010, 16'd0, "reset enter");
        if (reset_n !== 1'b0)
            $fatal(1, "reset-enter command did not clear reset_n");
        immediate_host_command(16'h0011, 16'd0, "reset exit");
        if (reset_n !== 1'b1)
            $fatal(1, "reset-exit command did not set reset_n");

        // Host dataslot commands remain intact.
        bridge_write_word(HOST_PARAM0_ADDR, 32'h0000_1234);
        start_host_command(16'h0080);
        if (!dataslot_requestread || dataslot_requestread_id !== 16'h1234)
            $fatal(1, "dataslot read request/id changed");
        finish_host_command(16'd0, "dataslot read");

        // A pending import asks Pocket to check again later.  Shutdown must not
        // read a zero-initialized or otherwise unverified memory image.
        dataslot_requestread_result = 2'd2;
        bridge_write_word(HOST_PARAM0_ADDR, 32'h0000_000A);
        start_host_command(16'h0080);
        if (!dataslot_requestread || dataslot_requestread_id !== 16'd10)
            $fatal(1, "blocked save read request/id changed");
        finish_host_command(16'd2, "blocked save read asks host to retry");

        // A finalized failed import is terminal for this launch.  Result 1
        // prevents Pocket from retrying forever or touching the source file.
        dataslot_requestread_result = 2'd1;
        bridge_write_word(HOST_PARAM0_ADDR, 32'h0000_000A);
        start_host_command(16'h0080);
        finish_host_command(16'd1, "failed save read is permanently refused");
        dataslot_requestread_result = 2'd0;

        dataslot_requestwrite_ok = 1'b0;
        bridge_write_word(HOST_PARAM0_ADDR, 32'h0000_5678);
        bridge_write_word(HOST_PARAM1_ADDR, 32'h0001_2345);
        start_host_command(16'h0082);
        if (!dataslot_requestwrite || dataslot_requestwrite_id !== 16'h5678 ||
            dataslot_requestwrite_size !== 32'h0001_2345)
            $fatal(1, "dataslot write request parameters changed");
        finish_host_command(16'd2, "dataslot write failure result");
        dataslot_requestwrite_ok = 1'b1;

        bridge_write_word(HOST_PARAM0_ADDR, 32'h0000_00A5);
        bridge_write_word(HOST_PARAM1_ADDR, 32'h0102_0304);
        start_host_command(16'h008A);
        if (!dataslot_update || dataslot_update_id !== 16'h00A5 ||
            dataslot_update_size !== 32'h0102_0304)
            $fatal(1, "dataslot update parameters changed");
        finish_host_command(16'd0, "dataslot update");

        immediate_host_command(16'h008F, 16'd0, "dataslot all-complete");
        if (!dataslot_allcomplete)
            $fatal(1, "all-complete command was not sticky");
        bridge_write_word(HOST_PARAM0_ADDR, 32'h0000_0002);
        immediate_host_command(16'h0080, 16'd0, "dataslot read clears all-complete");
        if (dataslot_allcomplete)
            $fatal(1, "dataslot request did not clear all-complete");

        // RTC notification remains a one-cycle pulse with all payload words.
        bridge_write_word(HOST_PARAM0_ADDR, 32'h65AA_55CC);
        bridge_write_word(HOST_PARAM1_ADDR, 32'h2026_0813);
        bridge_write_word(HOST_PARAM2_ADDR, 32'h0012_3456);
        start_host_command(16'h0090);
        if (!rtc_valid || rtc_epoch_seconds !== 32'h65AA_55CC ||
            rtc_date_bcd !== 32'h2026_0813 || rtc_time_bcd !== 32'h0012_3456)
            $fatal(1, "RTC command pulse/payload changed");
        finish_host_command(16'd0, "RTC command");
        if (rtc_valid)
            $fatal(1, "RTC valid did not return low");

        // Savestate query response registers and request handshakes.
        savestate_start_busy = 1'b1;
        bridge_write_word(HOST_PARAM0_ADDR, 32'd0);
        immediate_host_command(16'h00A0, 16'd1, "savestate start query");
        expect_bridge_read(HOST_RESP0_ADDR, 32'd1, "savestate support");
        expect_bridge_read(HOST_RESP1_ADDR, savestate_addr, "savestate address");
        expect_bridge_read(HOST_RESP2_ADDR, savestate_size, "savestate size");
        savestate_start_busy = 1'b0;

        savestate_load_ok = 1'b1;
        immediate_host_command(16'h00A4, 16'd2, "savestate load query");
        expect_bridge_read(HOST_RESP0_ADDR, 32'd1, "load support");
        expect_bridge_read(HOST_RESP1_ADDR, savestate_addr, "load address");
        expect_bridge_read(HOST_RESP2_ADDR, savestate_maxloadsize, "load maximum size");
        savestate_load_ok = 1'b0;

        savestate_start_ack = 1'b1;
        bridge_write_word(HOST_PARAM0_ADDR, 32'd1);
        start_host_command(16'h00A0);
        if (!savestate_start)
            $fatal(1, "savestate start request was not asserted");
        finish_host_command(16'd0, "savestate start request");
        savestate_start_ack = 1'b0;

        savestate_load_ack = 1'b1;
        start_host_command(16'h00A4);
        if (!savestate_load)
            $fatal(1, "savestate load request was not asserted");
        finish_host_command(16'd0, "savestate load request");
        savestate_load_ack = 1'b0;

        bridge_write_word(HOST_PARAM0_ADDR, 32'd1);
        immediate_host_command(16'h00B0, 16'd0, "menu notification");
        if (!osnotify_inmenu)
            $fatal(1, "menu notification state changed");
        immediate_host_command(16'hDEAD, 16'hFFFF, "unknown command");

        // Rising setup status produces the one target command K3V uses.
        status_setup_done = 1'b1;
        repeat (3) tick();
        immediate_host_command(16'h0000, 16'd3, "idle status");
        expect_bridge_read(TARGET_STATUS_ADDR, 32'h636D_0140,
                           "target Ready-to-Run command");
        expect_bridge_read(TARGET_PARAM_PTR_ADDR, 32'h0000_0020,
                           "target parameter pointer");
        expect_bridge_read(TARGET_RESP_PTR_ADDR, 32'h0000_0040,
                           "target response pointer");
        bridge_write_word(TARGET_STATUS_ADDR, 32'h6275_0000);
        expect_bridge_read(TARGET_STATUS_ADDR, 32'h6275_0000,
                           "target busy status");
        bridge_write_word(TARGET_STATUS_ADDR, 32'h6F6B_0000);
        if (dut.tstate !== 2'd0)
            $fatal(1, "target Ready-to-Run completion did not return idle");

        // Verify both command decoding and readback byte order in little-endian
        // bridge mode. Pointer writes must not alter the APF constants.
        bridge_endian_little = 1'b1;
        repeat (5) tick();
        bridge_write_word(HOST_PARAM0_ADDR, 32'd0);
        immediate_host_command(16'h00B0, 16'd0,
                               "little-endian menu notification");
        if (osnotify_inmenu)
            $fatal(1, "little-endian parameter data was not decoded");
        bridge_write_word(TARGET_PARAM_PTR_ADDR, 32'hDEAD_BEEF);
        expect_bridge_read(TARGET_PARAM_PTR_ADDR, 32'h0000_0020,
                           "constant target pointer in little-endian mode");
        immediate_host_command(16'h0010, 16'd0, "little-endian reset enter");
        if (reset_n !== 1'b0)
            $fatal(1, "little-endian reset command was not decoded");
        immediate_host_command(16'h0011, 16'd0, "little-endian reset exit");

        $display("PASS: core bridge retained host commands and Ready-to-Run target protocol");
        $finish;
    end

endmodule

`default_nettype wire
