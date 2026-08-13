//
// Shared APF write ingress for the K3V GBA core.
//
// One complete APF word crosses from clk_74a to clk_memory atomically.  The
// memory side then presents its two 16-bit halves in byte-address order.  A
// destination tag lets the core share one CDC FIFO and one dispatcher between
// ROM, save/RTC, and BIOS loading.
//

`timescale 1ns/1ps
`default_nettype none

module apf_write_ingress #(
    parameter integer ROM_WRITE_DELAY  = 20,
    parameter integer SAVE_WRITE_DELAY = 20,
    parameter integer BIOS_WRITE_DELAY = 4
) (
    input  wire        clk_74a,
    input  wire        clk_memory,

    input  wire        bridge_wr,
    input  wire        bridge_endian_little,
    input  wire [31:0] bridge_addr,
    input  wire [31:0] bridge_wr_data,

    // Memory-domain ready/valid stream.  Destination values match the APF
    // upper address nibble: 1=ROM, 2=save/RTC, 3=BIOS.
    output reg         write_valid = 1'b0,
    output reg  [1:0]  write_dest  = 2'd0,
    output reg  [27:0] write_addr  = 28'd0,
    output reg  [15:0] write_data  = 16'd0,
    input  wire        write_ready,
    output wire        write_busy
);

  localparam integer FIFO_WIDTH = 62;

  // APF write capture.  Keeping the normalized 32-bit word intact makes the
  // endian selection atomic and gives the eight-entry FIFO sixteen halfwords
  // of effective buffering.
  reg         prev_bridge_wr = 1'b0;
  wire        fifo_full;

  wire bridge_region_valid = bridge_addr[31:28] == 4'h1 ||
                             bridge_addr[31:28] == 4'h2 ||
                             bridge_addr[31:28] == 4'h3;
  wire [31:0] normalized_bridge_data = bridge_endian_little ? bridge_wr_data : {
      bridge_wr_data[7:0], bridge_wr_data[15:8],
      bridge_wr_data[23:16], bridge_wr_data[31:24]
  };
  wire [FIFO_WIDTH-1:0] fifo_in = {
      bridge_addr[29:28], normalized_bridge_data, bridge_addr[27:0]
  };
  wire fifo_write_req = ~prev_bridge_wr && bridge_wr &&
                        bridge_region_valid && !fifo_full;

  always @(posedge clk_74a) begin
    prev_bridge_wr <= bridge_wr;

    // APF writes cannot be backpressured.  Reaching full is therefore a
    // prohibited system condition and must be visible in simulation.
    // synthesis translate_off
    if (~prev_bridge_wr && bridge_wr && bridge_region_valid && fifo_full)
      $fatal(1, "APF write ingress overflow at address %08x", bridge_addr);
    // synthesis translate_on
  end

  wire [FIFO_WIDTH-1:0] fifo_out;
  wire                  fifo_empty;
  reg                   fifo_read_req = 1'b0;

  dcfifo ingress_fifo (
      .data(fifo_in),
      .rdclk(clk_memory),
      .rdreq(fifo_read_req),
      .wrclk(clk_74a),
      .wrreq(fifo_write_req),
      .q(fifo_out),
      .rdempty(fifo_empty),
      .wrfull(fifo_full)
  );
  defparam ingress_fifo.clocks_are_synchronized = "FALSE",
      ingress_fifo.intended_device_family = "Cyclone V", ingress_fifo.lpm_numwords = 8,
      ingress_fifo.lpm_showahead = "OFF", ingress_fifo.lpm_type = "dcfifo",
      ingress_fifo.lpm_width = FIFO_WIDTH, ingress_fifo.lpm_widthu = 3,
      ingress_fifo.overflow_checking = "OFF", ingress_fifo.rdsync_delaypipe = 5,
      ingress_fifo.underflow_checking = "OFF", ingress_fifo.use_eab = "ON",
      ingress_fifo.wrsync_delaypipe = 5;

  localparam [2:0] READ_IDLE           = 3'd0;
  localparam [2:0] READ_POP            = 3'd1;
  localparam [2:0] READ_LATCH          = 3'd2;
  localparam [2:0] READ_FIRST_VALID    = 3'd3;
  localparam [2:0] READ_FIRST_DELAY    = 3'd4;
  localparam [2:0] READ_SECOND_VALID   = 3'd5;
  localparam [2:0] READ_SECOND_DELAY   = 3'd6;

  reg [2:0]  read_state = READ_IDLE;
  reg [27:0] word_addr = 28'd0;
  reg [31:0] word_data = 32'd0;
  reg [5:0]  delay_count = 6'd0;

  function automatic [5:0] write_delay(input [1:0] destination);
    begin
      case (destination)
        2'd1: write_delay = ROM_WRITE_DELAY[5:0];
        2'd2: write_delay = SAVE_WRITE_DELAY[5:0];
        2'd3: write_delay = BIOS_WRITE_DELAY[5:0];
        default: write_delay = 6'd4;
      endcase
    end
  endfunction

  // The fixed delay begins when a halfword is accepted.  write_valid remains
  // asserted with a stable payload for an arbitrarily stalled destination.
  always @(posedge clk_memory) begin
    case (read_state)
      READ_IDLE: begin
        fifo_read_req <= 1'b0;
        write_valid <= 1'b0;
        if (!fifo_empty) begin
          fifo_read_req <= 1'b1;
          read_state <= READ_POP;
        end
      end

      READ_POP: begin
        fifo_read_req <= 1'b0;
        read_state <= READ_LATCH;
      end

      READ_LATCH: begin
        word_addr  <= fifo_out[27:0];
        word_data  <= fifo_out[59:28];
        write_dest <= fifo_out[61:60];
        write_addr <= fifo_out[27:0];
        write_data <= fifo_out[43:28];
        write_valid <= 1'b1;
        read_state <= READ_FIRST_VALID;
      end

      READ_FIRST_VALID: begin
        if (write_ready) begin
          write_valid <= 1'b0;
          delay_count <= write_delay(write_dest) - 1'b1;
          read_state <= READ_FIRST_DELAY;
        end
      end

      READ_FIRST_DELAY: begin
        if (delay_count <= 1) begin
          write_addr <= word_addr + 28'd2;
          write_data <= word_data[31:16];
          write_valid <= 1'b1;
          read_state <= READ_SECOND_VALID;
        end else begin
          delay_count <= delay_count - 1'b1;
        end
      end

      READ_SECOND_VALID: begin
        if (write_ready) begin
          write_valid <= 1'b0;
          delay_count <= write_delay(write_dest) - 1'b1;
          read_state <= READ_SECOND_DELAY;
        end
      end

      READ_SECOND_DELAY: begin
        if (delay_count == 0) begin
          read_state <= READ_IDLE;
        end else begin
          delay_count <= delay_count - 1'b1;
        end
      end

      default: begin
        fifo_read_req <= 1'b0;
        write_valid <= 1'b0;
        read_state <= READ_IDLE;
      end
    endcase
  end

  assign write_busy = (read_state != READ_IDLE) || !fifo_empty;

  // synthesis translate_off
  initial begin
    if (ROM_WRITE_DELAY < 4 || ROM_WRITE_DELAY > 63)
      $fatal(1, "ROM_WRITE_DELAY must be between 4 and 63");
    if (SAVE_WRITE_DELAY < 4 || SAVE_WRITE_DELAY > 63)
      $fatal(1, "SAVE_WRITE_DELAY must be between 4 and 63");
    if (BIOS_WRITE_DELAY < 4 || BIOS_WRITE_DELAY > 63)
      $fatal(1, "BIOS_WRITE_DELAY must be between 4 and 63");
  end
  // synthesis translate_on

endmodule

`default_nettype wire
