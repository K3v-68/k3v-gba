//
// cart_quirks.sv - Cart quirk database for GBA
//
// Matches the 4-byte cart ID from ROM[0xAC:0xAF] against the 70 known
// MiSTer-derived quirk records: 26 three-character prefixes and 44 exact IDs.
// The records are scanned from one synchronous M10K instead of building all
// comparisons in parallel logic. A scan takes 70 clocks after the ID is
// accepted; quirks_ready stays high once the accumulated result is complete.
//
// Cart ID format: big-endian (cart_id[31:24] = first char at 0xAC).
// Record format: {prefix_match, key[31:0], six quirk flags}.
// Prefix records ignore key[7:0]. Independent matches are ORed so a future
// overlapping prefix/exact pair preserves the original union semantics.
//
// SPDX-License-Identifier: GPL-2.0-or-later
//

`default_nettype none

module cart_quirks (
    input  wire        clk,
    input  wire        reset,
    input  wire [31:0] cart_id,
    input  wire        valid,

    output reg         quirks_ready,
    output reg         sram_quirk,
    output reg         gpio_quirk,
    output reg         tilt_quirk,
    output reg         solar_quirk,
    output reg         memory_remap,
    output reg         sprite_quirk
);

    localparam integer ENTRY_COUNT = 70;
    localparam [6:0] LAST_ENTRY = ENTRY_COUNT - 1;

    // {is_prefix, key, sram, gpio, tilt, solar, memory_remap, sprite}
    // 70 x 39 fits in one M10K. The forced style makes the intended ALM/M10K
    // trade explicit and prevents Quartus from flattening the table to logic.
    (* ramstyle = "M10K, no_rw_check" *) reg [38:0] quirk_rom [0:ENTRY_COUNT-1];

    initial begin
        // Three-character prefix matches.
        quirk_rom[ 0] = {1'b1, "AR8", 8'h00, 6'b100000};
        quirk_rom[ 1] = {1'b1, "ARO", 8'h00, 6'b100000};
        quirk_rom[ 2] = {1'b1, "ALG", 8'h00, 6'b100000};
        quirk_rom[ 3] = {1'b1, "ALF", 8'h00, 6'b100000};
        quirk_rom[ 4] = {1'b1, "BLF", 8'h00, 6'b100000};
        quirk_rom[ 5] = {1'b1, "BDB", 8'h00, 6'b100000};
        quirk_rom[ 6] = {1'b1, "BG3", 8'h00, 6'b100000};
        quirk_rom[ 7] = {1'b1, "BDV", 8'h00, 6'b100000};
        quirk_rom[ 8] = {1'b1, "A2Y", 8'h00, 6'b100000};
        quirk_rom[ 9] = {1'b1, "AI2", 8'h00, 6'b100000};
        quirk_rom[10] = {1'b1, "BT4", 8'h00, 6'b100000};
        quirk_rom[11] = {1'b1, "BPE", 8'h00, 6'b010000};
        quirk_rom[12] = {1'b1, "AXV", 8'h00, 6'b010000};
        quirk_rom[13] = {1'b1, "AXP", 8'h00, 6'b010000};
        quirk_rom[14] = {1'b1, "RZW", 8'h00, 6'b010000};
        quirk_rom[15] = {1'b1, "BKA", 8'h00, 6'b010000};
        quirk_rom[16] = {1'b1, "BR4", 8'h00, 6'b010000};
        quirk_rom[17] = {1'b1, "V49", 8'h00, 6'b010000};
        quirk_rom[18] = {1'b1, "2GB", 8'h00, 6'b010000};
        quirk_rom[19] = {1'b1, "BHG", 8'h00, 6'b000001};
        quirk_rom[20] = {1'b1, "BGX", 8'h00, 6'b000001};
        quirk_rom[21] = {1'b1, "KHP", 8'h00, 6'b001000};
        quirk_rom[22] = {1'b1, "KYG", 8'h00, 6'b001000};
        quirk_rom[23] = {1'b1, "U3I", 8'h00, 6'b010100};
        quirk_rom[24] = {1'b1, "U32", 8'h00, 6'b010100};
        quirk_rom[25] = {1'b1, "U33", 8'h00, 6'b010100};

        // Four-character exact matches.
        quirk_rom[26] = {1'b0, "FBME", 6'b100010};
        quirk_rom[27] = {1'b0, "FADE", 6'b100010};
        quirk_rom[28] = {1'b0, "FDKE", 6'b100010};
        quirk_rom[29] = {1'b0, "FDME", 6'b100010};
        quirk_rom[30] = {1'b0, "FEBE", 6'b100010};
        quirk_rom[31] = {1'b0, "FICE", 6'b100010};
        quirk_rom[32] = {1'b0, "FMRE", 6'b100010};
        quirk_rom[33] = {1'b0, "FP7E", 6'b100010};
        quirk_rom[34] = {1'b0, "FSME", 6'b100010};
        quirk_rom[35] = {1'b0, "FZLE", 6'b100010};
        quirk_rom[36] = {1'b0, "FXVE", 6'b100010};
        quirk_rom[37] = {1'b0, "FLBE", 6'b100010};
        quirk_rom[38] = {1'b0, "FSRJ", 6'b100010};
        quirk_rom[39] = {1'b0, "FGZJ", 6'b100010};
        quirk_rom[40] = {1'b0, "FSDJ", 6'b100011};
        quirk_rom[41] = {1'b0, "FADJ", 6'b100011};
        quirk_rom[42] = {1'b0, "FTUJ", 6'b100001};
        quirk_rom[43] = {1'b0, "FTKJ", 6'b100001};
        quirk_rom[44] = {1'b0, "FFMJ", 6'b100001};
        quirk_rom[45] = {1'b0, "FLBJ", 6'b100001};
        quirk_rom[46] = {1'b0, "FPTJ", 6'b100001};
        quirk_rom[47] = {1'b0, "FMRJ", 6'b100001};
        quirk_rom[48] = {1'b0, "FNMJ", 6'b100001};
        quirk_rom[49] = {1'b0, "FM2J", 6'b100011};
        quirk_rom[50] = {1'b0, "FGGJ", 6'b100010};
        quirk_rom[51] = {1'b0, "FTWJ", 6'b100010};
        quirk_rom[52] = {1'b0, "FMKJ", 6'b100010};
        quirk_rom[53] = {1'b0, "FTBJ", 6'b100010};
        quirk_rom[54] = {1'b0, "FDDJ", 6'b100010};
        quirk_rom[55] = {1'b0, "FDMJ", 6'b100010};
        quirk_rom[56] = {1'b0, "FWCJ", 6'b100010};
        quirk_rom[57] = {1'b0, "FVFJ", 6'b100010};
        quirk_rom[58] = {1'b0, "FCLJ", 6'b100010};
        quirk_rom[59] = {1'b0, "FMBJ", 6'b100010};
        quirk_rom[60] = {1'b0, "FSOJ", 6'b100010};
        quirk_rom[61] = {1'b0, "FBMJ", 6'b100010};
        quirk_rom[62] = {1'b0, "FMPJ", 6'b100010};
        quirk_rom[63] = {1'b0, "FXVJ", 6'b100010};
        quirk_rom[64] = {1'b0, "FPMJ", 6'b100010};
        quirk_rom[65] = {1'b0, "FZLJ", 6'b100010};
        quirk_rom[66] = {1'b0, "FEBJ", 6'b100010};
        quirk_rom[67] = {1'b0, "FICJ", 6'b100010};
        quirk_rom[68] = {1'b0, "FDKJ", 6'b100010};
        quirk_rom[69] = {1'b0, "FSMJ", 6'b100010};
    end

    reg [31:0] cart_id_latched;
    reg [6:0]  scan_index;
    reg [38:0] rom_record;
    reg        scanning;

    // While idle, keep entry zero prefetched. During a scan, issue the record
    // after the one currently in rom_record. Holding LAST_ENTRY on the final
    // cycle avoids an out-of-range speculative read without a second counter.
    wire [6:0] rom_read_addr = !scanning ? 7'd0
                             : (scan_index < LAST_ENTRY
                                ? scan_index + 7'd1 : LAST_ENTRY);

    // Synchronous read is required for block-ROM inference.
    always @(posedge clk)
        rom_record <= quirk_rom[rom_read_addr];

    wire record_matches = rom_record[38]
                        ? (cart_id_latched[31:8] == rom_record[37:14])
                        : (cart_id_latched       == rom_record[37:6]);

    always @(posedge clk) begin
        if (reset) begin
            cart_id_latched <= 32'd0;
            scan_index      <= 7'd0;
            scanning        <= 1'b0;
            quirks_ready    <= 1'b0;
            sram_quirk      <= 1'b0;
            gpio_quirk      <= 1'b0;
            tilt_quirk      <= 1'b0;
            solar_quirk     <= 1'b0;
            memory_remap    <= 1'b0;
            sprite_quirk    <= 1'b0;
        end else if (!scanning && !quirks_ready && valid) begin
            // valid may remain high indefinitely; accept the ID exactly once.
            cart_id_latched <= cart_id;
            scan_index      <= 7'd0;
            scanning        <= 1'b1;
            sram_quirk      <= 1'b0;
            gpio_quirk      <= 1'b0;
            tilt_quirk      <= 1'b0;
            solar_quirk     <= 1'b0;
            memory_remap    <= 1'b0;
            sprite_quirk    <= 1'b0;
        end else if (scanning) begin
            if (record_matches) begin
                sram_quirk   <= sram_quirk   | rom_record[5];
                gpio_quirk   <= gpio_quirk   | rom_record[4];
                tilt_quirk   <= tilt_quirk   | rom_record[3];
                solar_quirk  <= solar_quirk  | rom_record[2];
                memory_remap <= memory_remap | rom_record[1];
                sprite_quirk <= sprite_quirk | rom_record[0];
            end

            if (scan_index == LAST_ENTRY) begin
                scanning     <= 1'b0;
                quirks_ready <= 1'b1;
            end else begin
                scan_index <= scan_index + 7'd1;
            end
        end
    end

endmodule

`default_nettype wire
