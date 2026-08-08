`timescale 1ns/1ps

module tb_io_bridge_pipeline;
  reg clk = 0;
  always #5 clk = ~clk;

  reg reset_n = 1;
  reg endian_little = 0;
  wire [31:0] pmp_addr;
  wire pmp_addr_valid;
  wire pmp_rd;
  reg [31:0] pmp_rd_data = 32'h1234_5678;
  wire pmp_wr;
  wire [31:0] pmp_wr_data;
  tri phy_spimosi;
  tri phy_spimiso;
  tri phy_spiclk;
  reg phy_spiss = 0;

  io_bridge_peripheral dut (
      .clk(clk),
      .reset_n(reset_n),
      .endian_little(endian_little),
      .pmp_addr(pmp_addr),
      .pmp_addr_valid(pmp_addr_valid),
      .pmp_rd(pmp_rd),
      .pmp_rd_data(pmp_rd_data),
      .pmp_wr(pmp_wr),
      .pmp_wr_data(pmp_wr_data),
      .phy_spimosi(phy_spimosi),
      .phy_spimiso(phy_spimiso),
      .phy_spiclk(phy_spiclk),
      .phy_spiss(phy_spiss)
  );

  initial begin
    // Enter ST_READ_0 directly. The bridge must launch the already-buffered
    // response after exactly four clocks. Waiting for the following memory
    // word here recreates the hardware timeout that produced 0xDEADDEAD saves.
    dut.state = 5'd2;
    dut.read_cnt = 0;
    dut.spis = 5'd1;
    dut.spis_tx = 0;

    repeat (4) @(posedge clk);
    #1;
    if (dut.state !== 5'd3 || dut.spis_tx !== 1'b1)
      $fatal(1, "PMP response did not launch after its fixed four-cycle delay");
    if (dut.spis_word_tx !== 32'h1234_5678)
      $fatal(1, "PMP response did not use the previously buffered word");

    @(posedge clk);
    #1;
    if (pmp_rd !== 1'b1)
      $fatal(1, "PMP did not request the following pipelined word");

    $display("PASS: Pocket bridge preserves immediate one-word pipelining");
    $finish;
  end
endmodule
