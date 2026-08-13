`timescale 1ns/1ps

module tb_data_loader;

  localparam integer ADDRESS_SIZE = 28;
  localparam [3:0] ACCEPTED_REGION = 4'h2;
  localparam integer EXPECTED_WORDS = 4;

  // Deliberately unrelated clocks. The phase offset avoids same-delta FIFO
  // model races while retaining an asynchronous relationship.
  reg clk_74a = 1'b0;
  reg clk_memory = 1'b0;
  always #6.731 clk_74a = ~clk_74a;
  initial begin
    #0.001;
    forever #4.973 clk_memory = ~clk_memory;
  end

  reg bridge_wr = 1'b0;
  reg bridge_endian_little = 1'b0;
  reg [31:0] bridge_addr = 32'd0;
  reg [31:0] bridge_wr_data = 32'd0;

  wire write_en;
  wire [ADDRESS_SIZE-1:0] write_addr;
  wire [15:0] write_data;
  reg write_ready = 1'b0;
  wire write_busy;

  data_loader #(
      .ADDRESS_MASK_UPPER_4(ACCEPTED_REGION),
      .ADDRESS_SIZE(ADDRESS_SIZE),
      .WRITE_MEM_CLOCK_DELAY(4),
      .WRITE_MEM_EN_CYCLE_LENGTH(1),
      .USE_WRITE_READY(1),
      .OUTPUT_WORD_SIZE(2)
  ) dut (
      .clk_74a(clk_74a),
      .clk_memory(clk_memory),
      .bridge_wr(bridge_wr),
      .bridge_endian_little(bridge_endian_little),
      .bridge_addr(bridge_addr),
      .bridge_wr_data(bridge_wr_data),
      .write_en(write_en),
      .write_addr(write_addr),
      .write_data(write_data),
      .write_ready(write_ready),
      .write_busy(write_busy)
  );

  reg [ADDRESS_SIZE-1:0] expected_addr [0:EXPECTED_WORDS-1];
  reg [15:0] expected_data [0:EXPECTED_WORDS-1];
  integer expected_count = 0;
  integer accepted_count = 0;
  integer blocked_cycles = 0;
  integer timeout = 0;

  reg previous_blocked = 1'b0;
  reg [ADDRESS_SIZE-1:0] previous_blocked_addr = {ADDRESS_SIZE{1'b0}};
  reg [15:0] previous_blocked_data = 16'd0;
  reg drain_active = 1'b0;
  reg reject_phase = 1'b0;

  // Check the ready/valid contract on the exact edge at which the DUT samples
  // write_ready. A blocked request must retain both its enable and payload.
  always @(posedge clk_memory) begin
    if (previous_blocked) begin
      if (!write_en)
        $fatal(1, "write_en dropped before write_ready accepted the request");
      if (write_addr !== previous_blocked_addr || write_data !== previous_blocked_data)
        $fatal(1,
               "blocked payload changed: was addr=%07x data=%04x, now addr=%07x data=%04x",
               previous_blocked_addr, previous_blocked_data, write_addr, write_data);
    end

    if (write_en && !write_ready)
      blocked_cycles = blocked_cycles + 1;

    if (write_en && write_ready) begin
      if (accepted_count >= expected_count)
        $fatal(1, "unexpected loader write addr=%07x data=%04x",
               write_addr, write_data);
      if (write_addr !== expected_addr[accepted_count])
        $fatal(1, "write %0d address mismatch: expected=%07x actual=%07x",
               accepted_count, expected_addr[accepted_count], write_addr);
      if (write_data !== expected_data[accepted_count])
        $fatal(1, "write %0d data mismatch: expected=%04x actual=%04x",
               accepted_count, expected_data[accepted_count], write_data);
      accepted_count = accepted_count + 1;
    end

    previous_blocked = write_en && !write_ready;
    previous_blocked_addr = write_addr;
    previous_blocked_data = write_data;
  end

  // Once draining begins, write_busy must cover every queued or blocked
  // halfword. It may fall only after the final expected acceptance.
  always @(negedge clk_memory) begin
    if (reject_phase && write_busy)
      $fatal(1, "wrong address nibble entered the loader");
    if (drain_active && accepted_count < expected_count && !write_busy)
      $fatal(1, "write_busy dropped while %0d halfwords remained",
             expected_count - accepted_count);
  end

  task automatic append_expected(
      input [27:0] byte_address,
      input [31:0] word_data,
      input little_endian
  );
    begin
      if ((expected_count + 2) > EXPECTED_WORDS)
        $fatal(1, "test expectation array overflow");
      expected_addr[expected_count] = byte_address;
      expected_addr[expected_count + 1] = byte_address + 28'd2;
      if (little_endian) begin
        expected_data[expected_count] = word_data[15:0];
        expected_data[expected_count + 1] = word_data[31:16];
      end else begin
        expected_data[expected_count] = {word_data[23:16], word_data[31:24]};
        expected_data[expected_count + 1] = {word_data[7:0], word_data[15:8]};
      end
      expected_count = expected_count + 2;
    end
  endtask

  // One APF write pulse, followed only by the cycles the loader needs to enqueue
  // its second halfword. Sequential calls therefore drive words at the maximum
  // safe capture rate without waiting for the memory-side drain.
  task automatic pulse_bridge_write(
      input [31:0] address,
      input [31:0] word_data,
      input little_endian
  );
    begin
      @(negedge clk_74a);
      bridge_addr = address;
      bridge_wr_data = word_data;
      bridge_endian_little = little_endian;
      bridge_wr = 1'b1;
      @(negedge clk_74a);
      bridge_wr = 1'b0;
      repeat (2) @(negedge clk_74a);
    end
  endtask

  initial begin : test_sequence
    // Let initialized state settle in both domains.
    repeat (8) @(negedge clk_74a);

    // A different upper nibble must be ignored by this loader instance.
    write_ready = 1'b1;
    reject_phase = 1'b1;
    pulse_bridge_write(32'h3000_0040, 32'hdeaf_beef, 1'b1);
    repeat (20) @(negedge clk_memory);
    reject_phase = 1'b0;
    if (accepted_count != 0 || write_busy)
      $fatal(1, "address filter regression: accepts=%0d busy=%0b",
             accepted_count, write_busy);

    // Queue two contiguous bridge words without allowing the memory-side
    // consumer to drain them. This simultaneously covers maximum-rate input,
    // both endian modes, and all four exact halfword addresses.
    write_ready = 1'b0;
    append_expected(28'h000_0020, 32'h1122_3344, 1'b1);
    pulse_bridge_write(32'h2000_0020, 32'h1122_3344, 1'b1);
    append_expected(28'h000_0024, 32'ha1b2_c3d4, 1'b0);
    pulse_bridge_write(32'h2000_0024, 32'ha1b2_c3d4, 1'b0);

    timeout = 0;
    while (!write_busy) begin
      @(negedge clk_memory);
      timeout = timeout + 1;
      if (timeout > 100)
        $fatal(1, "write_busy never asserted for queued loader data");
    end
    drain_active = 1'b1;

    // Hold the first request blocked long enough to prove payload stability and
    // that busy accounts for both the held request and the remaining FIFO data.
    repeat (17) @(negedge clk_memory);
    if (!write_en)
      $fatal(1, "loader did not present a request during ready stall");
    if (blocked_cycles < 10)
      $fatal(1, "ready stall was not exercised (%0d blocked cycles)", blocked_cycles);

    write_ready = 1'b1;
    timeout = 0;
    while (accepted_count < expected_count) begin
      @(negedge clk_memory);
      timeout = timeout + 1;
      if (timeout > 200)
        $fatal(1, "loader drain timed out (%0d/%0d accepted)",
               accepted_count, expected_count);
    end

    timeout = 0;
    while (write_busy) begin
      @(negedge clk_memory);
      timeout = timeout + 1;
      if (timeout > 20)
        $fatal(1, "write_busy remained set after the FIFO drained");
    end
    drain_active = 1'b0;

    repeat (12) @(negedge clk_memory);
    if (accepted_count != EXPECTED_WORDS)
      $fatal(1, "accepted count mismatch: expected=%0d actual=%0d",
             EXPECTED_WORDS, accepted_count);

    $display("LOADER-TEST PASS accepts=%0d blocked_cycles=%0d",
             accepted_count, blocked_cycles);
    $finish;
  end

endmodule
