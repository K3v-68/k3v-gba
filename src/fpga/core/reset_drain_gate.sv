`timescale 1ns/1ps

// reset_drain_gate.sv - defer a host reset until the GBA save bus has drained.
//
// Pocket asserts reset (APF command 0x0010) immediately before it flushes the
// cartridge save.  gba_memorymux forces its sequencer to IDLE on reset, which
// abandons a FLASH_WRITEBLOCK (4 KiB sector erase, 128 KiB chip erase or a
// program burst) part-way through.  The save export would then faithfully copy
// a half-erased flash image.
//
// While a host reset is requested this gate:
//   1. asserts pause, which stops the GBA from starting new work;
//   2. requires bus_idle to be seen for HISTORY consecutive cycles *after* the
//      request (covers the CPU-step to memory-request latency);
//   3. latches quiesced, which the caller uses to actually reset the GBA and to
//      authorize save export.  It is latched so a later bus_idle glitch cannot
//      release the GBA in the middle of an export.
//
// There is deliberately no timeout: this is a handful of flops because the
// design is at its ALM budget.  A save-bus burst always terminates (it is a
// bounded loop of PSRAM writes), so the gate cannot wait forever unless the
// PSRAM controller itself hangs, in which case the GBA is already stalled.
//
// All signals are in the clk domain (synchronize reset_req beforehand).

`default_nettype none

module reset_drain_gate #(
    parameter integer HISTORY = 4
) (
    input  wire clk,
    input  wire reset_req,    // host reset request, already in clk domain
    input  wire bus_idle,     // save bus + sequencer fully idle
    output wire pause,        // stop issuing new GBA work
    output reg  quiesced = 1'b0
);
  reg [HISTORY-1:0] idle_hist = {HISTORY{1'b0}};
  wire              settled   = &idle_hist;

  assign pause = reset_req && !quiesced;

  always @(posedge clk) begin
    idle_hist <= reset_req ? {idle_hist[HISTORY-2:0], bus_idle} : {HISTORY{1'b0}};
    quiesced  <= reset_req && (quiesced || settled);
  end
endmodule

`default_nettype wire
