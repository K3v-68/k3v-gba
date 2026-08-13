`timescale 1ns/1ps

// Minimal Intel dcfifo model for the lifecycle reproduction.  Quartus has
// overflow_checking="OFF" on these FIFOs, so a blocked shutdown stream must
// not turn into a simulator-only fatal: excess writes are ignored here while
// the already-buffered request remains stalled.
module dcfifo #(
    parameter clocks_are_synchronized = "FALSE",
    parameter intended_device_family = "Cyclone V",
    parameter integer lpm_numwords = 4,
    parameter lpm_showahead = "OFF",
    parameter lpm_type = "dcfifo",
    parameter integer lpm_width = 8,
    parameter integer lpm_widthu = 2,
    parameter overflow_checking = "OFF",
    parameter integer rdsync_delaypipe = 5,
    parameter underflow_checking = "OFF",
    parameter use_eab = "OFF",
    parameter integer wrsync_delaypipe = 5
) (
    input  wire [lpm_width-1:0] data,
    input  wire                 rdclk,
    input  wire                 rdreq,
    input  wire                 wrclk,
    input  wire                 wrreq,
    output reg  [lpm_width-1:0] q = {lpm_width{1'b0}},
    output wire                 rdempty,
    output wire                 wrfull
);

  reg [lpm_width-1:0] storage [0:lpm_numwords-1];
  integer write_count = 0;
  integer read_count = 0;

  assign rdempty = write_count == read_count;
  assign wrfull = (write_count - read_count) >= lpm_numwords;

  always @(posedge wrclk) begin
    if (wrreq && !wrfull) begin
      storage[write_count % lpm_numwords] <= data;
      write_count <= write_count + 1;
    end else if (wrreq && overflow_checking != "OFF") begin
      $fatal(1, "dcfifo overflow (width=%0d depth=%0d)",
             lpm_width, lpm_numwords);
    end
  end

  always @(posedge rdclk) begin
    if (rdreq && !rdempty) begin
      q <= storage[read_count % lpm_numwords];
      read_count <= read_count + 1;
    end else if (rdreq && underflow_checking != "OFF") begin
      $fatal(1, "dcfifo underflow (width=%0d depth=%0d)",
             lpm_width, lpm_numwords);
    end
  end

endmodule
