`timescale 1ns/1ps

module tb_apf_write_ingress;

  localparam [1:0] DEST_ROM  = 2'd1;
  localparam [1:0] DEST_SAVE = 2'd2;
  localparam [1:0] DEST_BIOS = 2'd3;
  localparam integer ROM_DELAY  = 20;
  localparam integer SAVE_DELAY = 20;
  localparam integer BIOS_DELAY = 4;
  localparam integer MAX_HALVES = 16;

  // Deliberately unrelated clocks with a non-zero phase offset.
  reg clk_74a = 1'b0;
  reg clk_memory = 1'b0;
  always #6.731 clk_74a = ~clk_74a;
  initial begin
    #0.137;
    forever #4.973 clk_memory = ~clk_memory;
  end

  reg        bridge_wr = 1'b0;
  reg        bridge_endian_little = 1'b0;
  reg [31:0] bridge_addr = 32'd0;
  reg [31:0] bridge_wr_data = 32'd0;

  wire        write_valid;
  wire [1:0]  write_dest;
  wire [27:0] write_addr;
  wire [15:0] write_data;
  wire        write_busy;
  reg         save_ready = 1'b0;
  wire write_ready = write_dest == DEST_SAVE ? save_ready :
                     write_dest == DEST_ROM  ? 1'b1 :
                     write_dest == DEST_BIOS ? 1'b1 : 1'b0;

  apf_write_ingress #(
      .ROM_WRITE_DELAY(ROM_DELAY),
      .SAVE_WRITE_DELAY(SAVE_DELAY),
      .BIOS_WRITE_DELAY(BIOS_DELAY)
  ) dut (
      .clk_74a(clk_74a),
      .clk_memory(clk_memory),
      .bridge_wr(bridge_wr),
      .bridge_endian_little(bridge_endian_little),
      .bridge_addr(bridge_addr),
      .bridge_wr_data(bridge_wr_data),
      .write_valid(write_valid),
      .write_dest(write_dest),
      .write_addr(write_addr),
      .write_data(write_data),
      .write_ready(write_ready),
      .write_busy(write_busy)
  );

  reg [1:0]  expected_dest [0:MAX_HALVES-1];
  reg [27:0] expected_addr [0:MAX_HALVES-1];
  reg [15:0] expected_data [0:MAX_HALVES-1];
  integer expected_count = 0;
  integer accepted_count = 0;
  integer memory_cycle = 0;
  integer last_accept_cycle = -1000;
  integer blocked_cycles = 0;
  integer timeout = 0;
  reg drain_active = 1'b0;

  reg        previous_blocked = 1'b0;
  reg [1:0]  previous_dest = 2'd0;
  reg [27:0] previous_addr = 28'd0;
  reg [15:0] previous_data = 16'd0;

  function automatic integer delay_for(input [1:0] destination);
    begin
      case (destination)
        DEST_ROM:  delay_for = ROM_DELAY;
        DEST_SAVE: delay_for = SAVE_DELAY;
        DEST_BIOS: delay_for = BIOS_DELAY;
        default:   delay_for = 999;
      endcase
    end
  endfunction

  // Scoreboard at the edge where the ingress and destination both sample the
  // ready/valid transaction.
  always @(posedge clk_memory) begin
    memory_cycle = memory_cycle + 1;

    if (previous_blocked) begin
      if (!write_valid)
        $fatal(1, "write_valid dropped before the stalled save was accepted");
      if (write_dest !== previous_dest || write_addr !== previous_addr ||
          write_data !== previous_data)
        $fatal(1,
               "stalled payload changed: old=%0d/%07x/%04x new=%0d/%07x/%04x",
               previous_dest, previous_addr, previous_data,
               write_dest, write_addr, write_data);
    end

    if (write_valid && !write_ready)
      blocked_cycles = blocked_cycles + 1;

    if (write_valid && write_ready) begin
      if (write_dest != DEST_ROM && write_dest != DEST_SAVE && write_dest != DEST_BIOS)
        $fatal(1, "invalid destination fired: %0d", write_dest);
      if (accepted_count >= expected_count)
        $fatal(1, "unexpected write %0d/%07x/%04x",
               write_dest, write_addr, write_data);
      if (write_dest !== expected_dest[accepted_count] ||
          write_addr !== expected_addr[accepted_count] ||
          write_data !== expected_data[accepted_count])
        $fatal(1,
               "write %0d mismatch: expected=%0d/%07x/%04x actual=%0d/%07x/%04x",
               accepted_count, expected_dest[accepted_count],
               expected_addr[accepted_count], expected_data[accepted_count],
               write_dest, write_addr, write_data);

      if (accepted_count > 0 &&
          (memory_cycle - last_accept_cycle) < delay_for(expected_dest[accepted_count-1]))
        $fatal(1,
               "write spacing too short after destination %0d: expected >=%0d actual=%0d",
               expected_dest[accepted_count-1],
               delay_for(expected_dest[accepted_count-1]),
               memory_cycle - last_accept_cycle);

      last_accept_cycle = memory_cycle;
      accepted_count = accepted_count + 1;
    end

    previous_blocked = write_valid && !write_ready;
    previous_dest = write_dest;
    previous_addr = write_addr;
    previous_data = write_data;
  end

  always @(negedge clk_memory) begin
    if (drain_active && accepted_count < expected_count && !write_busy)
      $fatal(1, "write_busy dropped with %0d halfwords outstanding",
             expected_count - accepted_count);
  end

  task automatic append_expected(
      input [1:0] destination,
      input [27:0] byte_address,
      input [31:0] word_data,
      input little_endian
  );
    begin
      if (expected_count + 2 > MAX_HALVES)
        $fatal(1, "expectation array overflow");
      expected_dest[expected_count] = destination;
      expected_dest[expected_count+1] = destination;
      expected_addr[expected_count] = byte_address;
      expected_addr[expected_count+1] = byte_address + 28'd2;
      if (little_endian) begin
        expected_data[expected_count] = word_data[15:0];
        expected_data[expected_count+1] = word_data[31:16];
      end else begin
        expected_data[expected_count] = {word_data[23:16], word_data[31:24]};
        expected_data[expected_count+1] = {word_data[7:0], word_data[15:8]};
      end
      expected_count = expected_count + 2;
    end
  endtask

  // Change every bridge input as soon as the capture pulse ends.  Correct
  // output therefore proves that address, endian, destination, and all data
  // bytes were captured atomically rather than sampled during the FIFO write.
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
      bridge_addr = 32'hf000_0bad;
      bridge_wr_data = ~word_data;
      bridge_endian_little = ~little_endian;
    end
  endtask

  initial begin : test_sequence
    repeat (8) @(negedge clk_74a);

    // Command, save-state, and unrelated regions must not enter the ingress.
    pulse_bridge_write(32'h0000_0010, 32'hdead_beef, 1'b1);
    pulse_bridge_write(32'h4000_0020, 32'h0123_4567, 1'b0);
    pulse_bridge_write(32'hf800_0000, 32'h89ab_cdef, 1'b1);
    repeat (24) @(negedge clk_memory);
    if (write_busy || accepted_count != 0)
      $fatal(1, "rejected region entered ingress: busy=%0b accepts=%0d",
             write_busy, accepted_count);

    // Interleave all destinations.  SAVE is deliberately second so that its
    // stalled first halfword head-of-line blocks later ROM and BIOS words.
    append_expected(DEST_ROM,  28'h000_0020, 32'h1122_3344, 1'b1);
    pulse_bridge_write(32'h1000_0020, 32'h1122_3344, 1'b1);
    append_expected(DEST_SAVE, 28'h100_0040, 32'ha1b2_c3d4, 1'b0);
    pulse_bridge_write(32'h2100_0040, 32'ha1b2_c3d4, 1'b0);
    append_expected(DEST_ROM,  28'h000_0024, 32'h5566_7788, 1'b0);
    pulse_bridge_write(32'h1000_0024, 32'h5566_7788, 1'b0);
    append_expected(DEST_BIOS, 28'h000_0080, 32'hcafe_babe, 1'b1);
    pulse_bridge_write(32'h3000_0080, 32'hcafe_babe, 1'b1);
    append_expected(DEST_SAVE, 28'h000_0044, 32'h0bad_f00d, 1'b1);
    pulse_bridge_write(32'h2000_0044, 32'h0bad_f00d, 1'b1);
    append_expected(DEST_BIOS, 28'h000_0084, 32'h1020_3040, 1'b0);
    pulse_bridge_write(32'h3000_0084, 32'h1020_3040, 1'b0);

    timeout = 0;
    while (!write_busy) begin
      @(negedge clk_memory);
      timeout = timeout + 1;
      if (timeout > 100)
        $fatal(1, "write_busy never asserted");
    end
    drain_active = 1'b1;

    timeout = 0;
    while (!(write_valid && write_dest == DEST_SAVE)) begin
      @(negedge clk_memory);
      timeout = timeout + 1;
      if (timeout > 200)
        $fatal(1, "stalled save request never reached the head of line");
    end
    if (accepted_count != 2)
      $fatal(1, "save did not follow exactly one ROM word: accepts=%0d",
             accepted_count);

    // Later ROM/BIOS words are already queued. Hold save long enough to prove
    // payload stability, busy coverage, and lossless head-of-line blocking.
    repeat (25) begin
      @(negedge clk_memory);
      if (!write_valid || write_dest != DEST_SAVE || !write_busy)
        $fatal(1, "save stall was not held with ingress busy");
    end
    if (blocked_cycles < 20)
      $fatal(1, "save backpressure was not exercised (%0d cycles)", blocked_cycles);
    save_ready = 1'b1;

    timeout = 0;
    while (accepted_count < expected_count) begin
      @(negedge clk_memory);
      timeout = timeout + 1;
      if (timeout > 1000)
        $fatal(1, "ingress drain timed out (%0d/%0d)",
               accepted_count, expected_count);
    end

    // The final BIOS acceptance still owns the dispatcher for its entire
    // four-cycle cooldown; busy may fall only after that barrier expires.
    if (!write_busy)
      $fatal(1, "busy dropped on the final acceptance");
    repeat (BIOS_DELAY-1) begin
      @(negedge clk_memory);
      if (!write_busy)
        $fatal(1, "busy dropped inside the final BIOS cooldown");
    end

    timeout = 0;
    while (write_busy) begin
      @(negedge clk_memory);
      timeout = timeout + 1;
      if (timeout > 20)
        $fatal(1, "busy remained asserted after final cooldown");
    end
    drain_active = 1'b0;

    repeat (12) @(negedge clk_memory);
    if (accepted_count != expected_count)
      $fatal(1, "accepted count mismatch: expected=%0d actual=%0d",
             expected_count, accepted_count);

    $display("SHARED-INGRESS TEST PASS halves=%0d blocked=%0d",
             accepted_count, blocked_cycles);
    $finish;
  end

endmodule
