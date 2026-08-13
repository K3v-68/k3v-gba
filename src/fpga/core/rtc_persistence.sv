// K3V GBA RTC persistence record handling.
//
// Pocket presents the cartridge save and RTC sidecar through two addresses in
// the same 0x2xxxxxxx bridge window.  This module owns only the 16-byte RTC
// record: it captures the new sidecar, imports the legacy save footer, selects
// the best valid source, and serializes a coherent live record on shutdown.

`timescale 1ns/1ps
`default_nettype none

module rtc_persistence #(
    parameter [3:0] SAVE_SLOT_REGION = 4'h0,
    parameter [3:0] RTC_SLOT_REGION  = 4'h1
) (
    input  wire        clk,
    input  wire        reset_n,

    input  wire        loader_accept,
    input  wire [27:0] loader_addr,
    input  wire [15:0] loader_data,
    input  wire [23:0] save_size,

    input  wire        finalize_load,
    input  wire [31:0] host_epoch,
    input  wire [41:0] host_savedtime,

    output reg  [31:0] loaded_timestamp,
    output reg  [41:0] loaded_savedtime,
    output reg         load_complete,
    output wire        stored_record_present,
    output wire        sidecar_record_valid,
    output wire        legacy_record_valid,

    input  wire        unloader_accept,
    input  wire [27:0] unloader_addr,
    input  wire [31:0] live_timestamp,
    input  wire [41:0] live_savedtime,
    output reg  [15:0] unloader_word
);

    localparam [41:0] DEFAULT_SAVEDTIME =
        {8'h00, 5'h01, 6'h01, 3'd0, 6'h00, 7'h00, 7'h00};

    reg        sidecar_format_error;
    reg [7:0]  sidecar_word_seen;

    reg        legacy_format_error;
    reg [7:0]  legacy_word_seen;

    // Both records are consumed only after Pocket finishes loading all data
    // slots. Keep their accepted halfwords in one M10K and replay one source
    // at a time through the shared boot validator. Seen/error bits remain in
    // registers so stale, uncleared RAM can never make a partial record valid.
    localparam RECORD_BANK_SIDECAR = 1'b0;
    localparam RECORD_BANK_LEGACY  = 1'b1;
    (* ramstyle = "M10K, no_rw_check" *) reg [15:0] record_ram [0:15];
    reg [3:0]  record_read_addr;
    reg [15:0] record_read_data;

    reg        sidecar_record_valid_r;
    reg        legacy_record_valid_r;
    reg [2:0]  validation_state;
    reg [1:0]  load_phase;
    reg [2:0]  read_word_index;
    reg        host_savedtime_valid_r;

    reg [31:0] unload_timestamp_snapshot;
    reg [41:0] unload_savedtime_snapshot;

    wire loader_is_save = loader_addr[27:24] == SAVE_SLOT_REGION;
    wire loader_is_rtc  = loader_addr[27:24] == RTC_SLOT_REGION;
    wire [23:0] loader_offset = loader_addr[23:0];
    wire [23:0] legacy_offset = loader_offset - save_size;

    wire sidecar_word_accept = loader_accept && loader_is_rtc &&
        (loader_offset[23:4] == 20'd0) && !loader_offset[0];
    wire legacy_word_accept = loader_accept && loader_is_save &&
        (loader_offset >= save_size) &&
        (loader_offset < save_size + 24'd16) && !legacy_offset[0];
    wire [2:0] accepted_word_index = legacy_word_accept ?
        legacy_offset[3:1] : loader_offset[3:1];
    wire [3:0] record_write_addr = {
        legacy_word_accept ? RECORD_BANK_LEGACY : RECORD_BANK_SIDECAR,
        accepted_word_index
    };
    wire record_write_en = sidecar_word_accept || legacy_word_accept;

    wire unloader_is_rtc = unloader_addr[27:24] == RTC_SLOT_REGION;
    wire [23:0] unloader_offset = unloader_addr[23:0];

    function automatic bcd_time_valid(input [41:0] value);
        reg [1:0] leap_mod4;
        reg       leap_year;
        reg       year_valid;
        reg       month_valid;
        reg       month_is_february;
        reg       month_has_30_days;
        reg       day_valid;
        reg       hms_valid;
    begin
        // 2000..2099 leap years depend only on the two BCD year digits.
        // 10*tens + ones modulo four is 2*tens + ones modulo four.
        leap_mod4 = {value[38], 1'b0} + value[35:34];
        leap_year = leap_mod4 == 2'b00;

        year_valid = (value[41:38] <= 4'd9) &&
                     (value[37:34] <= 4'd9);
        month_valid = (!value[33] && value[32:29] >= 4'd1 &&
                       value[32:29] <= 4'd9) ||
                      (value[33] && value[32:29] <= 4'd2);
        month_is_february = !value[33] && value[32:29] == 4'd2;
        month_has_30_days = (!value[33] &&
                             (value[32:29] == 4'd4 ||
                              value[32:29] == 4'd6 ||
                              value[32:29] == 4'd9)) ||
                            (value[33] && value[32:29] == 4'd1);

        day_valid = (value[26:23] <= 4'd9) &&
                    (value[28:23] != 6'd0);
        if (month_is_february)
            day_valid = day_valid &&
                        ((value[28:27] < 2'd2) ||
                         (value[28:27] == 2'd2 &&
                          value[26:23] <= (leap_year ? 4'd9 : 4'd8)));
        else if (month_has_30_days)
            day_valid = day_valid &&
                        ((value[28:27] < 2'd3) ||
                         (value[28:27] == 2'd3 && value[26:23] == 4'd0));
        else
            day_valid = day_valid &&
                        ((value[28:27] < 2'd3) ||
                         (value[28:27] == 2'd3 && value[26:23] <= 4'd1));

        hms_valid = (value[17:14] <= 4'd9) &&
                    ((value[19:18] < 2'd2) ||
                     (value[19:18] == 2'd2 && value[17:14] <= 4'd3)) &&
                    (value[13:11] <= 3'd5) && (value[10:7] <= 4'd9) &&
                    (value[6:4] <= 3'd5) && (value[3:0] <= 4'd9);

        bcd_time_valid = year_valid && month_valid && day_valid &&
                         (value[22:20] <= 3'd6) && hms_valid;
    end
    endfunction

    wire host_epoch_valid = (host_epoch != 32'd0) &&
                            (host_epoch != 32'hFFFF_FFFF);

    localparam [2:0] VALIDATE_IDLE         = 3'd0;
    localparam [2:0] VALIDATE_READ_WAIT    = 3'd1;
    localparam [2:0] VALIDATE_READ_CAPTURE = 3'd2;
    localparam [2:0] VALIDATE_RECORD       = 3'd3;
    localparam [2:0] VALIDATE_HOST         = 3'd4;
    localparam [2:0] VALIDATE_SELECT       = 3'd5;
    localparam [2:0] VALIDATE_DONE         = 3'd6;

    localparam [1:0] LOAD_SIDECAR   = 2'd0;
    localparam [1:0] LOAD_LEGACY    = 2'd1;
    localparam [1:0] RELOAD_SIDECAR = 2'd2;

    wire sidecar_record_complete = sidecar_word_seen == 8'hFF;
    wire legacy_record_complete  = legacy_word_seen == 8'hFF;
    wire loaded_timestamp_shape_valid = (loaded_timestamp != 32'd0) &&
        (loaded_timestamp != 32'hFFFF_FFFF);
    // Keep one calendar validator: loaded_* holds each persisted candidate in
    // turn, then the same logic checks Pocket's host calendar.
    wire [41:0] validation_savedtime =
        (validation_state == VALIDATE_HOST) ?
            host_savedtime : loaded_savedtime;
    wire validation_bcd_valid = bcd_time_valid(validation_savedtime);

    assign sidecar_record_valid = sidecar_record_valid_r;
    assign legacy_record_valid  = legacy_record_valid_r;

    // A complete sidecar is preserved even if its contents are invalid: the
    // Pocket-clock fallback will repair it on the next clean shutdown.
    assign stored_record_present = sidecar_record_complete ||
                                   legacy_record_valid;

    // Simple dual-port inference: loader writes use one port and the boot-only
    // sequencer uses the synchronous read port. core_top does not finalize
    // until the shared ingress is drained, so normal operation cannot collide.
    always @(posedge clk) begin
        if (reset_n && record_write_en)
            record_ram[record_write_addr] <= loader_data;
        record_read_data <= record_ram[record_read_addr];
    end

    always @(posedge clk) begin
        if (!reset_n) begin
            sidecar_format_error <= 1'b0;
            sidecar_word_seen <= 8'd0;

            legacy_format_error <= 1'b0;
            legacy_word_seen <= 8'd0;

            sidecar_record_valid_r <= 1'b0;
            legacy_record_valid_r  <= 1'b0;
            validation_state       <= VALIDATE_IDLE;
            load_phase             <= LOAD_SIDECAR;
            read_word_index        <= 3'd0;
            record_read_addr       <= {RECORD_BANK_SIDECAR, 3'd0};
            host_savedtime_valid_r <= 1'b0;

            loaded_timestamp <= 32'd0;
            loaded_savedtime <= 42'd0;
            load_complete    <= 1'b0;
        end else begin
            if (sidecar_word_accept) begin
                sidecar_word_seen[accepted_word_index] <= 1'b1;
                if ((accepted_word_index == 3'd4 &&
                     loader_data[15:10] != 6'd0) ||
                    (accepted_word_index >= 3'd5 && loader_data != 16'd0))
                    sidecar_format_error <= 1'b1;
            end

            if (legacy_word_accept) begin
                legacy_word_seen[accepted_word_index] <= 1'b1;
                if ((accepted_word_index == 3'd4 &&
                     loader_data[15:10] != 6'd0) ||
                    (accepted_word_index >= 3'd5 && loader_data != 16'd0))
                    legacy_format_error <= 1'b1;
            end

            case (validation_state)
                VALIDATE_IDLE: begin
                    if (finalize_load) begin
                        // loaded_* are scratch until load_complete. core_top
                        // waits for that flag before the live RTC consumes them.
                        load_phase       <= LOAD_SIDECAR;
                        read_word_index  <= 3'd0;
                        record_read_addr <= {RECORD_BANK_SIDECAR, 3'd0};
                        validation_state <= VALIDATE_READ_WAIT;
                    end
                end

                // record_read_data is registered. Hold each address for one
                // full clock before consuming it in READ_CAPTURE.
                VALIDATE_READ_WAIT: begin
                    validation_state <= VALIDATE_READ_CAPTURE;
                end

                VALIDATE_READ_CAPTURE: begin
                    case (read_word_index)
                        3'd0: loaded_timestamp[15:0]  <= record_read_data;
                        3'd1: loaded_timestamp[31:16] <= record_read_data;
                        3'd2: loaded_savedtime[15:0]  <= record_read_data;
                        3'd3: loaded_savedtime[31:16] <= record_read_data;
                        default:
                            loaded_savedtime[41:32] <= record_read_data[9:0];
                    endcase

                    if (read_word_index == 3'd4) begin
                        if (load_phase == RELOAD_SIDECAR) begin
                            // Final word and completion become visible on the
                            // same edge, so consumers cannot observe tearing.
                            load_complete    <= 1'b1;
                            validation_state <= VALIDATE_DONE;
                        end else begin
                            validation_state <= VALIDATE_RECORD;
                        end
                    end else begin
                        read_word_index <= read_word_index + 3'd1;
                        record_read_addr <= {
                            (load_phase == LOAD_LEGACY) ?
                                RECORD_BANK_LEGACY : RECORD_BANK_SIDECAR,
                            read_word_index + 3'd1
                        };
                        validation_state <= VALIDATE_READ_WAIT;
                    end
                end

                VALIDATE_RECORD: begin
                    if (load_phase == LOAD_SIDECAR) begin
                        sidecar_record_valid_r <= sidecar_record_complete &&
                            !sidecar_format_error &&
                            loaded_timestamp_shape_valid &&
                            validation_bcd_valid;
                        load_phase       <= LOAD_LEGACY;
                        read_word_index  <= 3'd0;
                        record_read_addr <= {RECORD_BANK_LEGACY, 3'd0};
                        validation_state <= VALIDATE_READ_WAIT;
                    end else begin
                        legacy_record_valid_r <= legacy_record_complete &&
                            !legacy_format_error &&
                            loaded_timestamp_shape_valid &&
                            validation_bcd_valid;
                        validation_state <= VALIDATE_HOST;
                    end
                end

                VALIDATE_HOST: begin
                    host_savedtime_valid_r <= validation_bcd_valid;
                    validation_state <= VALIDATE_SELECT;
                end

                VALIDATE_SELECT: begin
                    // A footer can only be produced by an older core. Treat it
                    // as an explicit migration source when both records exist.
                    // This also preserves changes made after returning to
                    // v0.1.2, even if the host clock moved backwards.
                    if (host_epoch_valid && legacy_record_valid_r) begin
                        // The legacy record is already in loaded_*.
                        load_complete <= 1'b1;
                        validation_state <= VALIDATE_DONE;
                    end else if (host_epoch_valid && sidecar_record_valid_r) begin
                        // Legacy validation reused the scratch registers, so
                        // replay the validated sidecar before committing it.
                        load_phase       <= RELOAD_SIDECAR;
                        read_word_index  <= 3'd0;
                        record_read_addr <= {RECORD_BANK_SIDECAR, 3'd0};
                        validation_state <= VALIDATE_READ_WAIT;
                    end else begin
                        loaded_timestamp <= host_epoch;
                        loaded_savedtime <= host_savedtime_valid_r ?
                                            host_savedtime : DEFAULT_SAVEDTIME;
                        load_complete <= 1'b1;
                        validation_state <= VALIDATE_DONE;
                    end
                end
                default: ;
            endcase
        end
    end

    // Capture live fields at the first sidecar halfword.  Word zero must use
    // the live input directly because nonblocking snapshot updates take effect
    // after that same accepted request; all later words use the snapshot.
    always @(posedge clk) begin
        if (!reset_n) begin
            unload_timestamp_snapshot <= 32'd0;
            unload_savedtime_snapshot <= 42'd0;
        end else if (unloader_accept && unloader_is_rtc &&
                     unloader_offset == 24'd0) begin
            unload_timestamp_snapshot <= live_timestamp;
            unload_savedtime_snapshot <= live_savedtime;
        end
    end

    always @(*) begin
        case (unloader_offset[3:1])
            3'd0: unloader_word = live_timestamp[15:0];
            3'd1: unloader_word = unload_timestamp_snapshot[31:16];
            3'd2: unloader_word = unload_savedtime_snapshot[15:0];
            3'd3: unloader_word = unload_savedtime_snapshot[31:16];
            3'd4: unloader_word = {6'b0, unload_savedtime_snapshot[41:32]};
            default: unloader_word = 16'd0;
        endcase
    end

endmodule

`default_nettype wire
