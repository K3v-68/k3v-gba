`timescale 1ns/1ps

module tb_data_unloader;

  localparam integer ADDRESS_SIZE = 28;
  localparam integer BODY_BYTES_FULL = 128 * 1024;
  localparam integer BODY_WORDS_FULL = BODY_BYTES_FULL / 2;
  localparam [31:0] BRIDGE_BASE = 32'h2000_0000;
  localparam integer BRIDGE_TIMEOUT_CYCLES = 10000;
  localparam integer STALL_PROOF_CYCLES = 1000;

  // Deliberately unrelated clocks. Their edges do not periodically coincide.
  reg clk_74a = 1'b0;
  reg clk_memory = 1'b0;
  always #6.731 clk_74a = ~clk_74a;
  // The 1 ps phase offset also prevents exact same-delta edge races in the
  // intentionally lightweight FIFO model during very long full-mode runs.
  initial begin
    #0.001;
    forever #4.973 clk_memory = ~clk_memory;
  end

  reg bridge_rd = 1'b0;
  // core_top ties this low, so exercise the byte ordering used on hardware.
  reg bridge_endian_little = 1'b0;
  reg [31:0] bridge_addr = BRIDGE_BASE;
  wire [31:0] bridge_rd_data;
  wire bridge_rd_data_valid;

  wire read_en;
  wire [ADDRESS_SIZE-1:0] read_addr;
  reg read_ready = 1'b0;
  reg [15:0] read_data = 16'h0000;
  reg read_data_valid = 1'b0;

  data_unloader #(
      .ADDRESS_MASK_UPPER_4(4'h2),
      .ADDRESS_SIZE(ADDRESS_SIZE),
      .READ_MEM_CLOCK_DELAY(20),
      .INPUT_WORD_SIZE(2)
  ) dut (
      .clk_74a(clk_74a),
      .clk_memory(clk_memory),
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

  reg [15:0] memory [0:BODY_WORDS_FULL-1];

  integer accepted_count = 0;
  integer response_count = 0;
  integer response_fifo_write_count = 0;
  integer bridge_completion_count = 0;
  integer blocked_request_cycles = 0;
  integer long_latency_transactions = 0;
  integer compared_byte_count = 0;

  integer configured_max_busy = 8;
  integer configured_max_latency = 8;
  reg configured_force_long = 1'b0;
  reg [31:0] responder_prng = 32'h6d2b_79f5;

  reg response_outstanding = 1'b0;
  reg response_suppressed = 1'b0;
  reg suppress_next_response = 1'b0;
  reg [ADDRESS_SIZE-1:0] pending_address = {ADDRESS_SIZE{1'b0}};
  integer response_delay_remaining = 0;
  integer ready_busy_remaining = 11;

  reg previous_blocked = 1'b0;
  reg [ADDRESS_SIZE-1:0] previous_blocked_address = {ADDRESS_SIZE{1'b0}};
  reg previous_data_write_req = 1'b0;

  reg previous_bridge_rd = 1'b0;
  reg previous_bridge_valid = 1'b1;
  reg bridge_transaction_active = 1'b0;
  integer bridge_response_baseline = 0;

  function automatic [31:0] xorshift32(input [31:0] value);
    reg [31:0] mixed;
    begin
      mixed = (value == 0) ? 32'h1a2b_3c4d : value;
      mixed = mixed ^ (mixed << 13);
      mixed = mixed ^ (mixed >> 17);
      mixed = mixed ^ (mixed << 5);
      xorshift32 = mixed;
    end
  endfunction

  function automatic [15:0] fixture_word(
      input integer fixture_kind,
      input integer word_index,
      input [31:0] fixture_seed
  );
    reg [31:0] mixed;
    begin
      case (fixture_kind)
        0: fixture_word = 16'ha55a ^ (word_index * 16'h1f3d) ^
                          (word_index >> 3) ^ (word_index << 7);
        1: begin
          mixed = fixture_seed ^ (word_index * 32'h9e37_79b9);
          mixed = xorshift32(mixed);
          mixed = xorshift32(mixed ^ 32'h7f4a_7c15);
          fixture_word = mixed[31:16] ^ mixed[15:0];
        end
        2: fixture_word = 16'hffff;
        default: fixture_word = 16'h0000;
      endcase
    end
  endfunction

  // Memory responder and request-contract assertions. A request is accepted
  // only on read_en && read_ready. Exactly one later read_data_valid pulse is
  // generated for it unless the explicit missing-response regression is active.
  always @(posedge clk_memory) begin : memory_responder
    integer selected_delay;
    integer selected_busy;

    read_data_valid <= 1'b0;

    if (previous_blocked) begin
      if (!read_en) begin
        $fatal(1, "read_en dropped before a blocked request was accepted");
      end
      if (read_addr !== previous_blocked_address) begin
        $fatal(1, "read_addr changed while blocked: was %08x, now %08x",
               previous_blocked_address, read_addr);
      end
    end

    if (read_en && !read_ready) blocked_request_cycles = blocked_request_cycles + 1;
    previous_blocked = read_en && !read_ready;
    previous_blocked_address = read_addr;

    if (read_en && read_ready) begin
      if (response_outstanding) begin
        $fatal(1, "DUT issued a second accepted request before the first response");
      end
      if (read_addr[0] != 1'b0 || read_addr >= BODY_BYTES_FULL) begin
        $fatal(1, "DUT issued an invalid 16-bit memory address: %08x", read_addr);
      end

      accepted_count = accepted_count + 1;
      response_outstanding = 1'b1;
      pending_address = read_addr;
      read_ready <= 1'b0;

      if (suppress_next_response) begin
        suppress_next_response = 1'b0;
        response_suppressed = 1'b1;
        response_delay_remaining = 0;
      end else begin
        response_suppressed = 1'b0;
        responder_prng = xorshift32(responder_prng);
        if (configured_max_latency == 0)
          selected_delay = 0;
        else
          selected_delay = responder_prng % (configured_max_latency + 1);

        // Deterministically force some responses beyond the obsolete fixed
        // 20-cycle assumption while retaining random latency for the rest.
        if (configured_force_long && ((accepted_count % 13) == 0))
          selected_delay = configured_max_latency;
        response_delay_remaining = selected_delay;
        if (selected_delay > 20)
          long_latency_transactions = long_latency_transactions + 1;
      end
    end else if (response_outstanding) begin
      read_ready <= 1'b0;
      if (!response_suppressed) begin
        if (response_delay_remaining > 0) begin
          response_delay_remaining = response_delay_remaining - 1;
        end else begin
          read_data <= memory[pending_address >> 1];
          read_data_valid <= 1'b1;
          response_count = response_count + 1;
          if (response_count > accepted_count) begin
            $fatal(1, "memory response had no unique accepted request");
          end
          response_outstanding = 1'b0;

          responder_prng = xorshift32(responder_prng);
          if (configured_max_busy == 0)
            selected_busy = 0;
          else
            selected_busy = responder_prng % (configured_max_busy + 1);
          if (configured_force_long && ((response_count % 17) == 0))
            selected_busy = configured_max_busy;
          ready_busy_remaining = selected_busy;
        end
      end
    end else if (ready_busy_remaining > 0) begin
      read_ready <= 1'b0;
      ready_busy_remaining = ready_busy_remaining - 1;
    end else begin
      read_ready <= 1'b1;
    end
  end

  // A write into the response CDC FIFO must be backed by a previously emitted
  // read_data_valid pulse. This catches fabricated/default memory words.
  always @(posedge clk_memory) begin
    if (dut.data_write_req && !previous_data_write_req) begin
      response_fifo_write_count = response_fifo_write_count + 1;
      if (response_fifo_write_count > response_count) begin
        $fatal(1, "response FIFO write occurred before valid memory data");
      end
    end
    previous_data_write_req = dut.data_write_req;
  end

  // Independently enforce the bridge-side contract: a completion may not be
  // advertised until exactly two valid 16-bit memory responses have arrived.
  always @(posedge clk_74a) begin
    if (!previous_bridge_rd && bridge_rd && bridge_addr[31:28] == 4'h2) begin
      if (bridge_transaction_active) begin
        $fatal(1, "overlapping bridge transactions in serialized test driver");
      end
      bridge_transaction_active = 1'b1;
      bridge_response_baseline = response_count;
    end

    if (!previous_bridge_valid && bridge_rd_data_valid) begin
      if (!bridge_transaction_active) begin
        $fatal(1, "bridge_rd_data_valid rose without an active request");
      end
      if ((response_count - bridge_response_baseline) != 2) begin
        $fatal(1,
               "bridge completion used %0d valid halfwords instead of 2",
               response_count - bridge_response_baseline);
      end
      bridge_transaction_active = 1'b0;
      bridge_completion_count = bridge_completion_count + 1;
    end

    previous_bridge_rd = bridge_rd;
    previous_bridge_valid = bridge_rd_data_valid;
  end

  task automatic begin_bridge_read(
      input [27:0] byte_offset,
      output integer response_baseline
  );
    integer timeout;
    begin
      timeout = 0;
      while (!bridge_rd_data_valid) begin
        @(negedge clk_74a);
        timeout = timeout + 1;
        if (timeout > BRIDGE_TIMEOUT_CYCLES)
          $fatal(1, "prior bridge transaction did not complete");
      end

      response_baseline = response_count;
      @(negedge clk_74a);
      bridge_addr = BRIDGE_BASE | byte_offset;
      bridge_rd = 1'b1;
      @(negedge clk_74a);
      bridge_rd = 1'b0;

      timeout = 0;
      while (bridge_rd_data_valid) begin
        @(negedge clk_74a);
        timeout = timeout + 1;
        if (timeout > 8)
          $fatal(1, "bridge_rd_data_valid did not clear at request start");
      end
    end
  endtask

  task automatic finish_bridge_read(
      input integer response_baseline,
      output reg [31:0] returned_data
  );
    integer timeout;
    begin
      timeout = 0;
      while (!bridge_rd_data_valid) begin
        @(negedge clk_74a);
        timeout = timeout + 1;
        if ((response_count - response_baseline) > 2)
          $fatal(1, "more than two responses consumed by one bridge word");
        if (timeout > BRIDGE_TIMEOUT_CYCLES)
          $fatal(1, "bridge read timed out after %0d cycles", timeout);
      end

      if ((response_count - response_baseline) != 2) begin
        $fatal(1, "bridge valid preceded complete memory data (%0d/2 halfwords)",
               response_count - response_baseline);
      end
      returned_data = bridge_rd_data;
    end
  endtask

  task automatic fill_fixture(
      input integer fixture_kind,
      input integer body_bytes,
      input [31:0] fixture_seed
  );
    integer word_index;
    begin
      for (word_index = 0; word_index < (body_bytes / 2); word_index = word_index + 1)
        memory[word_index] = fixture_word(fixture_kind, word_index, fixture_seed);
    end
  endtask

  task automatic run_fixture(
      input integer fixture_kind,
      input integer body_bytes,
      input [31:0] fixture_seed
  );
    integer byte_offset;
    integer response_baseline;
    integer fixture_blocked_baseline;
    reg [31:0] actual_data;
    reg [31:0] memory_order_data;
    reg [31:0] expected_data;
    reg [31:0] expected_digest;
    reg [31:0] actual_digest;
    begin
      case (fixture_kind)
        0: begin
          configured_max_busy = 11;
          configured_max_latency = 12;
          configured_force_long = 1'b0;
        end
        1: begin
          configured_max_busy = 47;
          configured_max_latency = 73;
          configured_force_long = 1'b1;
        end
        default: begin
          configured_max_busy = 61;
          configured_max_latency = 91;
          configured_force_long = 1'b1;
        end
      endcase

      responder_prng = fixture_seed ^ 32'hd00d_feed;
      fill_fixture(fixture_kind, body_bytes, fixture_seed);
      fixture_blocked_baseline = blocked_request_cycles;
      expected_digest = 32'h0000_0000;
      actual_digest = 32'h0000_0000;

      $display("SAVE-TEST fixture=%0d bytes=%0d max_busy=%0d max_latency=%0d",
               fixture_kind, body_bytes, configured_max_busy, configured_max_latency);

      for (byte_offset = 0; byte_offset < body_bytes; byte_offset = byte_offset + 4) begin
        begin_bridge_read(byte_offset[27:0], response_baseline);
        finish_bridge_read(response_baseline, actual_data);
        memory_order_data = {memory[(byte_offset >> 1) + 1], memory[byte_offset >> 1]};
        expected_data = bridge_endian_little ? memory_order_data :
          {memory_order_data[7:0], memory_order_data[15:8],
           memory_order_data[23:16], memory_order_data[31:24]};

        if (actual_data !== expected_data) begin
          $fatal(1,
                 "byte mismatch fixture=%0d offset=%0d expected=%08x actual=%08x",
                 fixture_kind, byte_offset, expected_data, actual_data);
        end
        compared_byte_count = compared_byte_count + 4;
        expected_digest = {expected_digest[30:0], expected_digest[31]} ^ expected_data;
        actual_digest = {actual_digest[30:0], actual_digest[31]} ^ actual_data;
      end

      if (expected_digest !== actual_digest)
        $fatal(1, "fixture digest mismatch despite per-word comparisons");
      if (blocked_request_cycles == fixture_blocked_baseline)
        $fatal(1, "fixture did not exercise read_ready backpressure");

      $display("SAVE-TEST fixture=%0d PASS digest=%08x blocked_cycles=%0d",
               fixture_kind, actual_digest,
               blocked_request_cycles - fixture_blocked_baseline);
    end
  endtask

  task automatic run_missing_response_regression;
    integer response_baseline;
    integer accepted_baseline;
    integer cycle_index;
    reg [31:0] seeded_data;
    reg [31:0] held_data;
    begin
      configured_max_busy = 3;
      configured_max_latency = 4;
      configured_force_long = 1'b0;
      responder_prng = 32'h1357_9bdf;
      memory[0] = 16'h51a7;
      memory[1] = 16'hc39d;
      memory[2] = 16'h2468;
      memory[3] = 16'hace1;

      // Seed the output with conspicuously nonzero valid data so a fabricated
      // zero/stale completion during the missing-response phase is visible.
      begin_bridge_read(28'h0000000, response_baseline);
      finish_bridge_read(response_baseline, seeded_data);
      if (seeded_data !== 32'ha751_9dc3)
        $fatal(1, "failed to seed missing-response regression: %08x", seeded_data);

      accepted_baseline = accepted_count;
      response_baseline = response_count;
      suppress_next_response = 1'b1;
      begin_bridge_read(28'h0000004, cycle_index);
      held_data = bridge_rd_data;

      for (cycle_index = 0; cycle_index < STALL_PROOF_CYCLES;
           cycle_index = cycle_index + 1) begin
        @(negedge clk_74a);
        if (bridge_rd_data_valid)
          $fatal(1, "missing memory response incorrectly produced bridge valid");
        if (bridge_rd_data !== held_data)
          $fatal(1, "bridge data changed while its memory response was missing");
      end

      if (response_count != response_baseline)
        $fatal(1, "missing-response regression emitted unexpected memory data");
      if (accepted_count != (accepted_baseline + 1))
        $fatal(1, "DUT accepted %0d requests while first response was missing",
               accepted_count - accepted_baseline);
      if (!response_outstanding || !response_suppressed)
        $fatal(1, "memory model did not retain the intentionally unanswered request");

      $display("SAVE-TEST missing-response PASS: stalled %0d bridge cycles, data=%08x",
               STALL_PROOF_CYCLES, held_data);
    end
  endtask

  initial begin : test_sequence
    integer body_bytes;
    integer seed_value;
    integer expected_requests;
    reg stall_only;

    body_bytes = 4096;
    seed_value = 32'h4b1d_2e3f;
    stall_only = $test$plusargs("STALL_ONLY");
    if ($test$plusargs("FULL")) body_bytes = BODY_BYTES_FULL;
    if ($value$plusargs("BYTES=%d", body_bytes)) begin end
    if ($value$plusargs("SEED=%d", seed_value)) begin end

    if (body_bytes <= 0 || body_bytes > BODY_BYTES_FULL || (body_bytes % 4) != 0)
      $fatal(1, "BYTES must be a positive multiple of four no larger than %0d",
             BODY_BYTES_FULL);

    // Let initial values cross both asynchronous domains before driving work.
    repeat (8) @(negedge clk_74a);

    if (stall_only) begin
      run_missing_response_regression();
      $display("SAVE-TEST PASS mode=missing-response accepts=%0d responses=%0d",
               accepted_count, response_count);
      $finish;
    end

    run_fixture(0, body_bytes, seed_value ^ 32'h1111_1111);
    run_fixture(1, body_bytes, seed_value ^ 32'h2222_2222);
    run_fixture(2, body_bytes, seed_value ^ 32'h3333_3333);

    // The bridge monitor observes registered valid on the following bridge
    // edge; allow that final bookkeeping edge before checking totals.
    @(negedge clk_74a);

    expected_requests = (3 * body_bytes) / 2;
    if (accepted_count != expected_requests || response_count != expected_requests)
      $fatal(1, "request/response totals mismatch expected=%0d accepted=%0d responses=%0d",
             expected_requests, accepted_count, response_count);
    if (response_fifo_write_count != response_count)
      $fatal(1, "valid responses=%0d but response FIFO writes=%0d",
             response_count, response_fifo_write_count);
    if (long_latency_transactions == 0)
      $fatal(1, "long-latency paths were not exercised");
    if (bridge_completion_count != ((3 * body_bytes) / 4))
      $fatal(1, "bridge completion count mismatch: %0d", bridge_completion_count);

    $display("SAVE-TEST PASS mode=%s bytes_per_fixture=%0d compared_bytes=%0d",
             (body_bytes == BODY_BYTES_FULL) ? "full" : "quick",
             body_bytes, compared_byte_count);
    $display("SAVE-TEST totals accepts=%0d responses=%0d fifo_writes=%0d long=%0d blocked=%0d",
             accepted_count, response_count, response_fifo_write_count,
             long_latency_transactions, blocked_request_cycles);
    $finish;
  end

endmodule
