`timescale 1ns/1ps
`default_nettype none

module tb_rtc_persistence;
    localparam [27:0] CART_BASE = 28'h0000000;
    localparam [27:0] RTC_BASE  = 28'h1000000;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg         reset_n = 1'b0;
    reg         loader_accept = 1'b0;
    reg [27:0]  loader_addr = 28'd0;
    reg [15:0]  loader_data = 16'd0;
    reg [23:0]  save_size = 24'h01_0000;
    reg         finalize_load = 1'b0;
    reg [31:0]  host_epoch = 32'd0;
    reg [41:0]  host_savedtime = 42'd0;
    wire [31:0] loaded_timestamp;
    wire [41:0] loaded_savedtime;
    wire        load_complete;
    wire        stored_record_present;
    wire        sidecar_record_valid;
    wire        legacy_record_valid;
    reg         unloader_accept = 1'b0;
    reg [27:0]  unloader_addr = RTC_BASE;
    reg [31:0]  live_timestamp = 32'd0;
    reg [41:0]  live_savedtime = 42'd0;
    wire [15:0] unloader_word;

    rtc_persistence dut (
        .clk                   ( clk ),
        .reset_n               ( reset_n ),
        .loader_accept         ( loader_accept ),
        .loader_addr           ( loader_addr ),
        .loader_data           ( loader_data ),
        .save_size             ( save_size ),
        .finalize_load         ( finalize_load ),
        .host_epoch            ( host_epoch ),
        .host_savedtime        ( host_savedtime ),
        .loaded_timestamp      ( loaded_timestamp ),
        .loaded_savedtime      ( loaded_savedtime ),
        .load_complete         ( load_complete ),
        .stored_record_present ( stored_record_present ),
        .sidecar_record_valid  ( sidecar_record_valid ),
        .legacy_record_valid   ( legacy_record_valid ),
        .unloader_accept       ( unloader_accept ),
        .unloader_addr         ( unloader_addr ),
        .live_timestamp        ( live_timestamp ),
        .live_savedtime        ( live_savedtime ),
        .unloader_word         ( unloader_word )
    );

    localparam [41:0] HOST_TIME =
        {8'h24, 5'h08, 6'h05, 3'd1, 6'h07, 7'h08, 7'h09};
    localparam [41:0] LEGACY_TIME =
        {8'h23, 5'h12, 6'h31, 3'd0, 6'h23, 7'h59, 7'h58};
    localparam [41:0] SIDECAR_TIME =
        {8'h25, 5'h02, 6'h28, 3'd5, 6'h16, 7'h45, 7'h12};
    localparam [41:0] DEFAULT_TIME =
        {8'h00, 5'h01, 6'h01, 3'd0, 6'h00, 7'h00, 7'h00};

    task automatic tick;
    begin
        @(posedge clk);
        #1;
    end
    endtask

    task automatic reset_dut;
    begin
        reset_n = 1'b0;
        loader_accept = 1'b0;
        finalize_load = 1'b0;
        unloader_accept = 1'b0;
        save_size = 24'h01_0000;
        host_epoch = 32'd1_700_000_000;
        host_savedtime = HOST_TIME;
        live_timestamp = 32'd0;
        live_savedtime = 42'd0;
        repeat (2) tick();
        reset_n = 1'b1;
        tick();
    end
    endtask

    task automatic write_word(input [27:0] address, input [15:0] value);
    begin
        loader_addr = address;
        loader_data = value;
        loader_accept = 1'b1;
        tick();
        loader_accept = 1'b0;
        tick();
    end
    endtask

    task automatic write_record(
        input [27:0] base,
        input [31:0] timestamp,
        input [41:0] savedtime
    );
    begin
        write_word(base + 28'd0,  timestamp[15:0]);
        write_word(base + 28'd2,  timestamp[31:16]);
        write_word(base + 28'd4,  savedtime[15:0]);
        write_word(base + 28'd6,  savedtime[31:16]);
        write_word(base + 28'd8,  {6'd0, savedtime[41:32]});
        write_word(base + 28'd10, 16'd0);
        write_word(base + 28'd12, 16'd0);
        write_word(base + 28'd14, 16'd0);
    end
    endtask

    task automatic wait_for_load;
        integer wait_cycles;
    begin
        wait_cycles = 0;
        // The M10K-backed record store replays both candidates through one
        // synchronous read port before committing the selected source.
        while (!load_complete && wait_cycles < 64) begin
            tick();
            wait_cycles = wait_cycles + 1;
        end
        if (!load_complete)
            $fatal(1, "RTC persistence did not finalize");
    end
    endtask

    task automatic finish_load;
    begin
        finalize_load = 1'b1;
        tick();
        finalize_load = 1'b0;
        wait_for_load();
    end
    endtask

    task automatic write_word_and_finalize(
        input [27:0] address,
        input [15:0] value
    );
    begin
        // Exercise the strongest safe boundary: the final accepted halfword
        // and finalize request arrive on the same clock edge.
        loader_addr = address;
        loader_data = value;
        loader_accept = 1'b1;
        finalize_load = 1'b1;
        tick();
        loader_accept = 1'b0;
        finalize_load = 1'b0;
        if (load_complete)
            $fatal(1, "RTC persistence completed before replaying M10K data");
        wait_for_load();
    end
    endtask

    task automatic expect_loaded(
        input [31:0] timestamp,
        input [41:0] savedtime,
        input [255:0] label_text
    );
    begin
        if (loaded_timestamp !== timestamp || loaded_savedtime !== savedtime)
            $fatal(1, "%0s: got timestamp=%08x time=%011x expected=%08x/%011x",
                   label_text, loaded_timestamp, loaded_savedtime,
                   timestamp, savedtime);
    end
    endtask

    initial begin
        // No persisted record: use Pocket's epoch and calendar.
        reset_dut();
        write_record(CART_BASE, 32'hDEAD_BEEF, SIDECAR_TIME);
        finish_load();
        expect_loaded(host_epoch, HOST_TIME, "cart body is not RTC");
        if (stored_record_present)
            $fatal(1, "cart body falsely detected as an RTC record");
        repeat (3) tick();
        if (!load_complete)
            $fatal(1, "RTC persistence completion was not sticky");

        // Legacy 64 KiB footer imports unchanged.
        reset_dut();
        write_record(CART_BASE + 28'h001_0000, 32'h6500_0001, LEGACY_TIME);
        finish_load();
        if (!legacy_record_valid || sidecar_record_valid)
            $fatal(1, "legacy footer validation mismatch");
        expect_loaded(32'h6500_0001, LEGACY_TIME, "legacy 64K footer");
        if (!stored_record_present)
            $fatal(1, "valid legacy footer did not request sidecar migration");

        // The dynamic legacy offset also supports 128 KiB Flash saves.
        reset_dut();
        save_size = 24'h02_0000;
        write_record(CART_BASE + 28'h002_0000, 32'h6500_0002, LEGACY_TIME);
        finish_load();
        expect_loaded(32'h6500_0002, LEGACY_TIME, "legacy 128K footer");

        // A legacy footer is an explicit migration source when both records
        // exist. This covers returning from an older core even if its host
        // clock had moved backwards relative to the prior sidecar.
        reset_dut();
        write_record(CART_BASE + 28'h001_0000, 32'h6500_0010, LEGACY_TIME);
        write_record(RTC_BASE, 32'h6600_0020, SIDECAR_TIME);
        finish_load();
        if (!legacy_record_valid || !sidecar_record_valid)
            $fatal(1, "dual-source records did not validate");
        expect_loaded(32'h6500_0010, LEGACY_TIME, "legacy migration precedence");

        // Both M10K banks accept arbitrary arrival order. Interleave two
        // complete records and scramble every word while preserving legacy
        // migration precedence.
        reset_dut();
        write_word(RTC_BASE + 28'd14, 16'd0);
        write_word(CART_BASE + 28'h001_0006, LEGACY_TIME[31:16]);
        write_word(RTC_BASE + 28'd0, 16'h0021);
        write_word(CART_BASE + 28'h001_000E, 16'd0);
        write_word(RTC_BASE + 28'd8, {6'd0, SIDECAR_TIME[41:32]});
        write_word(CART_BASE + 28'h001_0002, 16'h6500);
        write_word(RTC_BASE + 28'd4, SIDECAR_TIME[15:0]);
        write_word(CART_BASE + 28'h001_000A, 16'd0);
        write_word(RTC_BASE + 28'd12, 16'd0);
        write_word(CART_BASE + 28'h001_0000, 16'h0011);
        write_word(RTC_BASE + 28'd2, 16'h6600);
        write_word(CART_BASE + 28'h001_0008,
                   {6'd0, LEGACY_TIME[41:32]});
        write_word(RTC_BASE + 28'd6, SIDECAR_TIME[31:16]);
        write_word(CART_BASE + 28'h001_0004, LEGACY_TIME[15:0]);
        write_word(RTC_BASE + 28'd10, 16'd0);
        write_word(CART_BASE + 28'h001_000C, 16'd0);
        finish_load();
        if (!legacy_record_valid || !sidecar_record_valid)
            $fatal(1, "interleaved out-of-order records did not validate");
        expect_loaded(32'h6500_0011, LEGACY_TIME,
                      "interleaved legacy precedence");

        // Duplicate data halfwords retain the last accepted value. Reserved
        // and padding errors are intentionally different and remain sticky,
        // as covered by the corrupt-padding scenario below.
        reset_dut();
        write_record(RTC_BASE, 32'h6600_0022, SIDECAR_TIME);
        write_word(RTC_BASE + 28'd0, 16'hDEAD);
        write_word(RTC_BASE + 28'd0, 16'h0022);
        finish_load();
        if (!sidecar_record_valid)
            $fatal(1, "corrected duplicate data word invalidated sidecar");
        expect_loaded(32'h6600_0022, SIDECAR_TIME,
                      "duplicate data last-write wins");

        // The final accepted word may coincide with finalize_load. The read
        // sequencer must still observe the just-written RAM word and commit
        // only after the complete record has been replayed.
        reset_dut();
        write_word(RTC_BASE + 28'd0, 16'h0023);
        write_word(RTC_BASE + 28'd2, 16'h6600);
        write_word(RTC_BASE + 28'd4, SIDECAR_TIME[15:0]);
        write_word(RTC_BASE + 28'd6, SIDECAR_TIME[31:16]);
        write_word(RTC_BASE + 28'd8, {6'd0, SIDECAR_TIME[41:32]});
        write_word(RTC_BASE + 28'd10, 16'd0);
        write_word(RTC_BASE + 28'd12, 16'd0);
        write_word_and_finalize(RTC_BASE + 28'd14, 16'd0);
        if (!sidecar_record_valid)
            $fatal(1, "same-cycle final write/finalize lost sidecar");
        expect_loaded(32'h6600_0023, SIDECAR_TIME,
                      "same-cycle final write and finalize");

        // Force a real same-address write/read collision. Word 0 already
        // exists and is rewritten on the edge that starts replay at address
        // zero. The inferred M10K is allowed to return old data on that edge;
        // READ_WAIT must give it another cycle so the committed record uses
        // the final accepted value.
        reset_dut();
        write_record(RTC_BASE, 32'h6600_DEAD, SIDECAR_TIME);
        write_word_and_finalize(RTC_BASE + 28'd0, 16'h0024);
        if (!sidecar_record_valid)
            $fatal(1, "same-address M10K collision invalidated sidecar");
        expect_loaded(32'h6600_0024, SIDECAR_TIME,
                      "same-address collision last-write wins");

        // Once load_complete is visible, neither stray loader writes nor host
        // input changes may mutate the committed startup snapshot.
        loader_addr = RTC_BASE;
        loader_data = 16'hBEEF;
        loader_accept = 1'b1;
        host_epoch = 32'h1111_2222;
        host_savedtime = DEFAULT_TIME;
        live_timestamp = 32'h3333_4444;
        live_savedtime = LEGACY_TIME;
        finalize_load = 1'b1;
        repeat (3) tick();
        loader_accept = 1'b0;
        finalize_load = 1'b0;
        expect_loaded(32'h6600_0024, SIDECAR_TIME,
                      "completed startup snapshot is immutable");
        if (!load_complete)
            $fatal(1, "post-completion perturbation cleared load_complete");

        // Block RAM is deliberately not reset. Seen bits must prevent the
        // complete record above from leaking into the next partial load.
        reset_dut();
        write_word(RTC_BASE + 28'd2, 16'hFFFF);
        finish_load();
        expect_loaded(host_epoch, HOST_TIME,
                      "reset then partial record ignores stale RAM");
        if (stored_record_present || sidecar_record_valid)
            $fatal(1, "stale M10K contents made a partial sidecar valid");

        // Corrupt sidecar padding falls back to a valid legacy footer and is
        // still marked present so shutdown repairs the 16-byte sidecar.
        reset_dut();
        write_record(CART_BASE + 28'h001_0000, 32'h6500_0030, LEGACY_TIME);
        write_record(RTC_BASE, 32'h6600_0040, SIDECAR_TIME);
        write_word(RTC_BASE + 28'd10, 16'h0001);
        finish_load();
        if (sidecar_record_valid || !legacy_record_valid || !stored_record_present)
            $fatal(1, "corrupt-sidecar recovery state mismatch");
        expect_loaded(32'h6500_0030, LEGACY_TIME,
                      "corrupt sidecar falls back to legacy");

        // A truncated sidecar is ignored and must not count as persistent.
        reset_dut();
        write_word(RTC_BASE, 16'h1234);
        finish_load();
        expect_loaded(host_epoch, HOST_TIME, "truncated sidecar fallback");
        if (stored_record_present)
            $fatal(1, "truncated sidecar was treated as complete");

        // Complete records with erased timestamps, malformed BCD, or reserved
        // bits set are rejected rather than applied to the game clock.
        reset_dut();
        write_record(RTC_BASE, 32'd0, SIDECAR_TIME);
        finish_load();
        expect_loaded(host_epoch, HOST_TIME, "zero sidecar timestamp fallback");
        if (!stored_record_present)
            $fatal(1, "complete invalid sidecar was not retained for repair");

        reset_dut();
        write_record(CART_BASE + 28'h001_0000, 32'd0, LEGACY_TIME);
        finish_load();
        expect_loaded(host_epoch, HOST_TIME, "invalid legacy-only fallback");
        if (stored_record_present)
            $fatal(1, "invalid legacy-only record requested sidecar migration");

        reset_dut();
        write_record(RTC_BASE, 32'h6600_0050,
                     {8'h25, 5'h00, 6'h28, 3'd5, 6'h16, 7'h45, 7'h12});
        finish_load();
        expect_loaded(host_epoch, HOST_TIME, "invalid BCD sidecar fallback");

        // Calendar boundary checks exercise the compact shared validator.
        reset_dut();
        write_record(RTC_BASE, 32'h6600_0051,
                     {8'h24, 5'h02, 6'h29, 3'd4, 6'h23, 7'h59, 7'h59});
        finish_load();
        expect_loaded(32'h6600_0051,
                      {8'h24, 5'h02, 6'h29, 3'd4, 6'h23, 7'h59, 7'h59},
                      "valid leap day sidecar");

        reset_dut();
        write_record(RTC_BASE, 32'h6600_0052,
                     {8'h25, 5'h02, 6'h29, 3'd6, 6'h12, 7'h00, 7'h00});
        finish_load();
        expect_loaded(host_epoch, HOST_TIME, "common-year February 29 fallback");

        reset_dut();
        write_record(RTC_BASE, 32'h6600_0053,
                     {8'h25, 5'h04, 6'h31, 3'd4, 6'h12, 7'h00, 7'h00});
        finish_load();
        expect_loaded(host_epoch, HOST_TIME, "April 31 fallback");

        reset_dut();
        write_record(RTC_BASE, 32'h6600_0054,
                     {8'h25, 5'h08, 6'h05, 3'd2, 6'h24, 7'h00, 7'h00});
        finish_load();
        expect_loaded(host_epoch, HOST_TIME, "hour 24 fallback");

        reset_dut();
        host_savedtime = 42'd0;
        finish_load();
        expect_loaded(host_epoch, DEFAULT_TIME, "invalid Pocket BCD fallback");

        reset_dut();
        host_epoch = 32'd0;
        write_record(RTC_BASE, 32'h6600_0055, SIDECAR_TIME);
        finish_load();
        expect_loaded(32'd0, HOST_TIME, "invalid Pocket epoch gates sidecar");
        if (!sidecar_record_valid)
            $fatal(1, "valid sidecar was not independently recognized");

        // Both invalid host-epoch sentinels gate every persisted source,
        // including a valid legacy footer with otherwise higher precedence.
        reset_dut();
        host_epoch = 32'hFFFF_FFFF;
        write_record(CART_BASE + 28'h001_0000,
                     32'h6500_0056, LEGACY_TIME);
        finish_load();
        expect_loaded(32'hFFFF_FFFF, HOST_TIME,
                      "all-ones host epoch gates legacy");
        if (!legacy_record_valid || !stored_record_present)
            $fatal(1, "valid gated legacy record was not independently recognized");

        reset_dut();
        write_record(CART_BASE + 28'h001_0000, 32'h6500_0060, LEGACY_TIME);
        write_record(RTC_BASE, 32'h6600_0070, SIDECAR_TIME);
        write_word(RTC_BASE + 28'd8, {6'b000001, SIDECAR_TIME[41:32]});
        finish_load();
        expect_loaded(32'h6500_0060, LEGACY_TIME,
                      "reserved sidecar bits fall back to legacy");

        // Snapshot serialization is little-endian and cannot tear if the RTC
        // advances while Pocket is reading the file.
        reset_dut();
        live_timestamp = 32'h1234_ABCD;
        live_savedtime = SIDECAR_TIME;
        unloader_addr = RTC_BASE;
        unloader_accept = 1'b1;
        #1;
        if (unloader_word !== 16'hABCD)
            $fatal(1, "sidecar word 0 did not use live timestamp");
        tick();
        unloader_accept = 1'b0;

        live_timestamp = 32'hFFFF_0000;
        live_savedtime = HOST_TIME;

        unloader_addr = RTC_BASE + 28'd2; #1;
        if (unloader_word !== 16'h1234) $fatal(1, "snapshot timestamp tore");
        unloader_addr = RTC_BASE + 28'd4; #1;
        if (unloader_word !== SIDECAR_TIME[15:0]) $fatal(1, "snapshot time word 0 tore");
        unloader_addr = RTC_BASE + 28'd6; #1;
        if (unloader_word !== SIDECAR_TIME[31:16]) $fatal(1, "snapshot time word 1 tore");
        unloader_addr = RTC_BASE + 28'd8; #1;
        if (unloader_word !== {6'd0, SIDECAR_TIME[41:32]})
            $fatal(1, "snapshot time word 2 tore");
        unloader_addr = RTC_BASE + 28'd10; #1;
        if (unloader_word !== 16'd0) $fatal(1, "sidecar padding word 0 is not zero");
        unloader_addr = RTC_BASE + 28'd12; #1;
        if (unloader_word !== 16'd0) $fatal(1, "sidecar padding word 1 is not zero");
        unloader_addr = RTC_BASE + 28'd14; #1;
        if (unloader_word !== 16'd0) $fatal(1, "sidecar padding word 2 is not zero");

        $display("RTC-PERSISTENCE-TEST PASS");
        $finish;
    end

endmodule

`default_nettype wire
