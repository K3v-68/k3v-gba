`timescale 1ns/1ps

// Fail-closed cart-save snapshot and APF bridge streamer.
//
// The complete live save is copied into Pocket's 128Kx16 asynchronous SRAM and
// read back before ready is asserted.  Word zero is prefetched before ready;
// subsequent sequential APF words are prefetched directly in clk_74a, avoiding
// the legacy data_unloader CDC/FIFO path during the irrevocable physical stream.
module save_snapshot #(
    parameter integer SRAM_WAIT_CYCLES = 6,
    parameter integer SOURCE_TIMEOUT_CYCLES = 1024
) (
    input  wire        clk,
    input  wire        reset_n,
    input  wire        start,
    input  wire [16:0] word_count,

    output reg         busy = 1'b0,
    output reg         ready = 1'b0,
    output reg         failed = 1'b0,

    // Four-phase bundled-data source handshake. Acceptance is separate from
    // response so quiescence/arbitration wait is not charged to data timeout.
    output reg         source_read = 1'b0,
    output reg  [16:0] source_addr = 17'd0,
    input  wire        source_accepted,
    input  wire        source_idle,
    input  wire [15:0] source_data,
    input  wire        source_data_valid,

    input  wire        bridge_endian_little,
    input  wire [31:0] bridge_addr,
    input  wire        bridge_rd,
    output reg  [31:0] bridge_rd_data = 32'd0,
    output reg         bridge_rd_data_valid = 1'b0,

    output reg  [16:0] sram_a = 17'd0,
    inout  wire [15:0] sram_dq,
    output reg         sram_oe_n = 1'b1,
    output reg         sram_we_n = 1'b1,
    output reg         sram_ub_n = 1'b1,
    output reg         sram_lb_n = 1'b1
);
  localparam [4:0] ST_IDLE        = 5'd0;
  localparam [4:0] ST_SOURCE_WAIT = 5'd1;
  localparam [4:0] ST_SRAM_WRITE  = 5'd2;
  localparam [4:0] ST_VERIFY_SET  = 5'd3;
  localparam [4:0] ST_VERIFY_WAIT = 5'd4;
  localparam [4:0] ST_PRIME_LO_SET = 5'd5;
  localparam [4:0] ST_PRIME_LO_WAIT = 5'd6;
  localparam [4:0] ST_PRIME_HI_SET = 5'd7;
  localparam [4:0] ST_PRIME_HI_WAIT = 5'd8;
  localparam [4:0] ST_DONE        = 5'd9;
  localparam [4:0] ST_STREAM_LO_WAIT = 5'd10;
  localparam [4:0] ST_STREAM_HI_SET = 5'd11;
  localparam [4:0] ST_STREAM_HI_WAIT = 5'd12;
  localparam [4:0] ST_FAILED      = 5'd13;
  localparam [4:0] ST_SOURCE_RELEASE = 5'd14;
  localparam [4:0] ST_SOURCE_ACCEPT = 5'd15;
  localparam [4:0] ST_ABORT_DRAIN = 5'd16;
  localparam [4:0] ST_SOURCE_CAPTURE = 5'd17;
  localparam integer WAIT_COUNTER_WIDTH =
      SRAM_WAIT_CYCLES <= 1 ? 1 : $clog2(SRAM_WAIT_CYCLES);
  localparam integer TIMEOUT_COUNTER_WIDTH =
      SOURCE_TIMEOUT_CYCLES <= 1 ? 1 : $clog2(SOURCE_TIMEOUT_CYCLES);

  reg [4:0] state = ST_IDLE;
  reg [16:0] copy_index = 17'd0;
  reg [16:0] verify_index = 17'd0;
  reg copy_complete = 1'b0;
  reg [31:0] source_crc = 32'hffff_ffff;
  reg [31:0] verify_crc = 32'hffff_ffff;
  reg [WAIT_COUNTER_WIDTH-1:0] wait_count = 0;
  reg [TIMEOUT_COUNTER_WIDTH-1:0] timeout_count = 0;
  reg sram_drive = 1'b0;
  reg [15:0] sram_data_out = 16'd0;
  reg [15:0] source_halfword = 16'd0;
  reg [15:0] prefetch_low = 16'd0;
  reg [31:0] prefetched_word = 32'd0;
  reg [15:0] prefetched_word_index = 16'd0;
  reg cache_valid = 1'b0;
  reg have_served_word = 1'b0;
  reg prev_bridge_rd = 1'b0;

  wire bridge_read_start = bridge_rd && !prev_bridge_rd;
  wire bridge_read_cart = bridge_addr[31:24] == 8'h20;
  wire [15:0] requested_word_index = bridge_addr[17:2];
  wire [15:0] terminal_word_index = (word_count >> 1) - 1'b1;
  wire terminal_flush_duplicate = have_served_word && cache_valid &&
      prefetched_word_index == 16'd0 &&
      requested_word_index == terminal_word_index;
  wire chunk_boundary_prime_duplicate = cache_valid &&
      prefetched_word_index[7:0] == 8'd1 &&
      requested_word_index[7:0] == 8'd0 &&
      requested_word_index[15:8] == prefetched_word_index[15:8];
  wire [31:0] formatted_prefetched_word = bridge_endian_little ?
      prefetched_word :
      {prefetched_word[7:0], prefetched_word[15:8],
       prefetched_word[23:16], prefetched_word[31:24]};

  assign sram_dq = sram_drive ? sram_data_out : 16'hzzzz;

  function automatic [31:0] crc32_halfword;
    input [31:0] crc_in;
    input [15:0] data_in;
    integer bit_index;
    reg [31:0] crc;
    reg feedback;
    begin
      crc = crc_in;
      for (bit_index = 0; bit_index < 16; bit_index = bit_index + 1) begin
        feedback = crc[0] ^ data_in[bit_index];
        crc = crc >> 1;
        if (feedback)
          crc = crc ^ 32'hedb8_8320;
      end
      crc32_halfword = crc;
    end
  endfunction

  task automatic fail_snapshot;
    begin
      source_read <= 1'b0;
      sram_drive <= 1'b0;
      sram_oe_n <= 1'b1;
      sram_we_n <= 1'b1;
      sram_ub_n <= 1'b1;
      sram_lb_n <= 1'b1;
      busy <= 1'b0;
      ready <= 1'b0;
      failed <= 1'b1;
      cache_valid <= 1'b0;
      state <= ST_FAILED;
    end
  endtask

  task automatic start_sram_read;
    input [16:0] halfword_addr;
    begin
      sram_a <= halfword_addr;
      sram_drive <= 1'b0;
      sram_we_n <= 1'b1;
      sram_oe_n <= 1'b0;
      sram_ub_n <= 1'b0;
      sram_lb_n <= 1'b0;
      wait_count <= 0;
    end
  endtask

  always @(posedge clk) begin
    prev_bridge_rd <= bridge_rd;
    bridge_rd_data_valid <= 1'b0;

    if (!reset_n) begin
      state <= ST_IDLE;
      busy <= 1'b0;
      ready <= 1'b0;
      failed <= 1'b0;
      source_read <= 1'b0;
      source_addr <= 17'd0;
      sram_a <= 17'd0;
      sram_drive <= 1'b0;
      sram_data_out <= 16'd0;
      source_halfword <= 16'd0;
      sram_oe_n <= 1'b1;
      sram_we_n <= 1'b1;
      sram_ub_n <= 1'b1;
      sram_lb_n <= 1'b1;
      copy_index <= 17'd0;
      verify_index <= 17'd0;
      copy_complete <= 1'b0;
      source_crc <= 32'hffff_ffff;
      verify_crc <= 32'hffff_ffff;
      wait_count <= 0;
      timeout_count <= 0;
      prefetch_low <= 16'd0;
      prefetched_word <= 32'd0;
      prefetched_word_index <= 16'd0;
      cache_valid <= 1'b0;
      have_served_word <= 1'b0;
      prev_bridge_rd <= 1'b0;
      bridge_rd_data <= 32'd0;
      bridge_rd_data_valid <= 1'b0;
    end else begin
      if (!start && state != ST_IDLE) begin
        // Reset-exit/cancellation revokes memory ownership immediately.
        source_read <= 1'b0;
        sram_drive <= 1'b0;
        sram_oe_n <= 1'b1;
        sram_we_n <= 1'b1;
        sram_ub_n <= 1'b1;
        sram_lb_n <= 1'b1;
        busy <= 1'b0;
        ready <= 1'b0;
        failed <= 1'b0;
        cache_valid <= 1'b0;
        have_served_word <= 1'b0;
        state <= ST_ABORT_DRAIN;
      end else begin
      case (state)
        ST_IDLE: begin
          busy <= 1'b0;
          ready <= 1'b0;
          failed <= 1'b0;
          source_read <= 1'b0;
          cache_valid <= 1'b0;
          have_served_word <= 1'b0;
          sram_drive <= 1'b0;
          sram_oe_n <= 1'b1;
          sram_we_n <= 1'b1;
          sram_ub_n <= 1'b1;
          sram_lb_n <= 1'b1;
          if (start && source_idle) begin
            if (word_count < 2 || word_count[0]) begin
              fail_snapshot();
            end else begin
              busy <= 1'b1;
              copy_index <= 17'd0;
              copy_complete <= 1'b0;
              source_addr <= 17'd0;
              source_read <= 1'b1;
              source_crc <= 32'hffff_ffff;
              verify_crc <= 32'hffff_ffff;
              timeout_count <= 0;
              state <= ST_SOURCE_ACCEPT;
            end
          end
        end

        ST_SOURCE_ACCEPT: begin
          // Quiescence and arbitration may legitimately take much longer than
          // a memory response. Cancellation is handled by start going low.
          if (source_accepted) begin
            timeout_count <= 0;
            state <= ST_SOURCE_WAIT;
          end
        end

        ST_SOURCE_WAIT: begin
          if (source_data_valid) begin
            source_read <= 1'b0;
            timeout_count <= 0;
            source_halfword <= source_data;
            state <= ST_SOURCE_CAPTURE;
          end else if (timeout_count >= SOURCE_TIMEOUT_CYCLES - 1) begin
            fail_snapshot();
          end else begin
            timeout_count <= timeout_count + 1'b1;
          end
        end

        ST_SOURCE_CAPTURE: begin
            source_crc <= crc32_halfword(source_crc, source_halfword);
            sram_a <= copy_index;
            sram_data_out <= source_halfword;
            sram_drive <= 1'b1;
            sram_oe_n <= 1'b1;
            sram_we_n <= 1'b0;
            sram_ub_n <= 1'b0;
            sram_lb_n <= 1'b0;
            wait_count <= 0;
            state <= ST_SRAM_WRITE;
        end

        ST_SRAM_WRITE: begin
          if (wait_count >= SRAM_WAIT_CYCLES - 1) begin
            sram_we_n <= 1'b1;
            sram_ub_n <= 1'b1;
            sram_lb_n <= 1'b1;
            sram_drive <= 1'b0;
            wait_count <= 0;
            if (copy_index == word_count - 1'b1)
              copy_complete <= 1'b1;
            else begin
              copy_index <= copy_index + 1'b1;
              source_addr <= copy_index + 1'b1;
              copy_complete <= 1'b0;
            end
            timeout_count <= 0;
            state <= ST_SOURCE_RELEASE;
          end else begin
            wait_count <= wait_count + 1'b1;
          end
        end

        // Enforce the return-to-zero phase of the bundled-data handshake.
        // A delayed response release must never be replayed as the next word.
        ST_SOURCE_RELEASE: begin
          if (!source_accepted && !source_data_valid) begin
            timeout_count <= 0;
            if (copy_complete) begin
              verify_index <= 17'd0;
              verify_crc <= 32'hffff_ffff;
              state <= ST_VERIFY_SET;
            end else begin
              source_read <= 1'b1;
              state <= ST_SOURCE_ACCEPT;
            end
          end else if (timeout_count >= SOURCE_TIMEOUT_CYCLES - 1) begin
            fail_snapshot();
          end else begin
            timeout_count <= timeout_count + 1'b1;
          end
        end

        ST_VERIFY_SET: begin
          start_sram_read(verify_index);
          state <= ST_VERIFY_WAIT;
        end

        ST_VERIFY_WAIT: begin
          if (wait_count >= SRAM_WAIT_CYCLES - 1) begin
            sram_oe_n <= 1'b1;
            sram_ub_n <= 1'b1;
            sram_lb_n <= 1'b1;
            wait_count <= 0;
            if (verify_index == word_count - 1'b1) begin
              if (crc32_halfword(verify_crc, sram_dq) == source_crc) begin
                // Prime halfword zero before authorization.
                state <= ST_PRIME_LO_SET;
              end else begin
                fail_snapshot();
              end
            end else begin
              verify_crc <= crc32_halfword(verify_crc, sram_dq);
              verify_index <= verify_index + 1'b1;
              state <= ST_VERIFY_SET;
            end
          end else begin
            wait_count <= wait_count + 1'b1;
          end
        end

        ST_PRIME_LO_SET: begin
          start_sram_read(17'd0);
          state <= ST_PRIME_LO_WAIT;
        end

        ST_PRIME_LO_WAIT: begin
          if (wait_count >= SRAM_WAIT_CYCLES - 1) begin
            prefetch_low <= sram_dq;
            sram_oe_n <= 1'b1;
            sram_ub_n <= 1'b1;
            sram_lb_n <= 1'b1;
            state <= ST_PRIME_HI_SET;
          end else begin
            wait_count <= wait_count + 1'b1;
          end
        end

        ST_PRIME_HI_SET: begin
          start_sram_read(17'd1);
          state <= ST_PRIME_HI_WAIT;
        end

        ST_PRIME_HI_WAIT: begin
          if (wait_count >= SRAM_WAIT_CYCLES - 1) begin
            prefetched_word <= {sram_dq, prefetch_low};
            prefetched_word_index <= 16'd0;
            cache_valid <= 1'b1;
            sram_oe_n <= 1'b1;
            sram_ub_n <= 1'b1;
            sram_lb_n <= 1'b1;
            busy <= 1'b0;
            ready <= 1'b1;
            state <= ST_DONE;
          end else begin
            wait_count <= wait_count + 1'b1;
          end
        end

        ST_DONE: begin
          busy <= 1'b0;
          ready <= 1'b1;
          if (!start) begin
            state <= ST_IDLE;
          end else if (bridge_read_start && bridge_read_cart) begin
            if ((!cache_valid || prefetched_word_index != requested_word_index) &&
                !terminal_flush_duplicate &&
                !chunk_boundary_prime_duplicate) begin
              fail_snapshot();
            end else if (chunk_boundary_prime_duplicate) begin
              // Pocket primes each 1 KiB data-slot chunk by repeating its
              // first address and discarding that transaction's response.
              // Keep the last response held and preserve the next prefetch.
            end else if (cache_valid && prefetched_word_index == requested_word_index) begin
              bridge_rd_data <= formatted_prefetched_word;
              bridge_rd_data_valid <= 1'b1;
              have_served_word <= 1'b1;
              cache_valid <= 1'b0;
              if ({1'b0, requested_word_index} + 1'b1 < (word_count >> 1)) begin
                prefetched_word_index <= requested_word_index + 1'b1;
                start_sram_read(({1'b0, requested_word_index} + 1'b1) << 1);
                state <= ST_STREAM_LO_WAIT;
              end else begin
                // Re-prime word zero after the terminal word. The host's final
                // duplicate read is a pipeline flush and leaves this cache intact.
                prefetched_word_index <= 16'd0;
                start_sram_read(17'd0);
                state <= ST_STREAM_LO_WAIT;
              end
            end
          end
        end

        ST_STREAM_LO_WAIT: begin
          ready <= 1'b1;
          if (bridge_read_start && bridge_read_cart) begin
            fail_snapshot();
          end else if (wait_count >= SRAM_WAIT_CYCLES - 1) begin
            prefetch_low <= sram_dq;
            sram_oe_n <= 1'b1;
            sram_ub_n <= 1'b1;
            sram_lb_n <= 1'b1;
            state <= ST_STREAM_HI_SET;
          end else begin
            wait_count <= wait_count + 1'b1;
          end
        end

        ST_STREAM_HI_SET: begin
          if (bridge_read_start && bridge_read_cart) begin
            fail_snapshot();
          end else begin
            start_sram_read(({1'b0, prefetched_word_index} << 1) + 1'b1);
            state <= ST_STREAM_HI_WAIT;
          end
        end

        ST_STREAM_HI_WAIT: begin
          ready <= 1'b1;
          if (bridge_read_start && bridge_read_cart) begin
            fail_snapshot();
          end else if (wait_count >= SRAM_WAIT_CYCLES - 1) begin
            prefetched_word <= {sram_dq, prefetch_low};
            cache_valid <= 1'b1;
            sram_oe_n <= 1'b1;
            sram_ub_n <= 1'b1;
            sram_lb_n <= 1'b1;
            state <= ST_DONE;
          end else begin
            wait_count <= wait_count + 1'b1;
          end
        end

        ST_ABORT_DRAIN: begin
          busy <= 1'b0;
          ready <= 1'b0;
          failed <= 1'b0;
          source_read <= 1'b0;
          if (source_idle)
            state <= ST_IDLE;
        end

        ST_FAILED: begin
          busy <= 1'b0;
          ready <= 1'b0;
          failed <= 1'b1;
          if (!start)
            state <= ST_IDLE;
        end

        default: fail_snapshot();
      endcase
      end
    end
  end
endmodule
