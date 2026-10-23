`timescale 1ns/1ps

// Equivalence check for data_unloader's narrow request-FIFO mode.
//
// core_top instantiates the unloader for the 16-byte RTC slot with
// ADDRESS_FIFO_BITS=8 to avoid a 28-bit-wide logic FIFO.  This testbench runs a
// full-width reference unloader and a narrow one side by side on identical
// bridge reads of 0x2100_0000..0x2100_000C and requires identical memory-side
// addresses and identical bridge data.  Memory data is a function of the whole
// 28-bit address, so any address difference shows up as a data mismatch.
module tb_data_unloader_narrow;

  reg clk_74a = 1'b0;
  reg clk_memory = 1'b0;
  always #6.731 clk_74a = ~clk_74a;
  initial begin
    #0.001;
    forever #4.973 clk_memory = ~clk_memory;
  end

  reg        bridge_rd = 1'b0;
  reg [31:0] bridge_addr = 32'h2100_0000;
  reg        endian_little = 1'b0;

  wire [31:0] full_data, narrow_data;
  wire        full_valid, narrow_valid;
  wire        full_read_en, narrow_read_en;
  wire [27:0] full_addr, narrow_addr;
  reg  [15:0] full_mem = 16'd0, narrow_mem = 16'd0;
  reg         full_mem_valid = 1'b0, narrow_mem_valid = 1'b0;

  function automatic [15:0] mem_word(input [27:0] address);
    mem_word = address[15:0] ^ {address[27:24], address[11:0]} ^ 16'h5aa5;
  endfunction

  data_unloader #(
      .ADDRESS_MASK_UPPER_4(4'h2), .ADDRESS_MASK_SECOND_4(4'h1),
      .ADDRESS_SIZE(28), .ADDRESS_FIFO_BITS(28),
      .READ_MEM_CLOCK_DELAY(20), .INPUT_WORD_SIZE(2)
  ) full_dut (
      .clk_74a(clk_74a), .clk_memory(clk_memory), .bridge_rd(bridge_rd),
      .bridge_endian_little(endian_little), .bridge_addr(bridge_addr),
      .bridge_rd_data(full_data), .bridge_rd_data_valid(full_valid),
      .read_en(full_read_en), .read_addr(full_addr), .read_ready(1'b1),
      .read_data(full_mem), .read_data_valid(full_mem_valid));

  data_unloader #(
      .ADDRESS_MASK_UPPER_4(4'h2), .ADDRESS_MASK_SECOND_4(4'h1),
      .ADDRESS_SIZE(28), .ADDRESS_FIFO_BITS(8),
      .READ_MEM_CLOCK_DELAY(20), .INPUT_WORD_SIZE(2)
  ) narrow_dut (
      .clk_74a(clk_74a), .clk_memory(clk_memory), .bridge_rd(bridge_rd),
      .bridge_endian_little(endian_little), .bridge_addr(bridge_addr),
      .bridge_rd_data(narrow_data), .bridge_rd_data_valid(narrow_valid),
      .read_en(narrow_read_en), .read_addr(narrow_addr), .read_ready(1'b1),
      .read_data(narrow_mem), .read_data_valid(narrow_mem_valid));

  // Fixed three-cycle memory responders, one accepted request at a time.
  integer full_delay = -1, narrow_delay = -1;
  reg [27:0] full_pending = 28'd0, narrow_pending = 28'd0;
  integer full_accepts = 0, narrow_accepts = 0;

  always @(posedge clk_memory) begin
    full_mem_valid <= 1'b0;
    if (full_delay > 0) full_delay = full_delay - 1;
    else if (full_delay == 0) begin
      full_mem <= mem_word(full_pending);
      full_mem_valid <= 1'b1;
      full_delay = -1;
    end
    if (full_read_en && full_delay < 0) begin
      full_pending = full_addr;
      full_delay = 3;
      full_accepts = full_accepts + 1;
    end
  end

  always @(posedge clk_memory) begin
    narrow_mem_valid <= 1'b0;
    if (narrow_delay > 0) narrow_delay = narrow_delay - 1;
    else if (narrow_delay == 0) begin
      narrow_mem <= mem_word(narrow_pending);
      narrow_mem_valid <= 1'b1;
      narrow_delay = -1;
    end
    if (narrow_read_en && narrow_delay < 0) begin
      narrow_pending = narrow_addr;
      narrow_delay = 3;
      narrow_accepts = narrow_accepts + 1;
    end
  end

  // The two request streams must be identical, every time.
  always @(posedge clk_memory) begin
    if (full_read_en !== narrow_read_en)
      $fatal(1, "read_en diverged");
    if (full_read_en && (full_addr !== narrow_addr))
      $fatal(1, "read_addr diverged: full=%08x narrow=%08x", full_addr, narrow_addr);
  end

  integer pass, offset, cycles;
  reg [31:0] full_result, narrow_result;
  reg [31:0] expected;

  task automatic bridge_read(input [31:0] address);
    begin
      @(negedge clk_74a); bridge_addr = address; bridge_rd = 1'b1;
      @(negedge clk_74a); bridge_rd = 1'b0;
      repeat (3) @(negedge clk_74a);
      cycles = 0;
      while (!(full_valid && narrow_valid) && cycles < 5000) begin
        @(negedge clk_74a); cycles = cycles + 1;
      end
      if (!(full_valid && narrow_valid))
        $fatal(1, "bridge read of %08x never completed", address);
      full_result = full_data;
      narrow_result = narrow_data;
    end
  endtask

  initial begin
    repeat (20) @(negedge clk_74a);
    for (pass = 0; pass < 3; pass = pass + 1) begin
      for (offset = 0; offset < 16; offset = offset + 4) begin
        bridge_read(32'h2100_0000 + offset);
        if (full_result !== narrow_result)
          $fatal(1, "bridge data diverged at offset %0d: full=%08x narrow=%08x",
                 offset, full_result, narrow_result);
        // Little-endian halves: low half from address, high from address + 2.
        expected = {mem_word(28'h100_0000 + offset + 2), mem_word(28'h100_0000 + offset)};
        // endian_little == 0 byte-swaps the assembled word.
        expected = {expected[7:0], expected[15:8], expected[23:16], expected[31:24]};
        if (narrow_result !== expected)
          $fatal(1, "unexpected data at offset %0d: got %08x expected %08x",
                 offset, narrow_result, expected);
      end
    end
    if (full_accepts != narrow_accepts || full_accepts != 24)
      $fatal(1, "accept counts differ or wrong: full=%0d narrow=%0d", full_accepts, narrow_accepts);
    $display("NARROW UNLOADER PASS (%0d memory requests)", narrow_accepts);
    $finish;
  end

  initial begin
    #20_000_000;
    $fatal(1, "testbench watchdog");
  end
endmodule
