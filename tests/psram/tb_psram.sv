`timescale 1ns/1ps

module tb_psram;

  localparam real CLOCK_SPEED = 100.66;
  localparam integer TIMEOUT_CYCLES = 64;

  reg clk = 0;
  always #5 clk = ~clk;

  reg bank_sel = 0;
  reg [21:0] addr = 0;
  reg write_en = 0;
  reg [15:0] data_in = 0;
  reg write_high_byte = 0;
  reg write_low_byte = 0;
  reg read_en = 0;
  wire read_avail;
  wire [15:0] data_out;
  wire busy;

  wire [5:0] cram_a;
  tri [15:0] cram_dq;
  reg model_drive = 0;
  reg [15:0] model_data = 0;
  assign cram_dq = model_drive ? model_data : 16'hzzzz;

  wire cram_clk;
  wire cram_adv_n;
  wire cram_cre;
  wire cram_ce0_n;
  wire cram_ce1_n;
  wire cram_oe_n;
  wire cram_we_n;
  wire cram_ub_n;
  wire cram_lb_n;

  psram #(.CLOCK_SPEED(CLOCK_SPEED)) dut (
    .clk,
    .bank_sel,
    .addr,
    .write_en,
    .data_in,
    .write_high_byte,
    .write_low_byte,
    .read_en,
    .read_avail,
    .data_out,
    .busy,
    .cram_a,
    .cram_dq,
    .cram_wait(1'b0),
    .cram_clk,
    .cram_adv_n,
    .cram_cre,
    .cram_ce0_n,
    .cram_ce1_n,
    .cram_oe_n,
    .cram_we_n,
    .cram_ub_n,
    .cram_lb_n
  );

  task automatic tick;
    begin
      @(posedge clk);
      #1;
    end
  endtask

  task automatic check(input bit condition, input string message);
    begin
      if (!condition) $fatal(1, "%s", message);
    end
  endtask

  integer cycles;

  initial begin
    tick();
    check(!busy, "controller did not power up idle");
    check(cram_adv_n && cram_ce0_n && cram_ce1_n && cram_we_n && cram_oe_n,
           "physical interface did not power up inactive");

    // Accept a write, then immediately change every live request input.  The
    // registered start stage must use only the accepted values.
    bank_sel = 1;
    addr = 22'h2a1234;
    data_in = 16'hc35a;
    write_high_byte = 1;
    write_low_byte = 0;
    write_en = 1;
    tick();
    check(busy, "write acceptance did not assert busy immediately");
    check(cram_adv_n && cram_ce0_n && cram_ce1_n,
           "write touched CRAM pins before the registered start edge");

    write_en = 0;
    bank_sel = 0;
    addr = 22'h001111;
    data_in = 16'hdead;
    write_high_byte = 0;
    write_low_byte = 1;
    read_en = 1; // must be ignored while busy

    tick();
    check(!cram_adv_n, "ADV# did not assert on registered write start");
    check(cram_ce0_n && !cram_ce1_n && !cram_we_n,
           "write bank/enable did not use captured request");
    check(!cram_ub_n && cram_lb_n, "write byte enables were not captured");
    check(cram_a == 6'h2a && cram_dq == 16'h1234,
           "write address was not captured before live inputs changed");

    read_en = 0;
    tick();
    check(!cram_adv_n, "ADV# pulse was shorter than two full cycles");
    tick();
    check(cram_adv_n, "ADV# pulse did not end after two full cycles");
    check(cram_dq == 16'h1234, "address was not held through ADV# release");
    tick();
    check(cram_dq === 16'hzzzz, "address bus was not released after hold cycle");
    tick();
    check(cram_dq == 16'hc35a, "write data did not use captured request data");

    cycles = 0;
    while (busy && cycles < TIMEOUT_CYCLES) begin
      tick();
      cycles = cycles + 1;
    end
    check(!busy, "write never completed");
    check(cram_ce0_n && cram_ce1_n && cram_we_n && cram_ub_n && cram_lb_n,
           "write completion did not release CRAM controls");

    // Perform a read with another conflicting request after acceptance.  Drive
    // model data only after OE# falls and verify a single valid response.
    bank_sel = 0;
    addr = 22'h155678;
    read_en = 1;
    tick();
    check(busy, "read acceptance did not assert busy immediately");
    check(cram_adv_n && cram_ce0_n && cram_ce1_n,
           "read touched CRAM pins before the registered start edge");

    read_en = 0;
    bank_sel = 1;
    addr = 22'h3f0000;
    write_en = 1; // ignored while the accepted read is active
    data_in = 16'h0000;
    tick();
    check(!cram_adv_n, "ADV# did not assert on registered read start");
    check(!cram_ce0_n && cram_ce1_n,
           "read bank select did not use captured request");
    check(cram_a == 6'h15 && cram_dq == 16'h5678,
           "read address was not captured before live inputs changed");
    write_en = 0;

    tick();
    check(!cram_adv_n, "read ADV# pulse was shorter than two full cycles");
    tick();
    check(cram_adv_n, "read ADV# pulse did not end after two full cycles");

    cycles = 0;
    while (cram_oe_n && cycles < TIMEOUT_CYCLES) begin
      tick();
      cycles = cycles + 1;
    end
    check(!cram_oe_n, "read never enabled CRAM output");
    model_data = 16'ha751;
    model_drive = 1;

    cycles = 0;
    while (!read_avail && cycles < TIMEOUT_CYCLES) begin
      tick();
      cycles = cycles + 1;
    end
    check(read_avail, "read never produced a valid response");
    check(data_out == 16'ha751, "read response did not sample CRAM data");
    check(!busy, "busy remained asserted with the read response");
    check(cram_ce0_n && cram_ce1_n && cram_oe_n,
           "read completion did not release CRAM controls");
    model_drive = 0;

    tick();
    check(!read_avail, "read_avail was not a one-cycle pulse");
    check(!busy, "conflicting request was accepted while busy");

    $display("PSRAM controller registered-start test PASS");
    $finish;
  end

endmodule
