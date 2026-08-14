`timescale 1ns/1ps

module tb_save_snapshot #(
  parameter integer SUPPRESS_SOURCE_WORD = -1,
  parameter integer CORRUPT_READBACK_WORD = -1,
  parameter integer RESPONSE_RELEASE_HOLD = 0,
  parameter integer SOURCE_ACCEPT_DELAY = 0,
  parameter integer SOURCE_ABORT_DRAIN_DELAY = 0,
  parameter integer TEST_OUT_OF_ORDER = 0,
  parameter integer TEST_MIDDLE_DUPLICATE = 0,
  parameter integer TEST_ABORT_DURING_COPY = 0,
  parameter integer DUT_SRAM_WAIT_CYCLES = 3,
  parameter integer SRAM_ACCESS_NS = 0,
  parameter integer EXPECT_FAILURE = 0
);
  localparam integer HALFWORDS = 16;
  localparam integer BODY_WORDS = HALFWORDS / 2;

  reg clk = 1'b0;
  always #5 clk = ~clk;

  reg reset_n = 1'b0;
  reg start = 1'b0;
  wire busy;
  wire ready;
  wire failed;

  wire source_read;
  wire [16:0] source_addr;
  reg source_accepted = 1'b0;
  reg source_idle = 1'b1;
  reg [15:0] source_data = 16'd0;
  reg source_data_valid = 1'b0;

  reg [31:0] bridge_addr = 32'h2000_0000;
  reg bridge_rd = 1'b0;
  wire [31:0] bridge_rd_data;
  wire bridge_rd_data_valid;

  wire [16:0] sram_a;
  tri [15:0] sram_dq;
  wire sram_oe_n;
  wire sram_we_n;
  wire sram_ub_n;
  wire sram_lb_n;

  reg [15:0] source_mem [0:HALFWORDS-1];
  reg [15:0] sram_mem [0:HALFWORDS-1];
  integer index;
  integer response_delay = -1;
  integer release_delay = 0;
  integer accept_delay = 0;
  reg source_seen = 1'b0;
  integer write_low_cycles = 0;
  reg previous_sram_we_n = 1'b1;
  reg source_was_active = 1'b0;
  integer source_drain_delay = 0;

  wire corrupt_read = CORRUPT_READBACK_WORD >= 0 &&
                      sram_a == CORRUPT_READBACK_WORD;
  assign #(SRAM_ACCESS_NS) sram_dq = !sram_oe_n ?
      (corrupt_read ? (sram_mem[sram_a] ^ 16'h0001) : sram_mem[sram_a]) :
      16'hzzzz;

  always @(posedge clk) begin
    if (source_read) begin
      source_idle <= 1'b0;
      source_was_active <= 1'b1;
      source_drain_delay <= 0;
    end else if (source_was_active) begin
      if (source_drain_delay < SOURCE_ABORT_DRAIN_DELAY) begin
        source_idle <= 1'b0;
        source_drain_delay <= source_drain_delay + 1;
      end else begin
        source_idle <= 1'b1;
        source_was_active <= 1'b0;
      end
    end else begin
      source_idle <= 1'b1;
    end
  end

  always @(posedge clk) begin
    previous_sram_we_n <= sram_we_n;
    if (!sram_we_n)
      write_low_cycles <= write_low_cycles + 1;
    else if (!previous_sram_we_n) begin
      if (write_low_cycles < DUT_SRAM_WAIT_CYCLES)
        $fatal(1, "SRAM WE pulse too short cycles=%0d required=%0d",
               write_low_cycles, DUT_SRAM_WAIT_CYCLES);
      write_low_cycles <= 0;
    end
    if (!sram_we_n) begin
      if (!sram_lb_n) sram_mem[sram_a][7:0] <= sram_dq[7:0];
      if (!sram_ub_n) sram_mem[sram_a][15:8] <= sram_dq[15:8];
    end
  end

  // Four-phase bundled-data source: hold valid/data until request drops.
  always @(posedge clk) begin
    if (!source_read) begin
      source_accepted <= 1'b0;
      accept_delay <= 0;
      if (source_data_valid && release_delay < RESPONSE_RELEASE_HOLD)
        release_delay <= release_delay + 1;
      else begin
        source_data_valid <= 1'b0;
        source_seen <= 1'b0;
        response_delay <= -1;
        release_delay <= 0;
      end
    end else if (!source_accepted) begin
      if (accept_delay >= SOURCE_ACCEPT_DELAY)
        source_accepted <= 1'b1;
      else
        accept_delay <= accept_delay + 1;
    end else if (!source_seen) begin
      source_seen <= 1'b1;
      response_delay <= 3;
    end else if (!source_data_valid && response_delay > 0) begin
      response_delay <= response_delay - 1;
    end else if (!source_data_valid && response_delay == 0) begin
      response_delay <= -1;
      if (source_addr != SUPPRESS_SOURCE_WORD) begin
        source_data <= source_mem[source_addr];
        source_data_valid <= 1'b1;
      end
    end
  end

  save_snapshot #(
    .SRAM_WAIT_CYCLES(DUT_SRAM_WAIT_CYCLES),
    .SOURCE_TIMEOUT_CYCLES(64)
  ) dut (
    .clk(clk),
    .reset_n(reset_n),
    .start(start),
    .word_count(17'd16),
    .busy(busy),
    .ready(ready),
    .failed(failed),
    .source_read(source_read),
    .source_addr(source_addr),
    .source_accepted(source_accepted),
    .source_idle(source_idle),
    .source_data(source_data),
    .source_data_valid(source_data_valid),
    .bridge_endian_little(1'b1),
    .bridge_addr(bridge_addr),
    .bridge_rd(bridge_rd),
    .bridge_rd_data(bridge_rd_data),
    .bridge_rd_data_valid(bridge_rd_data_valid),
    .sram_a(sram_a),
    .sram_dq(sram_dq),
    .sram_oe_n(sram_oe_n),
    .sram_we_n(sram_we_n),
    .sram_ub_n(sram_ub_n),
    .sram_lb_n(sram_lb_n)
  );

  task automatic request_bridge_word;
    input integer word_index;
    reg [31:0] expected;
    begin
      expected = {source_mem[word_index * 2 + 1], source_mem[word_index * 2]};
      @(negedge clk);
      bridge_addr = 32'h2000_0000 + word_index * 4;
      bridge_rd = 1'b1;
      @(negedge clk);
      if (!bridge_rd_data_valid)
        $fatal(1, "prefetched word %0d was not immediately valid", word_index);
      if (bridge_rd_data !== expected)
        $fatal(1, "bridge word %0d mismatch got=%08x expected=%08x",
               word_index, bridge_rd_data, expected);
      bridge_rd = 1'b0;
      repeat (86) @(negedge clk);
    end
  endtask

  initial begin
    for (index = 0; index < HALFWORDS; index = index + 1) begin
      source_mem[index] = 16'h4100 ^ (index * 16'h0137);
      sram_mem[index] = 16'hxxxx;
    end

    repeat (4) @(posedge clk);
    reset_n = 1'b1;
    @(posedge clk);
    start = 1'b1;

    if (TEST_ABORT_DURING_COPY) begin
      wait (source_read && source_addr == 3);
      start = 1'b0;
      repeat (3) @(posedge clk);
      if (busy || ready || failed || source_read || !sram_oe_n || !sram_we_n)
        $fatal(1, "active snapshot did not abort safely");
      start = 1'b1;
    end

    wait (ready || failed);
    if (EXPECT_FAILURE) begin
      if (!failed || ready)
        $fatal(1, "expected fail-closed result ready=%b failed=%b", ready, failed);
      if (bridge_rd_data_valid)
        $fatal(1, "failed snapshot exposed bridge data");
      $display("SAVE SNAPSHOT EXPECTED FAILURE PASS suppress=%0d corrupt=%0d",
               SUPPRESS_SOURCE_WORD, CORRUPT_READBACK_WORD);
      $finish;
    end

    if (failed || !ready)
      $fatal(1, "healthy snapshot did not authorize");
    for (index = 0; index < HALFWORDS; index = index + 1)
      if (sram_mem[index] !== source_mem[index])
        $fatal(1, "SRAM mismatch index=%0d got=%04x expected=%04x",
               index, sram_mem[index], source_mem[index]);

    if (TEST_OUT_OF_ORDER) begin
      @(negedge clk);
      bridge_addr = 32'h2000_0004;
      bridge_rd = 1'b1;
      @(negedge clk);
      bridge_rd = 1'b0;
      repeat (2) @(posedge clk);
      if (!failed || ready)
        $fatal(1, "out-of-order stream did not fail closed");
      $display("SAVE SNAPSHOT OUT-OF-ORDER FAILURE PASS");
      $finish;
    end

    if (TEST_MIDDLE_DUPLICATE) begin
      request_bridge_word(0);
      @(negedge clk);
      bridge_addr = 32'h2000_0000;
      bridge_rd = 1'b1;
      @(negedge clk);
      bridge_rd = 1'b0;
      repeat (2) @(posedge clk);
      if (!failed || ready)
        $fatal(1, "middle duplicate did not fail closed");
      $display("SAVE SNAPSHOT MIDDLE-DUPLICATE FAILURE PASS");
      $finish;
    end

    // Ready proves full readback plus a cached word zero; every following word
    // must be ready before the fixed 88-cycle physical cadence.
    for (index = 0; index < BODY_WORDS; index = index + 1)
      request_bridge_word(index);

    // The physical bridge repeats the terminal address only to shift out its
    // held word. Treat it as a no-op and retain re-primed word zero for retry.
    @(negedge clk);
    bridge_addr = 32'h2000_0000 + (BODY_WORDS - 1) * 4;
    bridge_rd = 1'b1;
    @(negedge clk);
    bridge_rd = 1'b0;
    repeat (20) @(negedge clk);
    if (failed)
      $fatal(1, "terminal pipeline-flush duplicate failed snapshot");
    request_bridge_word(0);

    // Leaving reset/cancelling export must release ownership from any stream
    // prefetch state, and a later reset-enter must rebuild a fresh snapshot.
    start = 1'b0;
    repeat (3) @(posedge clk);
    if (busy || ready || failed || source_read || !sram_oe_n || !sram_we_n)
      $fatal(1, "snapshot did not abort safely when start dropped");
    start = 1'b1;
    wait (ready || failed);
    if (failed || !ready)
      $fatal(1, "snapshot did not rearm after abort");

    if (failed)
      $fatal(1, "stream failed after verified snapshot");
    $display("SAVE SNAPSHOT VERIFIED/PREFETCHED STREAM PASS halfwords=%0d words=%0d",
             HALFWORDS, BODY_WORDS);
    $finish;
  end

  initial begin
    #1000000;
    $fatal(1, "snapshot test timeout");
  end
endmodule
