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

    reg [31:0] sidecar_timestamp;
    reg [41:0] sidecar_savedtime;
    reg [5:0]  sidecar_reserved;
    reg [47:0] sidecar_padding;
    reg [7:0]  sidecar_word_seen;

    reg [31:0] legacy_timestamp;
    reg [41:0] legacy_savedtime;
    reg [5:0]  legacy_reserved;
    reg [47:0] legacy_padding;
    reg [7:0]  legacy_word_seen;

    reg [31:0] unload_timestamp_snapshot;
    reg [41:0] unload_savedtime_snapshot;

    wire loader_is_save = loader_addr[27:24] == SAVE_SLOT_REGION;
    wire loader_is_rtc  = loader_addr[27:24] == RTC_SLOT_REGION;
    wire [23:0] loader_offset = loader_addr[23:0];
    wire [23:0] legacy_offset = loader_offset - save_size;

    wire unloader_is_rtc = unloader_addr[27:24] == RTC_SLOT_REGION;
    wire [23:0] unloader_offset = unloader_addr[23:0];

    function automatic integer days_in_month(input integer year_value,
                                               input integer month_value);
    begin
        case (month_value)
            1, 3, 5, 7, 8, 10, 12: days_in_month = 31;
            4, 6, 9, 11:            days_in_month = 30;
            2: days_in_month = ((year_value % 4) == 0) ? 29 : 28;
            default: days_in_month = 0;
        endcase
    end
    endfunction

    function automatic bcd_time_valid(input [41:0] value);
        integer year_value;
        integer month_value;
        integer day_value;
        integer wday_value;
        integer hour_value;
        integer minute_value;
        integer second_value;
    begin
        year_value   = (value[41:38] * 10) + value[37:34];
        month_value  = (value[33] * 10) + value[32:29];
        day_value    = (value[28:27] * 10) + value[26:23];
        wday_value   = value[22:20];
        hour_value   = (value[19:18] * 10) + value[17:14];
        minute_value = (value[13:11] * 10) + value[10:7];
        second_value = (value[6:4] * 10) + value[3:0];

        bcd_time_valid =
            (value[41:38] <= 9) && (value[37:34] <= 9) &&
            (value[32:29] <= 9) &&
            (value[28:27] <= 3) && (value[26:23] <= 9) &&
            (value[19:18] <= 2) && (value[17:14] <= 9) &&
            (value[13:11] <= 5) && (value[10:7] <= 9) &&
            (value[6:4] <= 5) && (value[3:0] <= 9) &&
            (month_value >= 1) && (month_value <= 12) &&
            (day_value >= 1) &&
            (day_value <= days_in_month(year_value, month_value)) &&
            (wday_value <= 6) && (hour_value <= 23) &&
            (minute_value <= 59) && (second_value <= 59);
    end
    endfunction

    wire host_epoch_valid = (host_epoch != 32'd0) &&
                            (host_epoch != 32'hFFFF_FFFF);

    assign sidecar_record_valid =
        (sidecar_word_seen == 8'hFF) &&
        (sidecar_reserved == 6'd0) && (sidecar_padding == 48'd0) &&
        (sidecar_timestamp != 32'd0) &&
        (sidecar_timestamp != 32'hFFFF_FFFF) &&
        bcd_time_valid(sidecar_savedtime);

    assign legacy_record_valid =
        (legacy_word_seen == 8'hFF) &&
        (legacy_reserved == 6'd0) && (legacy_padding == 48'd0) &&
        (legacy_timestamp != 32'd0) &&
        (legacy_timestamp != 32'hFFFF_FFFF) &&
        bcd_time_valid(legacy_savedtime);

    // A complete sidecar is preserved even if its contents are invalid: the
    // Pocket-clock fallback will repair it on the next clean shutdown.
    assign stored_record_present = (sidecar_word_seen == 8'hFF) ||
                                   legacy_record_valid;

    always @(posedge clk) begin
        if (!reset_n) begin
            sidecar_timestamp <= 32'd0;
            sidecar_savedtime <= 42'd0;
            sidecar_reserved  <= 6'd0;
            sidecar_padding   <= 48'd0;
            sidecar_word_seen <= 8'd0;

            legacy_timestamp <= 32'd0;
            legacy_savedtime <= 42'd0;
            legacy_reserved  <= 6'd0;
            legacy_padding   <= 48'd0;
            legacy_word_seen <= 8'd0;

            loaded_timestamp <= 32'd0;
            loaded_savedtime <= 42'd0;
            load_complete    <= 1'b0;
        end else begin
            if (loader_accept && loader_is_rtc) begin
                case (loader_offset)
                    24'd0:  begin sidecar_timestamp[15:0]  <= loader_data; sidecar_word_seen[0] <= 1'b1; end
                    24'd2:  begin sidecar_timestamp[31:16] <= loader_data; sidecar_word_seen[1] <= 1'b1; end
                    24'd4:  begin sidecar_savedtime[15:0]  <= loader_data; sidecar_word_seen[2] <= 1'b1; end
                    24'd6:  begin sidecar_savedtime[31:16] <= loader_data; sidecar_word_seen[3] <= 1'b1; end
                    24'd8:  begin
                        sidecar_savedtime[41:32] <= loader_data[9:0];
                        sidecar_reserved <= loader_data[15:10];
                        sidecar_word_seen[4] <= 1'b1;
                    end
                    24'd10: begin sidecar_padding[15:0]  <= loader_data; sidecar_word_seen[5] <= 1'b1; end
                    24'd12: begin sidecar_padding[31:16] <= loader_data; sidecar_word_seen[6] <= 1'b1; end
                    24'd14: begin sidecar_padding[47:32] <= loader_data; sidecar_word_seen[7] <= 1'b1; end
                    default: ;
                endcase
            end

            if (loader_accept && loader_is_save &&
                (loader_offset >= save_size) &&
                (loader_offset < save_size + 24'd16)) begin
                case (legacy_offset)
                    24'd0:  begin legacy_timestamp[15:0]  <= loader_data; legacy_word_seen[0] <= 1'b1; end
                    24'd2:  begin legacy_timestamp[31:16] <= loader_data; legacy_word_seen[1] <= 1'b1; end
                    24'd4:  begin legacy_savedtime[15:0]  <= loader_data; legacy_word_seen[2] <= 1'b1; end
                    24'd6:  begin legacy_savedtime[31:16] <= loader_data; legacy_word_seen[3] <= 1'b1; end
                    24'd8:  begin
                        legacy_savedtime[41:32] <= loader_data[9:0];
                        legacy_reserved <= loader_data[15:10];
                        legacy_word_seen[4] <= 1'b1;
                    end
                    24'd10: begin legacy_padding[15:0]  <= loader_data; legacy_word_seen[5] <= 1'b1; end
                    24'd12: begin legacy_padding[31:16] <= loader_data; legacy_word_seen[6] <= 1'b1; end
                    24'd14: begin legacy_padding[47:32] <= loader_data; legacy_word_seen[7] <= 1'b1; end
                    default: ;
                endcase
            end

            if (!load_complete && finalize_load) begin
                // A footer can only be produced by an older core. Treat it as
                // an explicit migration source when both records exist. This
                // also preserves RTC changes made after temporarily returning
                // to v0.1.2, even if the host clock moved backwards.
                if (host_epoch_valid && legacy_record_valid) begin
                    loaded_timestamp <= legacy_timestamp;
                    loaded_savedtime <= legacy_savedtime;
                end else if (host_epoch_valid && sidecar_record_valid) begin
                    loaded_timestamp <= sidecar_timestamp;
                    loaded_savedtime <= sidecar_savedtime;
                end else begin
                    loaded_timestamp <= host_epoch;
                    loaded_savedtime <= bcd_time_valid(host_savedtime) ?
                                        host_savedtime : DEFAULT_SAVEDTIME;
                end
                load_complete <= 1'b1;
            end
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
