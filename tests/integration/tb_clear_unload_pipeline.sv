`timescale 1ns/1ps

// Field-trigger audit: model the first-save path (PSRAM clear to FF, then APF
// bridge export) through the production PSRAM controller and data_unloader.
// The runner locks the production source to the field-proven logic FIFO
// mapping; Quartus map evidence, rather than this behavioral FIFO model,
// verifies that implementation choice.
module tb_clear_unload_pipeline #(
  parameter integer BODY_BYTES = 131072,
  parameter integer FIXED_CADENCE = 0,
  parameter integer CADENCE_CYCLES = 88,
  parameter integer PATTERNED = 0,
  parameter integer SUPPRESS_RESPONSE = 0,
  parameter integer RESPONSE_DELAY_CYCLES = 0
);
  localparam integer BODY_WORDS = BODY_BYTES / 2;
  localparam integer APF_WORDS = BODY_BYTES / 4;

  reg clk_74a = 1'b0;
  reg clk_sys = 1'b0;
  always #6.734 clk_74a = ~clk_74a;
  initial begin
    #0.319;
    forever #4.967 clk_sys = ~clk_sys;
  end

  reg bridge_rd = 1'b0;
  reg bridge_endian_little = 1'b1;
  reg [31:0] bridge_addr = 32'd0;
  wire [31:0] bridge_rd_data;
  wire bridge_rd_data_valid;

  wire read_en;
  wire [27:0] read_addr;
  wire read_ready;
  reg [15:0] read_data = 16'd0;
  reg read_data_valid = 1'b0;

  data_unloader #(
      .ADDRESS_MASK_UPPER_4(4'h2),
      .ADDRESS_SIZE(28),
      .READ_MEM_CLOCK_DELAY(20),
      .INPUT_WORD_SIZE(2)
  ) unloader (
      .clk_74a(clk_74a),
      .clk_memory(clk_sys),
      .bridge_rd(bridge_rd),
      .bridge_endian_little(bridge_endian_little),
      .bridge_addr(bridge_addr),
      .bridge_rd_data(bridge_rd_data),
      .bridge_rd_data_valid(bridge_rd_data_valid),
      .read_en(read_en),
      .read_addr(read_addr),
      .read_ready(read_ready),
      .read_data(read_data),
      .read_data_valid(read_data_valid)
  );

  reg [15:0] memory [0:BODY_WORDS-1];
  integer idx;

  function automatic [15:0] fixture_halfword(input integer halfword_index);
    reg [31:0] mixed;
    begin
      if (!PATTERNED) begin
        fixture_halfword = 16'hffff;
      end else begin
        mixed = (halfword_index * 32'h9e37_79b1) ^
                (halfword_index << 7) ^ 32'ha5c3_5a7d;
        // Keep every halfword nonzero so stale/default zero is unambiguous.
        fixture_halfword = (mixed[15:0] ^ mixed[31:16]) | 16'h0001;
      end
    end
  endfunction

  function automatic [31:0] fixture_apf_word(input integer word_index);
    begin
      fixture_apf_word = {fixture_halfword(word_index * 2 + 1),
                          fixture_halfword(word_index * 2)};
    end
  endfunction

  initial begin
    // Either the exact no-save clear result or a deterministic nonzero image.
    for (idx = 0; idx < BODY_WORDS; idx = idx + 1)
      memory[idx] = fixture_halfword(idx);
  end

  reg psram_read_en = 1'b0;
  wire psram_read_avail;
  wire [15:0] psram_data_out;
  wire psram_busy;
  wire [21:16] cram_a;
  tri [15:0] cram_dq;
  reg cram_model_drive = 1'b0;
  reg [15:0] cram_model_data = 16'd0;
  assign cram_dq = cram_model_drive ? cram_model_data : 16'hzzzz;
  wire cram_clk, cram_adv_n, cram_cre, cram_ce0_n, cram_ce1_n;
  wire cram_oe_n, cram_we_n, cram_ub_n, cram_lb_n;

  reg pending = 1'b0;
  reg [21:0] pending_word_addr = 22'd0;
  reg delayed_response_active = 1'b0;
  integer delayed_response_count = 0;
  reg [15:0] delayed_response_data = 16'd0;
  wire save_unloader_accept = read_en && read_ready;
  assign read_ready = !pending && !delayed_response_active && !psram_busy;

  psram #(.CLOCK_SPEED(100.66)) save_psram (
      .clk(clk_sys),
      .bank_sel(1'b1),
      .addr({1'b0, read_addr[21:1]}),
      .write_en(1'b0),
      .data_in(16'd0),
      .write_high_byte(1'b1),
      .write_low_byte(1'b1),
      .read_en(psram_read_en),
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

  // Production core_top read acceptance/pending/response contract. The
  // external memory model begins driving before the PSRAM sample edge.
  always @(posedge clk_sys) begin
    psram_read_en <= 1'b0;
    read_data_valid <= 1'b0;
    if (delayed_response_active) begin
      if (delayed_response_count == 0) begin
        read_data <= delayed_response_data;
        read_data_valid <= 1'b1;
        delayed_response_active <= 1'b0;
      end else begin
        delayed_response_count <= delayed_response_count - 1;
      end
    end
    if (save_unloader_accept) begin
      pending <= 1'b1;
      pending_word_addr <= read_addr[21:1];
      psram_read_en <= 1'b1;
    end
    if (!cram_oe_n && pending) begin
      cram_model_data <= memory[pending_word_addr];
      cram_model_drive <= 1'b1;
    end else begin
      cram_model_drive <= 1'b0;
    end
    if (psram_read_avail && pending) begin
      pending <= 1'b0;
      cram_model_drive <= 1'b0;
      if (!SUPPRESS_RESPONSE) begin
        if (RESPONSE_DELAY_CYCLES == 0) begin
          read_data <= psram_data_out;
          read_data_valid <= 1'b1;
        end else begin
          delayed_response_data <= psram_data_out;
          delayed_response_count <= RESPONSE_DELAY_CYCLES;
          delayed_response_active <= 1'b1;
        end
      end
    end
  end

  integer requested_words = 0;
  integer returned_words = 0;
  integer zero_words = 0;
  integer bad_words = 0;
  integer first_bad_word = -1;
  reg [31:0] first_bad_data = 32'd0;
  integer timeout;
  integer response_cycle;
  integer max_response_cycles = 0;

  task automatic request_apf_word(input integer word_index);
    begin
      // Capture the previous pipelined response, then pulse the next request.
      @(negedge clk_74a);
      bridge_addr = 32'h2000_0000 + word_index * 4;
      bridge_rd = 1'b1;
      @(negedge clk_74a);
      bridge_rd = 1'b0;
      requested_words = requested_words + 1;

      timeout = 0;
      while (!bridge_rd_data_valid) begin
        @(negedge clk_74a);
        timeout = timeout + 1;
        if (timeout > 300)
          $fatal(1, "APF word %0d response timed out", word_index);
      end
      if (bridge_rd_data === 32'h0000_0000)
        zero_words = zero_words + 1;
      if (bridge_rd_data !== fixture_apf_word(word_index)) begin
        if (first_bad_word < 0) begin
          first_bad_word = word_index;
          first_bad_data = bridge_rd_data;
        end
        bad_words = bad_words + 1;
      end
      returned_words = returned_words + 1;

      // Pocket's minimum read transaction cadence.
      repeat (12) @(negedge clk_74a);
    end
  endtask

  // Model the contract of io_bridge_peripheral exactly: it never waits on
  // bridge_rd_data_valid. A pmp_rd pulse starts preparation of the word that
  // must already be complete when the next host read arrives 88 clocks later.
  task automatic request_apf_word_fixed(input integer word_index);
    begin
      bridge_addr = 32'h2000_0000 + word_index * 4;
      bridge_rd = 1'b1;
      @(negedge clk_74a);
      bridge_rd = 1'b0;

      response_cycle = -1;
      if (bridge_rd_data_valid)
        response_cycle = 1;
      for (timeout = 2; timeout <= CADENCE_CYCLES; timeout = timeout + 1) begin
        @(negedge clk_74a);
        if (response_cycle < 0 && bridge_rd_data_valid)
          response_cycle = timeout;
      end

      if (!bridge_rd_data_valid)
        $fatal(1, "fixed-cadence word %0d was not valid after %0d clocks (suppress=%0d delay=%0d)",
               word_index, CADENCE_CYCLES, SUPPRESS_RESPONSE,
               RESPONSE_DELAY_CYCLES);
      if (response_cycle > max_response_cycles)
        max_response_cycles = response_cycle;
      if (bridge_rd_data === 32'h0000_0000)
        zero_words = zero_words + 1;
      if (bridge_rd_data !== fixture_apf_word(word_index)) begin
        if (first_bad_word < 0) begin
          first_bad_word = word_index;
          first_bad_data = bridge_rd_data;
        end
        bad_words = bad_words + 1;
      end
      requested_words = requested_words + 1;
      returned_words = returned_words + 1;
    end
  endtask

  initial begin
    repeat (20) @(negedge clk_74a);

    if (FIXED_CADENCE) begin
      // We are already on a falling edge here; successive task calls start
      // exactly CADENCE_CYCLES clocks apart.
      for (idx = 0; idx < APF_WORDS; idx = idx + 1) begin
        request_apf_word_fixed(idx);
        if ((idx & 4095) == 0)
          $display("FIXED progress fixture=%s words=%0d max_latency=%0d bad=%0d",
                   PATTERNED ? "PATTERN" : "FF", idx + 1,
                   max_response_cycles, bad_words);
      end
      if (returned_words != APF_WORDS || bad_words != 0 || zero_words != 0)
        $fatal(1, "fixed clear/unload mismatch returned=%0d bad=%0d zero=%0d first=%0d/%08x",
               returned_words, bad_words, zero_words,
               first_bad_word, first_bad_data);
      $display("FIXED-88 EXPORT PASS fixture=%s words=%0d max_latency=%0d",
               PATTERNED ? "PATTERN" : "FF", returned_words,
               max_response_cycles);
      $finish;
    end

    // data_unloader intentionally starts valid with a dummy zero pipeline
    // value. Kick the first read without scoring it.
    bridge_addr = 32'h2000_0000;
    bridge_rd = 1'b1;
    @(negedge clk_74a);
    bridge_rd = 1'b0;
    while (!bridge_rd_data_valid)
      @(negedge clk_74a);

    // The second request receives the first word, continuing the pipelined
    // bridge convention for the whole declared body.
    for (idx = 1; idx < APF_WORDS; idx = idx + 1) begin
      request_apf_word(idx);
      if ((idx & 4095) == 0)
        $display("UNLOAD progress words=%0d zero=%0d bad=%0d",
                 idx, zero_words, bad_words);
    end

    // Flush the final prepared bridge response with a duplicate in-range
    // address. The returned value belongs to the prior (last body) request.
    request_apf_word(APF_WORDS - 1);

    if (returned_words != APF_WORDS || bad_words != 0 || zero_words != 0)
      $fatal(1, "clear/unload mismatch returned=%0d bad=%0d zero=%0d first=%0d/%08x",
             returned_words, bad_words, zero_words,
             first_bad_word, first_bad_data);
    $display("UNLOAD PASS fixture=%s words=%0d",
             PATTERNED ? "PATTERN" : "FF", returned_words);
    $finish;
  end
endmodule
