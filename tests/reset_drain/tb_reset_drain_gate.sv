`timescale 1ns/1ps

// Regression for the "reset abandons a flash erase" save-corruption hazard.
//
// A behavioural stand-in for gba_memorymux's FLASH_WRITEBLOCK sequencer erases
// a 4 KiB sector one byte per BYTE_CYCLES clocks and, like the real RTL, drops
// back to IDLE (abandoning the burst) if its reset input is asserted.  The
// gate under test must hold that reset off until the burst finishes.
module tb_reset_drain_gate #(
    parameter integer BYTE_CYCLES = 6,
    parameter integer SECTOR_BYTES = 4096,
    parameter integer RESET_AT_BYTE = 1000,   // host reset request lands mid-erase
    parameter integer WEDGE = 0,              // 1: bus never goes idle
    parameter integer RESET_BEFORE_START = 0  // 1: request reset while idle
);
  reg clk = 0;
  always #5 clk = ~clk;

  reg reset_req = 0;
  reg start_erase = 0;

  // ---- flash sequencer model --------------------------------------------
  reg        erasing = 0;
  integer    bytes_done = 0;
  integer    cyc = 0;
  reg [7:0]  flash [0:SECTOR_BYTES-1];
  integer    i;
  wire       bus_idle = !erasing && !start_erase && (WEDGE == 0);

  wire pause, quiesced;
  reset_drain_gate dut (
      .clk(clk), .reset_req(reset_req),
      .bus_idle(bus_idle), .pause(pause), .quiesced(quiesced));

  // Exactly the expression core_top feeds to gba reset for host resets.
  wire gba_reset_host = reset_req & quiesced;

  initial for (i = 0; i < SECTOR_BYTES; i = i + 1) flash[i] = 8'h5A;

  integer abandoned = 0;
  integer accepted_starts = 0;
  always @(posedge clk) begin
    if (gba_reset_host) begin
      if (erasing) abandoned = abandoned + 1;
      erasing <= 0;
    end else if (start_erase && !pause) begin
      erasing <= 1; bytes_done <= 0; cyc <= 0;
      accepted_starts = accepted_starts + 1;
    end else if (erasing) begin
      if (cyc == BYTE_CYCLES - 1) begin
        cyc <= 0;
        flash[bytes_done] <= 8'hFF;
        bytes_done <= bytes_done + 1;
        if (bytes_done == SECTOR_BYTES - 1) erasing <= 0;
      end else cyc <= cyc + 1;
    end
  end


  integer cycles_to_quiesce;

  // All stimulus changes happen on negedge, away from the posedge where the
  // DUT and flash model sample, so there is no initial-vs-always race.
  task automatic pulse_start;
    begin
      @(negedge clk); start_erase = 1;
      @(negedge clk); start_erase = 0;
    end
  endtask

  task automatic wait_quiesce(input integer limit, output integer waited);
    begin
      waited = 0;
      while (!quiesced && waited < limit) begin
        @(negedge clk); waited = waited + 1;
      end
    end
  endtask

  initial begin
    repeat (8) @(negedge clk);

    if (RESET_BEFORE_START) begin
      reset_req = 1;
      wait_quiesce(200, cycles_to_quiesce);
      if (!quiesced) $fatal(1, "idle bus never quiesced");
      // CPU tries to launch a new erase after the host reset took effect.
      pulse_start();
      repeat (50) @(negedge clk);
      if (erasing) $fatal(1, "burst started while GBA held in reset");
      $display("RESET DRAIN PASS idle-bus");
      $finish;
    end

    pulse_start();
    if (WEDGE == 0) begin
      while (bytes_done < RESET_AT_BYTE) @(negedge clk);
      @(negedge clk); reset_req = 1;

      // While the burst is running the reset must not take effect.
      repeat (BYTE_CYCLES * 4) @(negedge clk);
      if (erasing && gba_reset_host) $fatal(1, "reset asserted while flash burst active");
      if (erasing && !pause) $fatal(1, "GBA not paused while reset waits for drain");
      // A new burst attempted during the drain must be refused.
      if (erasing) begin
        pulse_start();
      end
      while (erasing) @(negedge clk);   // original burst completes
      wait_quiesce(200, cycles_to_quiesce);
      if (!quiesced) $fatal(1, "gate never quiesced after burst finished");
      if (abandoned != 0) $fatal(1, "burst was abandoned by reset");
      if (accepted_starts != 1) $fatal(1, "new burst started while paused (%0d starts)", accepted_starts);
      for (i = 0; i < SECTOR_BYTES; i = i + 1)
        if (flash[i] !== 8'hFF) $fatal(1, "sector byte %0d not erased: %02x", i, flash[i]);
      // Dropping the reset request must clear the gate for the next cycle.
      reset_req = 0; repeat (3) @(negedge clk);
      if (quiesced) $fatal(1, "quiesced stuck after reset request released");
      $display("RESET DRAIN PASS burst-complete (%0d cycles after finish)", cycles_to_quiesce);
    end else begin
      // Wedged bus: with no timeout the reset must stay deferred, never fire
      // mid-burst.  (Documented trade-off; see reset_drain_gate.sv.)
      @(negedge clk); reset_req = 1;
      repeat (2000) @(negedge clk);
      if (quiesced || gba_reset_host) $fatal(1, "gate released with a busy bus");
      if (!pause) $fatal(1, "GBA not paused while waiting");
      $display("RESET DRAIN PASS busy-bus-stays-deferred");
    end
    $finish;
  end

  initial begin
    #50_000_000;
    $fatal(1, "testbench watchdog");
  end
endmodule
