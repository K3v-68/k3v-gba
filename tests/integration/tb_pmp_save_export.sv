`timescale 1ns/1ps

// Transport-level save-export reproduction.  Unlike the existing integration
// test, this drives the physical dual-data PMP pins of io_bridge_peripheral and
// scores the words actually shifted back to the host.  All data-path modules
// below are production sources supplied on the simulator command line.
module tb_pmp_save_export #(
  parameter integer BODY_BYTES = 131072,
  parameter integer CADENCE_CYCLES = 88,
  parameter integer RUN_RTC = 1,
  parameter integer VERBOSE = 0,
  parameter integer SUPPRESS_CART_RESPONSE = 0,
  parameter integer EXPECT_ALL_ZERO = 0,
  parameter integer USE_SNAPSHOT = 0,
  parameter integer INJECT_MIDDLE_DUPLICATE = 0,
  parameter integer INJECT_BOUNDARY_PRIME_DUPLICATE = 0,
  parameter integer BOUNDARY_PRIME_REPEATS = 1,
  parameter integer INJECT_CHUNK_LAST_DUPLICATE = 0,
  parameter integer INJECT_BOUNDARY_REWIND = 0,
  parameter integer INTERLEAVE_COMMAND_READ = 0
);
  localparam integer BODY_HALFWORDS = BODY_BYTES / 2;
  localparam integer BODY_WORDS = BODY_BYTES / 4;
  localparam [16:0] BODY_HALFWORDS_17 = BODY_HALFWORDS;

  reg clk_74a = 1'b0;
  reg clk_sys = 1'b0;
  always #6.734 clk_74a = ~clk_74a;
  initial begin
    #0.319;
    forever #4.967 clk_sys = ~clk_sys;
  end

  integer clk74_cycle = 0;
  integer prime_repeat;
  always @(posedge clk_74a)
    clk74_cycle <= clk74_cycle + 1;

  reg reset_n = 1'b0;
  reg endian_little = 1'b0;

  // The physical bridge is pulled high when neither endpoint drives it.  This
  // avoids treating a host release (1 -> Z) as an extra response-clock edge.
  tri1 phy_spimosi;
  tri1 phy_spimiso;
  tri1 phy_spiclk;
  reg phy_spiss = 1'b1;
  reg host_data_oe = 1'b0;
  reg host_clk_oe = 1'b0;
  reg host_mosi = 1'b1;
  reg host_miso = 1'b1;
  reg host_clk = 1'b1;
  assign phy_spimosi = host_data_oe ? host_mosi : 1'bz;
  assign phy_spimiso = host_data_oe ? host_miso : 1'bz;
  assign phy_spiclk  = host_clk_oe  ? host_clk  : 1'bz;

  wire [31:0] bridge_addr;
  wire bridge_addr_valid;
  wire bridge_rd;
  wire bridge_wr;
  wire [31:0] bridge_wr_data;
  reg [31:0] bridge_rd_data;

  io_bridge_peripheral bridge (
      .clk(clk_74a),
      .reset_n(reset_n),
      .endian_little(endian_little),
      .pmp_addr(bridge_addr),
      .pmp_addr_valid(bridge_addr_valid),
      .pmp_rd(bridge_rd),
      .pmp_rd_data(bridge_rd_data),
      .pmp_wr(bridge_wr),
      .pmp_wr_data(bridge_wr_data),
      .phy_spimosi(phy_spimosi),
      .phy_spimiso(phy_spimiso),
      .phy_spiclk(phy_spiclk),
      .phy_spiss(phy_spiss)
  );

  wire [31:0] legacy_read_bridge_data;
  wire legacy_read_bridge_valid;
  wire [31:0] snapshot_bridge_data;
  wire snapshot_bridge_valid;
  wire snapshot_ready;
  wire snapshot_failed;
  wire [31:0] save_read_bridge_data =
      USE_SNAPSHOT && bridge_addr[27:24] == 4'h0 ?
      snapshot_bridge_data : legacy_read_bridge_data;
  wire save_read_bridge_valid =
      USE_SNAPSHOT && bridge_addr[27:24] == 4'h0 ?
      snapshot_bridge_valid : legacy_read_bridge_valid;
  wire save_unloader_rd;
  wire [27:0] save_unloader_addr;
  reg [15:0] save_unloader_data = 16'd0;
  reg save_unloader_data_valid = 1'b0;
  wire save_unloader_ready;

  data_unloader #(
      .ADDRESS_MASK_UPPER_4(4'h2),
      .ADDRESS_SIZE(28),
      .READ_MEM_CLOCK_DELAY(20),
      .INPUT_WORD_SIZE(2)
  ) save_data_unloader (
      .clk_74a(clk_74a),
      .clk_memory(clk_sys),
      .bridge_rd(bridge_rd),
      .bridge_endian_little(endian_little),
      .bridge_addr(bridge_addr),
      .bridge_rd_data(legacy_read_bridge_data),
      .bridge_rd_data_valid(legacy_read_bridge_valid),
      .read_en(save_unloader_rd),
      .read_addr(save_unloader_addr),
      .read_ready(save_unloader_ready),
      .read_data(save_unloader_data),
      .read_data_valid(save_unloader_data_valid)
  );

  // Exact core_top read mux for the region under test.
  always @(*) begin
    casex (bridge_addr)
      32'h2xxxxxxx: bridge_rd_data = save_read_bridge_data;
      32'hF8xxxxxx: bridge_rd_data = 32'hc0de_f00d;
      default:      bridge_rd_data = 32'd0;
    endcase
  end

  function automatic [15:0] fixture_halfword(input integer halfword_index);
    reg [31:0] mixed;
    begin
      mixed = (halfword_index * 32'h9e37_79b1) ^
              (halfword_index << 7) ^ 32'ha5c3_5a7d;
      fixture_halfword = (mixed[15:0] ^ mixed[31:16]) | 16'h0001;
    end
  endfunction

  // data_unloader swaps byte lanes for bridge_endian_little=0, which is the
  // value driven by production core_top.  io_bridge_peripheral then sends this
  // value MSB-pair first without a second swap.
  function automatic [31:0] expected_save_word(input integer word_index);
    reg [15:0] lo;
    reg [15:0] hi;
    begin
      lo = fixture_halfword(word_index * 2);
      hi = fixture_halfword(word_index * 2 + 1);
      expected_save_word = {lo[7:0], lo[15:8], hi[7:0], hi[15:8]};
    end
  endfunction

  function automatic [15:0] rtc_halfword(input integer halfword_index);
    begin
      case (halfword_index)
        0: rtc_halfword = 16'h4567;
        1: rtc_halfword = 16'h0123;
        2: rtc_halfword = 16'hcdef;
        3: rtc_halfword = 16'h89ab;
        4: rtc_halfword = 16'h02aa;
        default: rtc_halfword = 16'h0000;
      endcase
    end
  endfunction

  function automatic [31:0] expected_rtc_word(input integer word_index);
    reg [15:0] lo;
    reg [15:0] hi;
    begin
      lo = rtc_halfword(word_index * 2);
      hi = rtc_halfword(word_index * 2 + 1);
      expected_rtc_word = {lo[7:0], lo[15:8], hi[7:0], hi[15:8]};
    end
  endfunction

  reg [15:0] memory [0:BODY_HALFWORDS-1];
  integer init_index;
  initial begin
    for (init_index = 0; init_index < BODY_HALFWORDS; init_index = init_index + 1)
      memory[init_index] = fixture_halfword(init_index);
  end

  wire snapshot_source_read;
  wire [16:0] snapshot_source_addr;
  reg [15:0] snapshot_source_data = 16'd0;
  reg snapshot_source_data_valid = 1'b0;
  reg snapshot_source_seen = 1'b0;
  integer snapshot_source_delay = -1;
  wire [16:0] snapshot_sram_a;
  tri [15:0] snapshot_sram_dq;
  wire snapshot_sram_oe_n;
  wire snapshot_sram_we_n;
  wire snapshot_sram_ub_n;
  wire snapshot_sram_lb_n;
  reg [15:0] snapshot_sram [0:BODY_HALFWORDS-1];

  assign snapshot_sram_dq = !snapshot_sram_oe_n ?
      snapshot_sram[snapshot_sram_a] : 16'hzzzz;

  always @(posedge clk_74a) begin
    if (!snapshot_sram_we_n) begin
      if (!snapshot_sram_lb_n)
        snapshot_sram[snapshot_sram_a][7:0] <= snapshot_sram_dq[7:0];
      if (!snapshot_sram_ub_n)
        snapshot_sram[snapshot_sram_a][15:8] <= snapshot_sram_dq[15:8];
    end

    if (!snapshot_source_read) begin
      snapshot_source_data_valid <= 1'b0;
      snapshot_source_seen <= 1'b0;
      snapshot_source_delay <= -1;
    end else if (!snapshot_source_seen) begin
      snapshot_source_seen <= 1'b1;
      snapshot_source_delay <= 3;
    end else if (!snapshot_source_data_valid && snapshot_source_delay > 0) begin
      snapshot_source_delay <= snapshot_source_delay - 1;
    end else if (!snapshot_source_data_valid && snapshot_source_delay == 0) begin
      snapshot_source_data <= fixture_halfword(snapshot_source_addr);
      snapshot_source_data_valid <= 1'b1;
      snapshot_source_delay <= -1;
    end
  end

  save_snapshot #(
      .SRAM_WAIT_CYCLES(8),
      .SOURCE_TIMEOUT_CYCLES(1024)
  ) snapshot (
      .clk(clk_74a),
      .reset_n(reset_n),
      .start(USE_SNAPSHOT != 0),
      .word_count(BODY_HALFWORDS_17),
      .busy(),
      .ready(snapshot_ready),
      .failed(snapshot_failed),
      .source_read(snapshot_source_read),
      .source_addr(snapshot_source_addr),
      .source_accepted(snapshot_source_seen),
      .source_idle(!snapshot_source_seen && !snapshot_source_data_valid),
      .source_data(snapshot_source_data),
      .source_data_valid(snapshot_source_data_valid),
      .bridge_endian_little(endian_little),
      .bridge_addr(bridge_addr),
      .bridge_rd(bridge_rd),
      .bridge_rd_data(snapshot_bridge_data),
      .bridge_rd_data_valid(snapshot_bridge_valid),
      .sram_a(snapshot_sram_a),
      .sram_dq(snapshot_sram_dq),
      .sram_oe_n(snapshot_sram_oe_n),
      .sram_we_n(snapshot_sram_we_n),
      .sram_ub_n(snapshot_sram_ub_n),
      .sram_lb_n(snapshot_sram_lb_n)
  );

  // Production PSRAM controller plus behavioral external CRAM storage.
  wire psram_read_avail;
  wire [15:0] psram_data_out;
  wire psram_busy;
  wire [21:16] cram_a;
  tri [15:0] cram_dq;
  reg cram_model_drive = 1'b0;
  reg [15:0] cram_model_data = 16'd0;
  assign cram_dq = cram_model_drive ? cram_model_data : 16'hzzzz;
  wire cram_clk;
  wire cram_adv_n;
  wire cram_cre;
  wire cram_ce0_n;
  wire cram_ce1_n;
  wire cram_oe_n;
  wire cram_we_n;
  wire cram_ub_n;
  wire cram_lb_n;

  wire save_unload_is_cart = save_unloader_addr[27:24] == 4'h0;
  wire save_unload_is_rtc = save_unloader_addr[27:24] == 4'h1;
  wire save_unloader_accept = save_unloader_rd && save_unloader_ready;
  reg save_unload_pending = 1'b0;
  reg [21:0] pending_word_addr = 22'd0;
  reg save_unload_pause = 1'b0;

  // Mirror the only dynamic parts of core_top's readiness gate: the first
  // memory-side request establishes pause ownership, then waits for an idle
  // PSRAM and for the previous read response to retire.
  always @(posedge clk_sys) begin
    if (!reset_n)
      save_unload_pause <= 1'b0;
    else if (save_unloader_rd || save_unload_pending)
      save_unload_pause <= 1'b1;
  end
  assign save_unloader_ready = reset_n && save_unload_pause &&
      !save_unload_pending &&
      (save_unload_is_rtc || (save_unload_is_cart && !psram_busy));

  psram #(.CLOCK_SPEED(100.66)) save_psram (
      .clk(clk_sys),
      .bank_sel(1'b1),
      .addr({1'b0, save_unloader_addr[21:1]}),
      .write_en(1'b0),
      .data_in(16'd0),
      .write_high_byte(1'b1),
      .write_low_byte(1'b1),
      .read_en(save_unloader_accept && save_unload_is_cart),
      .read_avail(psram_read_avail),
      .data_out(psram_data_out),
      .busy(psram_busy),
      .cram_a(cram_a),
      .cram_dq(cram_dq),
      .cram_wait(1'b0),
      .cram_clk(cram_clk),
      .cram_adv_n(cram_adv_n),
      .cram_cre(cram_cre),
      .cram_ce0_n(cram_ce0_n),
      .cram_ce1_n(cram_ce1_n),
      .cram_oe_n(cram_oe_n),
      .cram_we_n(cram_we_n),
      .cram_ub_n(cram_ub_n),
      .cram_lb_n(cram_lb_n)
  );

  always @(posedge clk_sys) begin
    save_unloader_data_valid <= 1'b0;

    if (save_unloader_accept) begin
      if (save_unload_is_rtc) begin
        save_unloader_data <= rtc_halfword(save_unloader_addr[4:1]);
        save_unloader_data_valid <= 1'b1;
      end else if (save_unload_is_cart) begin
        save_unload_pending <= 1'b1;
        pending_word_addr <= save_unloader_addr[21:1];
      end
    end

    if (!cram_oe_n && save_unload_pending) begin
      cram_model_data <= memory[pending_word_addr];
      cram_model_drive <= 1'b1;
    end else begin
      cram_model_drive <= 1'b0;
    end

    if (psram_read_avail && save_unload_pending) begin
      if (!SUPPRESS_CART_RESPONSE) begin
        save_unloader_data <= psram_data_out;
        save_unloader_data_valid <= 1'b1;
      end
      save_unload_pending <= 1'b0;
      cram_model_drive <= 1'b0;
    end
  end

  integer pmp_read_pulses = 0;
  integer pmp_valid_pulses = 0;
  integer last_pmp_read_cycle = -1;
  reg [4:0] prior_bridge_state = 5'h1f;
  reg [4:0] prior_spis_state = 5'h1f;
  always @(posedge clk_74a) begin
    if (VERBOSE && (bridge.state !== prior_bridge_state ||
                    bridge.spis !== prior_spis_state))
      $display("TRACE cycle=%0d state=%0d spis=%0d ss=%b rx_done=%b rd=%b valid=%b data=%08x",
               clk74_cycle, bridge.state, bridge.spis, phy_spiss,
               bridge.rx_byte_done_r_2, bridge_rd,
               save_read_bridge_valid, save_read_bridge_data);
    if (VERBOSE && bridge.rx_byte_done_r_2)
      $display("BYTE cycle=%0d addr_cnt=%0d byte=%02x pmp_addr=%08x",
               clk74_cycle, bridge.addr_cnt, bridge.rx_byte_2, bridge_addr);
    prior_bridge_state <= bridge.state;
    prior_spis_state <= bridge.spis;
    if (bridge_rd) begin
      pmp_read_pulses <= pmp_read_pulses + 1;
      last_pmp_read_cycle <= clk74_cycle;
    end
    if (save_read_bridge_valid)
      pmp_valid_pulses <= pmp_valid_pulses + 1;
  end

  task automatic send_address_pair(input [1:0] pair_value);
    begin
      @(negedge clk_74a);
      host_clk = 1'b0;
      host_mosi = pair_value[1];
      host_miso = pair_value[0];
      #2.000;
      host_clk = 1'b1;
      #1.000;
    end
  endtask

  task automatic physical_read(
      input [31:0] byte_address,
      input integer scheduled_start,
      output [31:0] response_word,
      output integer actual_start,
      output integer actual_end
  );
    reg [31:0] tx_address;
    integer pair_index;
    integer response_wait;
    begin
      while (clk74_cycle < scheduled_start)
        @(negedge clk_74a);
      if (clk74_cycle > scheduled_start)
        $fatal(1, "missed transaction schedule wanted=%0d actual=%0d",
               scheduled_start, clk74_cycle);

      actual_start = clk74_cycle;
      phy_spiss = 1'b0;
      host_data_oe = 1'b1;
      host_clk_oe = 1'b1;
      host_clk = 1'b1;
      // Low address bit 0 selects a read.  The production bridge forces the
      // two low address bits to zero after decoding this direction bit.
      tx_address = {byte_address[31:2], 2'b00};
      for (pair_index = 15; pair_index >= 0; pair_index = pair_index - 1)
        send_address_pair(tx_address[pair_index*2 +: 2]);

      // Hold the idle-high level while ownership returns to the peripheral.
      host_data_oe = 1'b0;
      host_clk_oe = 1'b0;

      // ST_SEND_N establishes idle high.  The following falling edge is the
      // start of real data; score exactly the next sixteen rising edges.
      response_wait = 0;
      while (phy_spiclk !== 1'b0) begin
        @(negedge clk_74a);
        response_wait = response_wait + 1;
        if (response_wait > 200)
          $fatal(1, "physical response did not start addr=%08x state=%0d spis=%0d rx_done=%b",
                 byte_address, bridge.state, bridge.spis,
                 bridge.rx_byte_done_r_2);
      end
      response_word = 32'd0;
      for (pair_index = 0; pair_index < 16; pair_index = pair_index + 1) begin
        @(posedge phy_spiclk);
        response_word = {response_word[29:0], phy_spimosi, phy_spimiso};
      end

      repeat (4) @(negedge clk_74a);
      phy_spiss = 1'b1;
      actual_end = clk74_cycle;
      if (actual_end >= scheduled_start + CADENCE_CYCLES)
        $fatal(1, "physical read exceeded cadence start=%0d end=%0d budget=%0d",
               scheduled_start, actual_end, CADENCE_CYCLES);
    end
  endtask

  integer next_start;
  integer tx_start;
  integer tx_end;
  integer word_index;
  integer bad_words = 0;
  integer zero_words = 0;
  integer first_bad = -1;
  reg [31:0] first_bad_actual = 32'd0;
  reg [31:0] physical_word;
  reg [31:0] expected_word;
  integer max_transaction_cycles = 0;

  task automatic score_previous_save(input integer previous_word_index);
    begin
      expected_word = expected_save_word(previous_word_index);
      if (physical_word === 32'h0000_0000)
        zero_words = zero_words + 1;
      if (physical_word !== expected_word) begin
        if (first_bad < 0) begin
          first_bad = previous_word_index;
          first_bad_actual = physical_word;
        end
        bad_words = bad_words + 1;
      end
    end
  endtask

  initial begin
    repeat (12) @(negedge clk_74a);
    reset_n = 1'b1;
    repeat (12) @(negedge clk_74a);
    if (USE_SNAPSHOT) begin
      wait (snapshot_ready || snapshot_failed);
      if (snapshot_failed)
        $fatal(1, "snapshot failed before physical stream");
      repeat (4) @(negedge clk_74a);
    end

    next_start = clk74_cycle + 4;

    // First transaction returns the bridge's initial dummy and starts save
    // word zero.  It must not be scored as file payload.
    physical_read(32'h2000_0000, next_start, physical_word, tx_start, tx_end);
    if (physical_word !== 32'h0000_0000)
      $fatal(1, "first pipeline word was not dummy zero: %08x", physical_word);
    if ((tx_end - tx_start) > max_transaction_cycles)
      max_transaction_cycles = tx_end - tx_start;
    next_start = next_start + CADENCE_CYCLES;

    // Each transaction returns the word requested by the preceding one and
    // starts preparation of its own address.  The final duplicate address is
    // the flush transaction that returns the last body word.
    for (word_index = 1; word_index < BODY_WORDS; word_index = word_index + 1) begin
      // Competing boundary hypotheses remain explicit negative models.  A
      // duplicate of the preceding chunk's last address must fail closed; a
      // later rewind must likewise fail even though word[k] is already held.
      if (USE_SNAPSHOT && INJECT_CHUNK_LAST_DUPLICATE &&
          word_index == 256) begin
        physical_read(32'h2000_0000 + (word_index - 1) * 4, next_start,
                      physical_word, tx_start, tx_end);
        repeat (4) @(posedge clk_74a);
        if (!snapshot_failed)
          $fatal(1, "chunk-last duplicate did not fail snapshot");
        $display("PMP CHUNK-LAST DUPLICATE FAILURE PASS word=%0d", word_index - 1);
        $finish;
      end
      physical_read(32'h2000_0000 + word_index * 4, next_start,
                    physical_word, tx_start, tx_end);
      score_previous_save(word_index - 1);
      if (USE_SNAPSHOT && INJECT_BOUNDARY_REWIND && word_index == 256) begin
        next_start = next_start + CADENCE_CYCLES;
        physical_read(32'h2000_0000 + (word_index - 1) * 4, next_start,
                      physical_word, tx_start, tx_end);
        repeat (4) @(posedge clk_74a);
        if (!snapshot_failed)
          $fatal(1, "boundary rewind did not fail snapshot");
        $display("PMP BOUNDARY REWIND FAILURE PASS word=%0d", word_index - 1);
        $finish;
      end
      // Artifact-supported hypothesis model: repeat the first request of each
      // noninitial 1 KiB chunk and discard its response.  This validates RTL
      // compatibility with that model; it is not a captured Pocket trace.
      if (USE_SNAPSHOT && INJECT_BOUNDARY_PRIME_DUPLICATE &&
          word_index != 0 && (word_index & 255) == 0) begin
        for (prime_repeat = 0; prime_repeat < BOUNDARY_PRIME_REPEATS;
             prime_repeat = prime_repeat + 1) begin
          next_start = next_start + CADENCE_CYCLES;
          physical_read(32'h2000_0000 + word_index * 4, next_start,
                        physical_word, tx_start, tx_end);
        end
      end
      if (USE_SNAPSHOT && INTERLEAVE_COMMAND_READ &&
          word_index != 0 && (word_index & 255) == 0) begin
        next_start = next_start + CADENCE_CYCLES;
        physical_read(32'hF800_0000, next_start,
                      physical_word, tx_start, tx_end);
        if (physical_word !== 32'hc0de_f00d)
          $fatal(1, "interleaved command response mismatch: %08x", physical_word);
      end
      if (USE_SNAPSHOT && INJECT_MIDDLE_DUPLICATE && word_index == 2) begin
        next_start = next_start + CADENCE_CYCLES;
        physical_read(32'h2000_0000 + word_index * 4, next_start,
                      physical_word, tx_start, tx_end);
        repeat (4) @(posedge clk_74a);
        if (!snapshot_failed)
          $fatal(1, "physical middle duplicate did not fail snapshot");
        $display("PMP SNAPSHOT MIDDLE-DUPLICATE FAILURE PASS word=%0d", word_index);
        $finish;
      end
      if ((tx_end - tx_start) > max_transaction_cycles)
        max_transaction_cycles = tx_end - tx_start;
      next_start = next_start + CADENCE_CYCLES;
      if ((word_index & 4095) == 0)
        $display("PMP progress payload=%0d/%0d bad=%0d zero=%0d max_tx=%0d",
                 word_index, BODY_WORDS, bad_words, zero_words,
                 max_transaction_cycles);
    end

    physical_read(32'h2000_0000 + (BODY_WORDS - 1) * 4, next_start,
                  physical_word, tx_start, tx_end);
    score_previous_save(BODY_WORDS - 1);
    if ((tx_end - tx_start) > max_transaction_cycles)
      max_transaction_cycles = tx_end - tx_start;
    next_start = next_start + CADENCE_CYCLES;

    if (EXPECT_ALL_ZERO) begin
      if (zero_words != BODY_WORDS)
        $fatal(1, "expected all-zero physical reproduction words=%0d zero=%0d bad=%0d",
               BODY_WORDS, zero_words, bad_words);
      $display("PMP ALL-ZERO REPRO PASS bytes=%0d zero_payload_words=%0d valid=%b",
               BODY_BYTES, zero_words, save_read_bridge_valid);
    end else begin
      if (bad_words != 0 || zero_words != 0)
        $fatal(1, "PMP SAVE FAIL body_words=%0d bad=%0d zero=%0d first=%0d actual=%08x expected=%08x",
               BODY_WORDS, bad_words, zero_words, first_bad, first_bad_actual,
               expected_save_word(first_bad));
      $display("PMP SAVE PASS bytes=%0d payload_words=%0d pmp_reads=%0d max_tx=%0d",
               BODY_BYTES, BODY_WORDS, pmp_read_pulses, max_transaction_cycles);
    end

    if (USE_SNAPSHOT) begin
      repeat (4) @(posedge clk_74a);
      if (snapshot_failed)
        $fatal(1, "snapshot streamer failed during physical transfer");
    end

    if (RUN_RTC) begin
      // RTC is the same top-nibble unloader pipeline.  The transition read
      // returns the prior save-flush request, then prepares RTC word zero.
      physical_read(32'h2100_0000, next_start,
                    physical_word, tx_start, tx_end);
      next_start = next_start + CADENCE_CYCLES;
      for (word_index = 1; word_index < 4; word_index = word_index + 1) begin
        physical_read(32'h2100_0000 + word_index * 4, next_start,
                      physical_word, tx_start, tx_end);
        expected_word = expected_rtc_word(word_index - 1);
        if (physical_word !== expected_word)
          $fatal(1, "PMP RTC mismatch word=%0d actual=%08x expected=%08x",
                 word_index - 1, physical_word, expected_word);
        next_start = next_start + CADENCE_CYCLES;
      end
      physical_read(32'h2100_000c, next_start,
                    physical_word, tx_start, tx_end);
      expected_word = expected_rtc_word(3);
      if (physical_word !== expected_word)
        $fatal(1, "PMP RTC mismatch word=3 actual=%08x expected=%08x",
               physical_word, expected_word);
      $display("PMP RTC PASS payload_words=4");
    end

    $display("PMP PHYSICAL PIPELINE PASS");
    $finish;
  end

  initial begin
    #100000000;
    $fatal(1, "global simulation timeout");
  end
endmodule
