`timescale 1ns/1ps

// Minimal dual-port model for core_bridge_cmd simulation. The command
// regression does not depend on initialized build metadata, but retaining the
// synchronous read/write contract catches accidental interface changes.
module mf_datatable (
    input  wire [9:0]  address_a,
    input  wire [9:0]  address_b,
    input  wire        clock_a,
    input  wire        clock_b,
    input  wire [31:0] data_a,
    input  wire [31:0] data_b,
    input  wire        wren_a,
    input  wire        wren_b,
    output reg  [31:0] q_a = 32'd0,
    output reg  [31:0] q_b = 32'd0
);

    reg [31:0] memory [0:255];

    always @(posedge clock_a) begin
        if (wren_a)
            memory[address_a[7:0]] <= data_a;
        q_a <= memory[address_a[7:0]];
    end

    always @(posedge clock_b) begin
        if (wren_b)
            memory[address_b[7:0]] <= data_b;
        q_b <= memory[address_b[7:0]];
    end

endmodule
