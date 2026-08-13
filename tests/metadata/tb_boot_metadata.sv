`timescale 1ns/1ps
`default_nettype none

module tb_boot_metadata;

    localparam integer PREFIX_COUNT = 26;
    localparam integer EXACT_COUNT  = 44;
    localparam integer RECORD_COUNT = PREFIX_COUNT + EXACT_COUNT;
    localparam [71:0] FLASH_SIGNATURE = "FLASH1M_V";

    // Flag order used by the independent oracle:
    // {sram, gpio, tilt, solar, memory_remap, sprite}.
    reg [23:0] prefix_key   [0:PREFIX_COUNT-1];
    reg [5:0]  prefix_value [0:PREFIX_COUNT-1];
    reg [31:0] exact_key    [0:EXACT_COUNT-1];
    reg [5:0]  exact_value  [0:EXACT_COUNT-1];

    reg clk = 1'b0;
    always #5 clk = ~clk;

    // Direct cart-database instance used for exhaustive table checks.
    reg         direct_reset = 1'b1;
    reg [31:0]  direct_cart_id = 32'd0;
    reg         direct_valid = 1'b0;
    wire        direct_sram;
    wire        direct_gpio;
    wire        direct_tilt;
    wire        direct_solar;
    wire        direct_remap;
    wire        direct_sprite;
    wire        direct_ready;
    wire [5:0]  direct_flags = {
        direct_sram, direct_gpio, direct_tilt,
        direct_solar, direct_remap, direct_sprite
    };

    cart_quirks direct_quirks (
        .clk          ( clk ),
        .reset        ( direct_reset ),
        .cart_id      ( direct_cart_id ),
        .valid        ( direct_valid ),
        .sram_quirk   ( direct_sram ),
        .gpio_quirk   ( direct_gpio ),
        .tilt_quirk   ( direct_tilt ),
        .solar_quirk  ( direct_solar ),
        .memory_remap ( direct_remap ),
        .sprite_quirk ( direct_sprite ),
        .quirks_ready ( direct_ready )
    );

    // Integrated detector/database pair used to verify header byte order and
    // the ready boundary seen by core_top.
    reg         boot_reset = 1'b1;
    reg         rom_wr = 1'b0;
    reg [15:0]  rom_data = 16'd0;
    reg [27:0]  rom_addr = 28'd0;
    wire        flash_1m;
    wire [31:0] cart_id;
    wire        cart_id_valid;
    wire        boot_sram;
    wire        boot_gpio;
    wire        boot_tilt;
    wire        boot_solar;
    wire        boot_remap;
    wire        boot_sprite;
    wire        boot_quirks_ready;
    wire [5:0]  boot_flags = {
        boot_sram, boot_gpio, boot_tilt,
        boot_solar, boot_remap, boot_sprite
    };

    save_type_detector detector (
        .clk           ( clk ),
        .reset         ( boot_reset ),
        .rom_wr        ( rom_wr ),
        .rom_data      ( rom_data ),
        .rom_addr      ( rom_addr ),
        .flash_1m      ( flash_1m ),
        .cart_id       ( cart_id ),
        .cart_id_valid ( cart_id_valid )
    );

    cart_quirks boot_quirks (
        .clk          ( clk ),
        .reset        ( boot_reset ),
        .cart_id      ( cart_id ),
        .valid        ( cart_id_valid ),
        .sram_quirk   ( boot_sram ),
        .gpio_quirk   ( boot_gpio ),
        .tilt_quirk   ( boot_tilt ),
        .solar_quirk  ( boot_solar ),
        .memory_remap ( boot_remap ),
        .sprite_quirk ( boot_sprite ),
        .quirks_ready ( boot_quirks_ready )
    );

    integer i;
    integer j;
    integer suffix;
    integer mutation;
    integer quirk_checks = 0;
    integer flash_checks = 0;
    integer scan_cycles;
    integer random_nonmatches;
    reg [31:0] work_id;
    reg [31:0] lfsr;
    reg [71:0] random_window;
    integer random_byte_count;
    reg [7:0] random_low;
    reg [7:0] random_high;

    function automatic [5:0] oracle_flags(input [31:0] candidate);
        integer index;
        reg [5:0] result;
        begin
            result = 6'b000000;
            for (index = 0; index < PREFIX_COUNT; index = index + 1)
                if (candidate[31:8] == prefix_key[index])
                    result = result | prefix_value[index];
            for (index = 0; index < EXACT_COUNT; index = index + 1)
                if (candidate == exact_key[index])
                    result = result | exact_value[index];
            oracle_flags = result;
        end
    endfunction

    function automatic [7:0] signature_byte(input integer index);
        begin
            case (index)
                0: signature_byte = "F";
                1: signature_byte = "L";
                2: signature_byte = "A";
                3: signature_byte = "S";
                4: signature_byte = "H";
                5: signature_byte = "1";
                6: signature_byte = "M";
                7: signature_byte = "_";
                8: signature_byte = "V";
                default: signature_byte = 8'h00;
            endcase
        end
    endfunction

    function automatic [7:0] stream_byte(
        input integer alignment,
        input integer position,
        input integer mutation_bit,
        input [7:0] first_suffix
    );
        integer signature_index;
        reg [7:0] result;
        begin
            if (alignment == 0) begin
                signature_index = position;
                result = position < 9 ? signature_byte(position) : first_suffix;
            end else begin
                signature_index = position - 1;
                result = position == 0 ? 8'hD3 : signature_byte(position - 1);
            end
            if (signature_index >= 0 && signature_index < 9 &&
                mutation_bit >= 0 && mutation_bit / 8 == signature_index)
                result = result ^ (8'h01 << (mutation_bit % 8));
            stream_byte = result;
        end
    endfunction

    task automatic initialize_oracle;
        integer index;
        begin
            index = 0;
            prefix_key[index] = "AR8"; prefix_value[index] = 6'b100000; index = index + 1;
            prefix_key[index] = "ARO"; prefix_value[index] = 6'b100000; index = index + 1;
            prefix_key[index] = "ALG"; prefix_value[index] = 6'b100000; index = index + 1;
            prefix_key[index] = "ALF"; prefix_value[index] = 6'b100000; index = index + 1;
            prefix_key[index] = "BLF"; prefix_value[index] = 6'b100000; index = index + 1;
            prefix_key[index] = "BDB"; prefix_value[index] = 6'b100000; index = index + 1;
            prefix_key[index] = "BG3"; prefix_value[index] = 6'b100000; index = index + 1;
            prefix_key[index] = "BDV"; prefix_value[index] = 6'b100000; index = index + 1;
            prefix_key[index] = "A2Y"; prefix_value[index] = 6'b100000; index = index + 1;
            prefix_key[index] = "AI2"; prefix_value[index] = 6'b100000; index = index + 1;
            prefix_key[index] = "BT4"; prefix_value[index] = 6'b100000; index = index + 1;

            prefix_key[index] = "BPE"; prefix_value[index] = 6'b010000; index = index + 1;
            prefix_key[index] = "AXV"; prefix_value[index] = 6'b010000; index = index + 1;
            prefix_key[index] = "AXP"; prefix_value[index] = 6'b010000; index = index + 1;
            prefix_key[index] = "RZW"; prefix_value[index] = 6'b010000; index = index + 1;
            prefix_key[index] = "BKA"; prefix_value[index] = 6'b010000; index = index + 1;
            prefix_key[index] = "BR4"; prefix_value[index] = 6'b010000; index = index + 1;
            prefix_key[index] = "V49"; prefix_value[index] = 6'b010000; index = index + 1;
            prefix_key[index] = "2GB"; prefix_value[index] = 6'b010000; index = index + 1;

            prefix_key[index] = "BHG"; prefix_value[index] = 6'b000001; index = index + 1;
            prefix_key[index] = "BGX"; prefix_value[index] = 6'b000001; index = index + 1;
            prefix_key[index] = "KHP"; prefix_value[index] = 6'b001000; index = index + 1;
            prefix_key[index] = "KYG"; prefix_value[index] = 6'b001000; index = index + 1;
            prefix_key[index] = "U3I"; prefix_value[index] = 6'b010100; index = index + 1;
            prefix_key[index] = "U32"; prefix_value[index] = 6'b010100; index = index + 1;
            prefix_key[index] = "U33"; prefix_value[index] = 6'b010100; index = index + 1;
            if (index != PREFIX_COUNT)
                $fatal(1, "oracle prefix count is %0d, expected %0d", index, PREFIX_COUNT);

            index = 0;
            exact_key[index] = "FBME"; exact_value[index] = 6'b100010; index = index + 1;
            exact_key[index] = "FADE"; exact_value[index] = 6'b100010; index = index + 1;
            exact_key[index] = "FDKE"; exact_value[index] = 6'b100010; index = index + 1;
            exact_key[index] = "FDME"; exact_value[index] = 6'b100010; index = index + 1;
            exact_key[index] = "FEBE"; exact_value[index] = 6'b100010; index = index + 1;
            exact_key[index] = "FICE"; exact_value[index] = 6'b100010; index = index + 1;
            exact_key[index] = "FMRE"; exact_value[index] = 6'b100010; index = index + 1;
            exact_key[index] = "FP7E"; exact_value[index] = 6'b100010; index = index + 1;
            exact_key[index] = "FSME"; exact_value[index] = 6'b100010; index = index + 1;
            exact_key[index] = "FZLE"; exact_value[index] = 6'b100010; index = index + 1;
            exact_key[index] = "FXVE"; exact_value[index] = 6'b100010; index = index + 1;
            exact_key[index] = "FLBE"; exact_value[index] = 6'b100010; index = index + 1;
            exact_key[index] = "FSRJ"; exact_value[index] = 6'b100010; index = index + 1;
            exact_key[index] = "FGZJ"; exact_value[index] = 6'b100010; index = index + 1;

            exact_key[index] = "FSDJ"; exact_value[index] = 6'b100011; index = index + 1;
            exact_key[index] = "FADJ"; exact_value[index] = 6'b100011; index = index + 1;
            exact_key[index] = "FTUJ"; exact_value[index] = 6'b100001; index = index + 1;
            exact_key[index] = "FTKJ"; exact_value[index] = 6'b100001; index = index + 1;
            exact_key[index] = "FFMJ"; exact_value[index] = 6'b100001; index = index + 1;
            exact_key[index] = "FLBJ"; exact_value[index] = 6'b100001; index = index + 1;
            exact_key[index] = "FPTJ"; exact_value[index] = 6'b100001; index = index + 1;
            exact_key[index] = "FMRJ"; exact_value[index] = 6'b100001; index = index + 1;
            exact_key[index] = "FNMJ"; exact_value[index] = 6'b100001; index = index + 1;
            exact_key[index] = "FM2J"; exact_value[index] = 6'b100011; index = index + 1;

            exact_key[index] = "FGGJ"; exact_value[index] = 6'b100010; index = index + 1;
            exact_key[index] = "FTWJ"; exact_value[index] = 6'b100010; index = index + 1;
            exact_key[index] = "FMKJ"; exact_value[index] = 6'b100010; index = index + 1;
            exact_key[index] = "FTBJ"; exact_value[index] = 6'b100010; index = index + 1;
            exact_key[index] = "FDDJ"; exact_value[index] = 6'b100010; index = index + 1;
            exact_key[index] = "FDMJ"; exact_value[index] = 6'b100010; index = index + 1;
            exact_key[index] = "FWCJ"; exact_value[index] = 6'b100010; index = index + 1;
            exact_key[index] = "FVFJ"; exact_value[index] = 6'b100010; index = index + 1;
            exact_key[index] = "FCLJ"; exact_value[index] = 6'b100010; index = index + 1;
            exact_key[index] = "FMBJ"; exact_value[index] = 6'b100010; index = index + 1;
            exact_key[index] = "FSOJ"; exact_value[index] = 6'b100010; index = index + 1;
            exact_key[index] = "FBMJ"; exact_value[index] = 6'b100010; index = index + 1;
            exact_key[index] = "FMPJ"; exact_value[index] = 6'b100010; index = index + 1;
            exact_key[index] = "FXVJ"; exact_value[index] = 6'b100010; index = index + 1;
            exact_key[index] = "FPMJ"; exact_value[index] = 6'b100010; index = index + 1;
            exact_key[index] = "FZLJ"; exact_value[index] = 6'b100010; index = index + 1;
            exact_key[index] = "FEBJ"; exact_value[index] = 6'b100010; index = index + 1;
            exact_key[index] = "FICJ"; exact_value[index] = 6'b100010; index = index + 1;
            exact_key[index] = "FDKJ"; exact_value[index] = 6'b100010; index = index + 1;
            exact_key[index] = "FSMJ"; exact_value[index] = 6'b100010; index = index + 1;
            if (index != EXACT_COUNT)
                $fatal(1, "oracle exact count is %0d, expected %0d", index, EXACT_COUNT);

            if (RECORD_COUNT != 70)
                $fatal(1, "oracle record count changed: %0d", RECORD_COUNT);

            // The oracle itself must not contain duplicate keys. A duplicate
            // could silently turn a count ratchet into repeated coverage.
            for (i = 0; i < PREFIX_COUNT; i = i + 1)
                for (j = i + 1; j < PREFIX_COUNT; j = j + 1)
                    if (prefix_key[i] == prefix_key[j])
                        $fatal(1, "duplicate prefix oracle key %06x", prefix_key[i]);
            for (i = 0; i < EXACT_COUNT; i = i + 1)
                for (j = i + 1; j < EXACT_COUNT; j = j + 1)
                    if (exact_key[i] == exact_key[j])
                        $fatal(1, "duplicate exact oracle key %08x", exact_key[i]);
        end
    endtask

    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic reset_direct;
        begin
            @(negedge clk);
            direct_reset = 1'b1;
            direct_valid = 1'b0;
            tick();
            if (direct_ready !== 1'b0 || direct_flags !== 6'b000000)
                $fatal(1, "cart_quirks reset did not clear ready/flags");
            @(negedge clk);
            direct_reset = 1'b0;
        end
    endtask

    task automatic query_quirks(input [31:0] candidate);
        reg [5:0] expected;
        integer cycles;
        begin
            expected = oracle_flags(candidate);
            reset_direct();
            direct_cart_id = candidate;
            direct_valid = 1'b1;
            tick();
            @(negedge clk);
            direct_valid = 1'b0;

            cycles = 0;
            while (!direct_ready && cycles < RECORD_COUNT + 2) begin
                tick();
                cycles = cycles + 1;
            end
            if (!direct_ready)
                $fatal(1, "quirk lookup timed out for %08x", candidate);
            if (cycles != RECORD_COUNT)
                $fatal(1, "quirk lookup latency=%0d expected=%0d for %08x",
                       cycles, RECORD_COUNT, candidate);
            if (direct_flags !== expected)
                $fatal(1, "quirk mismatch id=%08x got=%06b expected=%06b",
                       candidate, direct_flags, expected);
            quirk_checks = quirk_checks + 1;
        end
    endtask

    task automatic reset_boot;
        begin
            @(negedge clk);
            boot_reset = 1'b1;
            rom_wr = 1'b0;
            tick();
            if (flash_1m !== 1'b0 || cart_id !== 32'd0 ||
                cart_id_valid !== 1'b0 || boot_quirks_ready !== 1'b0 ||
                boot_flags !== 6'b000000)
                $fatal(1, "boot metadata reset contract failed");
            @(negedge clk);
            boot_reset = 1'b0;
        end
    endtask

    task automatic send_word(
        input [7:0] low_byte,
        input [7:0] high_byte,
        input [27:0] address,
        input integer idle_cycles
    );
        begin
            if (address[0] !== 1'b0)
                $fatal(1, "metadata test driver used odd ROM address %07x", address);
            @(negedge clk);
            rom_data = {high_byte, low_byte};
            rom_addr = address;
            rom_wr = 1'b1;
            tick();
            @(negedge clk);
            rom_wr = 1'b0;
            repeat (idle_cycles)
                tick();
        end
    endtask

    task automatic feed_signature(
        input integer alignment,
        input integer mutation_bit,
        input integer address_mode,
        input integer gap_mode,
        input [7:0] first_suffix,
        input integer expect_match
    );
        integer word_index;
        integer gap_count;
        reg [27:0] address;
        reg [7:0] low_byte;
        reg [7:0] high_byte;
        reg already_detected;
        begin
            already_detected = flash_1m;
            for (word_index = 0; word_index < 5; word_index = word_index + 1) begin
                low_byte = stream_byte(alignment, word_index * 2,
                                       mutation_bit, first_suffix);
                high_byte = stream_byte(alignment, word_index * 2 + 1,
                                        mutation_bit, first_suffix);
                case (address_mode)
                    0: address = 28'h0010000 + word_index * 2;
                    1: begin
                        case (word_index)
                            0: address = 28'h0004200;
                            1: address = 28'h0ABC000;
                            2: address = 28'h0000010;
                            3: address = 28'h0555000;
                            default: address = 28'h0000200;
                        endcase
                    end
                    default: address = 28'h0100000 - word_index * 14;
                endcase
                gap_count = gap_mode == 0 ? 0 : (word_index * 3 + 1);
                send_word(low_byte, high_byte, address, gap_count);
                if (!already_detected && word_index < 4 && flash_1m !== 1'b0)
                    $fatal(1, "FLASH1M_V detected before the V byte");
            end
            if (flash_1m !== (expect_match != 0))
                $fatal(1,
                       "signature result mismatch align=%0d mutation=%0d addrmode=%0d gapmode=%0d got=%0b",
                       alignment, mutation_bit, address_mode, gap_mode, flash_1m);
            flash_checks = flash_checks + 1;
        end
    endtask

    task automatic run_signature(
        input integer alignment,
        input integer mutation_bit,
        input integer address_mode,
        input integer gap_mode,
        input [7:0] first_suffix,
        input integer expect_match
    );
        begin
            reset_boot();
            feed_signature(alignment, mutation_bit, address_mode, gap_mode,
                           first_suffix, expect_match);
        end
    endtask

    task automatic wait_boot_quirks(input integer expected_cycles);
        integer cycles;
        begin
            cycles = 0;
            while (!boot_quirks_ready && cycles < expected_cycles + 3) begin
                tick();
                cycles = cycles + 1;
            end
            if (!boot_quirks_ready)
                $fatal(1, "integrated quirk lookup timed out");
            if (cycles != expected_cycles)
                $fatal(1, "integrated ready latency=%0d expected=%0d",
                       cycles, expected_cycles);
        end
    endtask

    initial begin : regression
        reg [5:0] held_flags;
        reg [71:0] candidate_window;
        initialize_oracle();

        // Exact production table: every suffix of every prefix.
        for (i = 0; i < PREFIX_COUNT; i = i + 1)
            for (suffix = 0; suffix < 256; suffix = suffix + 1)
                query_quirks({prefix_key[i], suffix[7:0]});

        // Every exact key and all variants of every exact three-byte stem.
        for (i = 0; i < EXACT_COUNT; i = i + 1)
            query_quirks(exact_key[i]);
        for (i = 0; i < EXACT_COUNT; i = i + 1)
            for (suffix = 0; suffix < 256; suffix = suffix + 1)
                query_quirks({exact_key[i][31:8], suffix[7:0]});

        // Flip every significant prefix bit and every exact-key bit. Always
        // compare with the oracle: several mutations are other legal keys.
        for (i = 0; i < PREFIX_COUNT; i = i + 1)
            for (mutation = 0; mutation < 24; mutation = mutation + 1) begin
                work_id = {prefix_key[i], 8'hA5};
                work_id[mutation + 8] = ~work_id[mutation + 8];
                query_quirks(work_id);
            end
        for (i = 0; i < EXACT_COUNT; i = i + 1)
            for (mutation = 0; mutation < 32; mutation = mutation + 1) begin
                work_id = exact_key[i];
                work_id[mutation] = ~work_id[mutation];
                query_quirks(work_id);
            end

        // Fixed-seed random negatives.
        lfsr = 32'h3511_A70D;
        random_nonmatches = 0;
        while (random_nonmatches < 4096) begin
            lfsr = {lfsr[30:0],
                    lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            if (oracle_flags(lfsr) == 6'b000000) begin
                query_quirks(lfsr);
                random_nonmatches = random_nonmatches + 1;
            end
        end

        // valid may remain high, but only the first ID after reset is
        // captured. Input changes, valid gaps, and retriggers cannot replace
        // the finalized result until the next reset.
        reset_direct();
        direct_cart_id = "BPEE";
        direct_valid = 1'b1;
        tick();
        for (i = 0; i < RECORD_COUNT; i = i + 1) begin
            @(negedge clk);
            direct_cart_id = (i[0] ? "AR8E" : "FSDJ");
            direct_valid = 1'b1;
            tick();
        end
        if (!direct_ready || direct_flags !== 6'b010000)
            $fatal(1, "held valid replaced first captured cart ID");
        held_flags = direct_flags;
        repeat (4) begin
            @(negedge clk);
            direct_cart_id = "FM2J";
            tick();
            if (!direct_ready || direct_flags !== held_flags)
                $fatal(1, "completed quirk result changed while valid stayed high");
        end
        @(negedge clk);
        direct_valid = 1'b0;
        tick();
        if (!direct_ready || direct_flags !== held_flags)
            $fatal(1, "valid=0 did not hold finalized quirk result");
        @(negedge clk);
        direct_cart_id = "AR8E";
        direct_valid = 1'b1;
        repeat (3) tick();
        if (!direct_ready || direct_flags !== held_flags)
            $fatal(1, "cart_quirks retriggered without reset");
        direct_valid = 1'b0;

        // Synchronous reset also aborts an in-flight scan and returns the
        // externally visible metadata boundary to a known state.
        reset_direct();
        direct_cart_id = "FSDJ";
        direct_valid = 1'b1;
        tick();
        @(negedge clk);
        direct_valid = 1'b0;
        repeat (13) tick();
        if (direct_ready)
            $fatal(1, "quirk scan completed implausibly early");
        @(negedge clk);
        direct_reset = 1'b1;
        tick();
        if (direct_ready || direct_flags !== 6'b000000)
            $fatal(1, "in-flight quirk reset did not clear state");
        @(negedge clk);
        direct_reset = 1'b0;

        $display("QUIRK-DATABASE PASS checks=%0d prefixes=%0d exact=%0d",
                 quirk_checks, PREFIX_COUNT, EXACT_COUNT);

        // Signature positives at both byte alignments, including arbitrary
        // stream history, temporal gaps, and discontinuous/reordered addresses.
        run_signature(0, -1, 0, 0, 8'h00, 1);
        run_signature(1, -1, 0, 0, 8'h00, 1);
        reset_boot();
        send_word(8'h91, 8'h27, 28'h0003000, 0);
        send_word(8'hE4, 8'h5A, 28'h0003002, 0);
        feed_signature(0, -1, 0, 0, 8'hCC, 1);
        run_signature(0, -1, 0, 1, 8'hA7, 1);
        run_signature(1, -1, 0, 1, 8'h00, 1);
        run_signature(0, -1, 1, 0, 8'h5C, 1);
        run_signature(1, -1, 2, 0, 8'h00, 1);

        // Every possible first suffix byte. Even alignment consumes it on the
        // V edge; odd alignment consumes it one word later. Detection must
        // already be sticky before either suffix can influence the result.
        for (suffix = 0; suffix < 256; suffix = suffix + 1) begin
            run_signature(0, -1, 0, 0, suffix[7:0], 1);
            run_signature(1, -1, 0, 0, 8'h00, 1);
            if (!flash_1m)
                $fatal(1, "odd-aligned signature not set before suffix %02x", suffix);
            send_word(suffix[7:0], 8'hA6, 28'h001000A, 0);
            if (!flash_1m)
                $fatal(1, "suffix %02x cleared sticky detection", suffix);
        end

        // Every bit of the nine-byte signature, at both alignments.
        for (mutation = 0; mutation < 72; mutation = mutation + 1) begin
            run_signature(0, mutation, 0, 0, 8'h6D, 0);
            run_signature(1, mutation, 0, 0, 8'h00, 0);
        end

        // Pairwise byte reversal, FLASH512_V, and FLASH_V must not alias.
        reset_boot();
        send_word("L", "F", 28'h2000, 0);
        send_word("S", "A", 28'h2002, 0);
        send_word("1", "H", 28'h2004, 0);
        send_word("_", "M", 28'h2006, 0);
        send_word(8'h00, "V", 28'h2008, 0);
        if (flash_1m) $fatal(1, "word-byte-reversed signature detected");

        reset_boot();
        send_word("F", "L", 28'h2100, 0);
        send_word("A", "S", 28'h2102, 0);
        send_word("H", "5", 28'h2104, 0);
        send_word("1", "2", 28'h2106, 0);
        send_word("_", "V", 28'h2108, 0);
        if (flash_1m) $fatal(1, "FLASH512_V alias detected");

        reset_boot();
        send_word("F", "L", 28'h2200, 0);
        send_word("A", "S", 28'h2202, 0);
        send_word("H", "_", 28'h2204, 0);
        send_word("V", 8'h00, 28'h2206, 0);
        if (flash_1m) $fatal(1, "FLASH_V alias detected");

        // Pattern-like bus values while rom_wr is low do not enter history.
        reset_boot();
        for (i = 0; i < 5; i = i + 1) begin
            @(negedge clk);
            rom_wr = 1'b0;
            rom_data = {
                stream_byte(0, i * 2 + 1, -1, 8'h00),
                stream_byte(0, i * 2, -1, 8'h00)
            };
            repeat (i + 1) tick();
            if (flash_1m) $fatal(1, "idle bus data shifted into signature history");
        end
        send_word("V", 8'h00, 28'h2300, 0);
        if (flash_1m) $fatal(1, "idle pattern joined a later V byte");

        // A reset in the middle severs history. A simultaneous reset/write is
        // reset-only and cannot complete the signature.
        reset_boot();
        send_word("F", "L", 28'h2400, 0);
        send_word("A", "S", 28'h2402, 0);
        reset_boot();
        send_word("H", "1", 28'h2404, 0);
        send_word("M", "_", 28'h2406, 0);
        send_word("V", 8'h00, 28'h2408, 0);
        if (flash_1m) $fatal(1, "signature history crossed reset");

        reset_boot();
        send_word("F", "L", 28'h2500, 0);
        send_word("A", "S", 28'h2502, 0);
        send_word("H", "1", 28'h2504, 0);
        send_word("M", "_", 28'h2506, 0);
        @(negedge clk);
        boot_reset = 1'b1;
        rom_wr = 1'b1;
        rom_data = {8'h00, "V"};
        rom_addr = 28'h2508;
        tick();
        if (flash_1m || cart_id_valid || cart_id != 0)
            $fatal(1, "rom_wr overrode simultaneous metadata reset");
        @(negedge clk);
        boot_reset = 1'b0;
        rom_wr = 1'b0;
        send_word("V", 8'h00, 28'h2508, 0);
        if (flash_1m) $fatal(1, "reset/write edge retained signature history");

        // Fixed-seed random bytes, independently checked with a byte-oriented
        // 72-bit window, contain no signature and must not detect.
        reset_boot();
        lfsr = 32'hC001_D00D;
        random_window = 72'd0;
        random_byte_count = 0;
        for (i = 0; i < 4096; i = i + 1) begin
            lfsr = {lfsr[30:0],
                    lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            random_low = lfsr[7:0];
            random_high = lfsr[23:16] ^ lfsr[15:8];
            candidate_window = {random_window[63:0], random_low};
            if (random_byte_count >= 8 && candidate_window == FLASH_SIGNATURE)
                $fatal(1, "fixed random fixture unexpectedly contains FLASH1M_V");
            random_window = candidate_window;
            random_byte_count = random_byte_count + 1;
            candidate_window = {random_window[63:0], random_high};
            if (random_byte_count >= 8 && candidate_window == FLASH_SIGNATURE)
                $fatal(1, "fixed random fixture unexpectedly contains FLASH1M_V");
            random_window = candidate_window;
            random_byte_count = random_byte_count + 1;
            send_word(random_low, random_high,
                      28'h3000000 ^ {lfsr[19:0], 1'b0}, i % 4);
            if (flash_1m) $fatal(1, "random non-signature stream detected");
        end

        // Sticky detection survives arbitrary later data and a repeated
        // signature, then clears only on reset.
        run_signature(0, -1, 0, 0, 8'h42, 1);
        for (i = 0; i < 20; i = i + 1) begin
            send_word(i[7:0], ~i[7:0], 28'h4000000 + i * 30, i % 3);
            if (!flash_1m) $fatal(1, "FLASH1M result was not sticky");
        end
        feed_signature(1, -1, 1, 1, 8'h00, 1);
        reset_boot();
        if (flash_1m) $fatal(1, "metadata reset did not clear FLASH1M");

        $display("SAVE-DETECTOR PASS checks=%0d random_bytes=%0d",
                 flash_checks, random_byte_count);

        // Header bytes AC/AE are little-endian halfwords but form a big-endian
        // cart ID. valid rises at B0; the sequential database observes that
        // sticky level on the following edge, then scans exactly 70 records.
        reset_boot();
        send_word("B", "P", 28'h00000AC, 0);
        if (cart_id !== 32'h4250_0000 || cart_id_valid)
            $fatal(1, "header AC byte order/valid mismatch: %08x/%0b",
                   cart_id, cart_id_valid);
        send_word("E", "E", 28'h00000AE, 0);
        if (cart_id !== "BPEE" || cart_id_valid)
            $fatal(1, "header AE byte order/valid mismatch: %08x/%0b",
                   cart_id, cart_id_valid);
        send_word(8'h12, 8'h34, 28'h00000B0, 0);
        if (!cart_id_valid || boot_quirks_ready || boot_flags !== 6'b000000)
            $fatal(1, "B0 readiness boundary mismatch");
        wait_boot_quirks(RECORD_COUNT + 1);
        if (boot_flags !== 6'b010000)
            $fatal(1, "integrated BPEE flags=%06b expected=010000", boot_flags);
        repeat (4) begin
            tick();
            if (!cart_id_valid || !boot_quirks_ready ||
                boot_flags !== 6'b010000)
                $fatal(1, "metadata ready/valid was not sticky");
        end

        // The detector may update its sticky-level cart_id later, but the
        // finalized quirk lookup is intentionally one-shot until reset.
        send_word("A", "R", 28'h00000AC, 0);
        send_word("8", "E", 28'h00000AE, 0);
        if (cart_id !== "AR8E")
            $fatal(1, "post-valid header rewrite byte order mismatch");
        repeat (RECORD_COUNT + 4) begin
            tick();
            if (!boot_quirks_ready || boot_flags !== 6'b010000)
                $fatal(1, "sticky cart_id_valid retriggered quirk scan");
        end
        send_word(8'hAA, 8'h55, 28'h00000F0, 0);
        if (!cart_id_valid || !boot_quirks_ready)
            $fatal(1, "later ROM write cleared metadata readiness");

        // Preserve the current detector contract for incomplete headers: any
        // accepted address at/above B0 raises valid. The database safely
        // finalizes all-zero flags for the reset cart ID.
        reset_boot();
        send_word(8'h00, 8'h00, 28'h00000B0, 0);
        if (!cart_id_valid || cart_id !== 32'd0)
            $fatal(1, "incomplete-header valid characterization changed");
        wait_boot_quirks(RECORD_COUNT + 1);
        if (boot_flags !== 6'b000000)
            $fatal(1, "incomplete header produced nonzero quirks");

        $display("HEADER-INTEGRATION PASS cart_id=%08x ready=%0b",
                 cart_id, boot_quirks_ready);
        $display("BOOT-METADATA-TEST PASS quirk_checks=%0d flash_checks=%0d",
                 quirk_checks, flash_checks);
        $finish;
    end

endmodule

`default_nettype wire
