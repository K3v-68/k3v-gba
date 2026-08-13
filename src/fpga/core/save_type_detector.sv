//
// save_type_detector.sv - Detect save type from ROM download stream
//
// Watches accepted ROM halfwords and recognizes "FLASH1M_V" with a compact
// streaming matcher. Each rom_wr contributes the low byte followed by the high
// byte; idle gaps and rom_addr discontinuities do not break the byte stream.
// This preserves the MiSTer detector's two possible byte alignments without a
// 64-bit history register and two wide comparisons.
//
// Also captures the cart ID from ROM header bytes 0xAC-0xAF during download,
// matching the MiSTer GBA implementation.
//
// SPDX-License-Identifier: GPL-2.0-or-later
//

`default_nettype none

module save_type_detector (
    input  wire        clk,
    input  wire        reset,

    // ROM download stream (from data_loader, active during boot)
    input  wire        rom_wr,
    input  wire [15:0] rom_data,
    input  wire [27:0] rom_addr,

    output reg         flash_1m,

    // Cart ID captured from ROM header at byte offset 0xAC-0xAF.
    // Stored big-endian (MiSTer-compatible) for cart_quirks matching.
    output reg  [31:0] cart_id,
    output reg         cart_id_valid
);

    // Number of leading "FLASH1M_V" bytes already matched (0..8). The pattern
    // has no proper prefix longer than its initial 'F', so a mismatch falls
    // back to state 1 only when the current byte is another 'F'. Bit 4 of the
    // function result pulses when the final 'V' is consumed; bits 3:0 carry
    // the next prefix length. This is the KMP fallback specialized to the one
    // signature and keeps both incoming bytes in the same accepted cycle.
    reg [3:0] flash_match_len;

    function automatic [4:0] flash_match_step;
        input [3:0] state;
        input [7:0] byte_in;
        begin
            // Pack the expected character and next state into one small
            // state-indexed lookup. This is one byte comparison per matcher
            // step, rather than a bank of parallel character comparisons.
            case (state)
                4'd0: flash_match_step = (byte_in == "F")
                    ? {1'b0, 4'd1} : {1'b0, 4'd0};
                4'd1: flash_match_step = (byte_in == "L")
                    ? {1'b0, 4'd2} : {1'b0, (byte_in == "F") ? 4'd1 : 4'd0};
                4'd2: flash_match_step = (byte_in == "A")
                    ? {1'b0, 4'd3} : {1'b0, (byte_in == "F") ? 4'd1 : 4'd0};
                4'd3: flash_match_step = (byte_in == "S")
                    ? {1'b0, 4'd4} : {1'b0, (byte_in == "F") ? 4'd1 : 4'd0};
                4'd4: flash_match_step = (byte_in == "H")
                    ? {1'b0, 4'd5} : {1'b0, (byte_in == "F") ? 4'd1 : 4'd0};
                4'd5: flash_match_step = (byte_in == "1")
                    ? {1'b0, 4'd6} : {1'b0, (byte_in == "F") ? 4'd1 : 4'd0};
                4'd6: flash_match_step = (byte_in == "M")
                    ? {1'b0, 4'd7} : {1'b0, (byte_in == "F") ? 4'd1 : 4'd0};
                4'd7: flash_match_step = (byte_in == "_")
                    ? {1'b0, 4'd8} : {1'b0, (byte_in == "F") ? 4'd1 : 4'd0};
                4'd8: flash_match_step = (byte_in == "V")
                    ? {1'b1, 4'd0} : {1'b0, (byte_in == "F") ? 4'd1 : 4'd0};
                default: flash_match_step = {1'b0, 4'd0};
            endcase
        end
    endfunction

    wire [4:0] match_after_low  = flash_match_step(flash_match_len, rom_data[7:0]);
    wire [4:0] match_after_high = flash_match_step(match_after_low[3:0], rom_data[15:8]);

    always @(posedge clk) begin
        if (reset) begin
            flash_match_len <= 4'd0;
            flash_1m        <= 1'b0;
            cart_id         <= 32'd0;
            cart_id_valid   <= 1'b0;
        end else if (rom_wr) begin
            flash_match_len <= match_after_high[3:0];
            if (match_after_low[4] || match_after_high[4])
                flash_1m <= 1'b1;

            // ROM header bytes 0xAC-0xAF contain the four-character game code.
            // Accepted halfwords at 0xAC and 0xAE are byte-swapped into the
            // big-endian representation used by the quirk table.
            if (rom_addr[27:4] == 24'hA) begin
                if (rom_addr[3:0] >= 4'hC)
                    cart_id[{4'hE - rom_addr[3:0], 3'd0} +: 16]
                        <= {rom_data[7:0], rom_data[15:8]};
            end

            // Preserve MiSTer's readiness contract: this sticky level rises
            // on the first accepted halfword at or beyond byte address 0xB0.
            if (rom_addr >= 28'hB0)
                cart_id_valid <= 1'b1;
        end
    end

endmodule

`default_nettype wire
