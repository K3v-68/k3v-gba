`timescale 1ns/1ps
`default_nettype none

// Reduced integration model of the production boot-save lifecycle.  The
// production ingress and unloader are instantiated unchanged; only PSRAM and
// the surrounding lifecycle registers are modeled here so Icarus can exercise
// a complete 128 KiB two-launch sequence without compiling the VHDL GBA core.
module save_boot_model (
    input  wire        clk_74a,
    input  wire        clk_memory,
    input  wire        bridge_wr,
    input  wire [31:0] bridge_addr,
    input  wire [31:0] bridge_wr_data,
    input  wire        allcomplete_74a,
    output wire        write_busy,
    output reg  [16:0] accepted_halves = 17'd0,
    output reg  [16:0] body_words = 17'd0,
    output reg         load_complete = 1'b0,
    output reg         load_failed = 1'b0,
    output reg         load_finalized = 1'b0,
    output wire        mem_ready,
    output wire        reset_held
);
  wire        write_valid;
  wire [1:0]  write_dest;
  wire [27:0] write_addr;
  wire [15:0] write_data;

  // Deterministic bursts of memory-side backpressure.  The APF source is
  // deliberately faster than its documented worst-case cadence, but remains
  // slow enough that the production eight-word ingress does not overflow.
  reg [7:0] pressure_phase = 8'd0;
  always @(posedge clk_memory)
    pressure_phase <= pressure_phase + 1'b1;
  wire write_ready = write_dest == 2'd2 && pressure_phase[7:4] != 4'hf;
  wire write_accept = write_valid && write_ready && write_dest == 2'd2;

  apf_write_ingress #(
      .ROM_WRITE_DELAY(20),
      .SAVE_WRITE_DELAY(20),
      .BIOS_WRITE_DELAY(4)
  ) ingress (
      .clk_74a(clk_74a),
      .clk_memory(clk_memory),
      .bridge_wr(bridge_wr),
      .bridge_endian_little(1'b1),
      .bridge_addr(bridge_addr),
      .bridge_wr_data(bridge_wr_data),
      .write_valid(write_valid),
      .write_dest(write_dest),
      .write_addr(write_addr),
      .write_data(write_data),
      .write_ready(write_ready),
      .write_busy(write_busy)
  );

  // Zero initialization models the hardware state implicated by the captured
  // post-exit file.  A successful import overwrites all 65,536 halfwords.
  reg [15:0] memory [0:65535];
  integer initialize_index;
  initial begin
    for (initialize_index = 0; initialize_index < 65536;
         initialize_index = initialize_index + 1)
      memory[initialize_index] = 16'h0000;
  end

  reg save_load_seen = 1'b0;
  reg sequence_ok = 1'b1;
  always @(posedge clk_memory) begin
    if (write_accept && write_addr[27:24] == 4'h0 &&
        write_addr[23:0] < 24'h02_0000) begin
      accepted_halves <= accepted_halves + 1'b1;
      memory[write_addr[16:1]] <= write_data;
      save_load_seen <= 1'b1;
      if (write_addr[23:0] == (body_words << 1))
        body_words <= body_words + 1'b1;
      else
        sequence_ok <= 1'b0;
    end
  end

  // Match the independent host-command CDC and the production 31-cycle drain
  // barrier.  allcomplete_74a is asserted while the final APF word is still in
  // the ingress, which is the ordering the original unit tests omitted.
  reg [2:0] allcomplete_sync = 3'b000;
  always @(posedge clk_memory)
    allcomplete_sync <= {allcomplete_sync[1:0], allcomplete_74a};
  wire allcomplete = allcomplete_sync[2];

  reg [4:0] idle_count = 5'd0;
  wire settled = &idle_count;
  always @(posedge clk_memory) begin
    if (!allcomplete || write_busy || write_valid)
      idle_count <= 5'd0;
    else if (!settled)
      idle_count <= idle_count + 1'b1;
  end

  wire finalize_safe = allcomplete && !write_busy && !write_valid && settled;
  always @(posedge clk_memory) begin
    if (!load_finalized && finalize_safe) begin
      load_finalized <= 1'b1;
      if (save_load_seen && sequence_ok && body_words == 17'd65536)
        load_complete <= 1'b1;
      else if (save_load_seen)
        load_failed <= 1'b1;
    end
  end

  assign mem_ready = load_complete;
  assign reset_held = !allcomplete || !mem_ready;
endmodule


module tb_failed_save_shutdown;
  localparam integer SAVE_BYTES = 128 * 1024;
  localparam integer SAVE_HALVES = SAVE_BYTES / 2;
  localparam integer SAVE_DWORDS = SAVE_BYTES / 4;
  localparam integer MUTATED_DWORD = 16384;
  localparam integer APF_GAP_CYCLES = 44;
  localparam [31:0] SAVE_BASE = 32'h2000_0000;

  localparam [31:0] HOST_STATUS_ADDR = 32'hF800_0000;
  localparam [31:0] HOST_PARAM0_ADDR = 32'hF800_0020;

  // Unrelated bridge and memory clocks with a non-zero phase offset.
  reg clk_74a = 1'b0;
  reg clk_memory = 1'b0;
  always #6.731 clk_74a = ~clk_74a;
  initial begin
    #0.137;
    forever #4.973 clk_memory = ~clk_memory;
  end

  reg         first_wr = 1'b0;
  reg  [31:0] first_addr = SAVE_BASE;
  reg  [31:0] first_data = 32'd0;
  reg         first_allcomplete = 1'b0;
  wire        first_busy;
  wire [16:0] first_accepted;
  wire [16:0] first_body_words;
  wire        first_complete;
  wire        first_failed;
  wire        first_finalized;
  wire        first_mem_ready;
  wire        first_reset_held;

  save_boot_model first_launch (
      .clk_74a(clk_74a),
      .clk_memory(clk_memory),
      .bridge_wr(first_wr),
      .bridge_addr(first_addr),
      .bridge_wr_data(first_data),
      .allcomplete_74a(first_allcomplete),
      .write_busy(first_busy),
      .accepted_halves(first_accepted),
      .body_words(first_body_words),
      .load_complete(first_complete),
      .load_failed(first_failed),
      .load_finalized(first_finalized),
      .mem_ready(first_mem_ready),
      .reset_held(first_reset_held)
  );

  reg         second_wr = 1'b0;
  reg  [31:0] second_addr = SAVE_BASE;
  reg  [31:0] second_data = 32'd0;
  reg         second_allcomplete = 1'b0;
  wire        second_busy;
  wire [16:0] second_accepted;
  wire [16:0] second_body_words;
  wire        second_complete;
  wire        second_failed;
  wire        second_finalized;
  wire        second_mem_ready;
  wire        second_reset_held;

  save_boot_model second_launch (
      .clk_74a(clk_74a),
      .clk_memory(clk_memory),
      .bridge_wr(second_wr),
      .bridge_addr(second_addr),
      .bridge_wr_data(second_data),
      .allcomplete_74a(second_allcomplete),
      .write_busy(second_busy),
      .accepted_halves(second_accepted),
      .body_words(second_body_words),
      .load_complete(second_complete),
      .load_failed(second_failed),
      .load_finalized(second_finalized),
      .mem_ready(second_mem_ready),
      .reset_held(second_reset_held)
  );

  // Production data_unloader in the exact failed-import state: its request is
  // visible, but read_ready can never rise because save_mem_ready is false.
  reg         failed_bridge_rd = 1'b0;
  reg  [31:0] failed_bridge_addr = SAVE_BASE;
  wire [31:0] failed_bridge_data;
  wire        failed_bridge_valid;
  wire        failed_read_en;
  wire [27:0] failed_read_addr;
  wire        failed_read_ready = first_mem_ready && !first_failed;

  data_unloader #(
      .ADDRESS_MASK_UPPER_4(4'h2),
      .ADDRESS_SIZE(28),
      .READ_MEM_CLOCK_DELAY(20),
      .INPUT_WORD_SIZE(2)
  ) failed_unloader (
      .clk_74a(clk_74a),
      .clk_memory(clk_memory),
      .bridge_rd(failed_bridge_rd),
      .bridge_endian_little(1'b1),
      .bridge_addr(failed_bridge_addr),
      .bridge_rd_data(failed_bridge_data),
      .bridge_rd_data_valid(failed_bridge_valid),
      .read_en(failed_read_en),
      .read_addr(failed_read_addr),
      .read_ready(failed_read_ready),
      .read_data(16'h0000),
      .read_data_valid(1'b0)
  );

  // The command block is production RTL.  Model the selected top-level status
  // contract around it: ACK follows request so the newly latched ID is stable
  // for a full cycle, while the explicit result distinguishes permanent boot
  // failure from a transiently unavailable export path.
  reg  [31:0] cmd_addr = 32'd0;
  reg         cmd_rd = 1'b0;
  wire [31:0] cmd_rd_data;
  reg         cmd_wr = 1'b0;
  reg  [31:0] cmd_wr_data = 32'd0;
  wire        cmd_reset_n;
  wire        cmd_requestread;
  wire [15:0] cmd_requestread_id;
  wire cmd_requestread_ack = cmd_requestread;
  reg characterize_unsafe = 1'b0;
  wire [1:0] cmd_requestread_result = characterize_unsafe ? 2'd0 :
      cmd_requestread_id == 16'd10 ?
          ((first_finalized && first_failed) ? 2'd1 :
           ((!first_finalized || !first_mem_ready || first_busy) ? 2'd2 : 2'd0)) :
      2'd1;

  wire cmd_requestwrite;
  wire [15:0] cmd_requestwrite_id;
  wire [31:0] cmd_requestwrite_size;
  wire cmd_update;
  wire [15:0] cmd_update_id;
  wire [31:0] cmd_update_size;
  wire cmd_allcomplete;
  wire [31:0] cmd_rtc_epoch;
  wire [31:0] cmd_rtc_date;
  wire [31:0] cmd_rtc_time;
  wire cmd_rtc_valid;
  wire cmd_savestate_start;
  wire cmd_savestate_load;
  wire cmd_inmenu;
  reg [9:0] datatable_addr = 10'd0;
  reg datatable_wren = 1'b0;
  reg [31:0] datatable_data = 32'd0;
  wire [31:0] datatable_q;

  core_bridge_cmd command_dut (
      .clk(clk_74a),
      .reset_n(cmd_reset_n),
      .bridge_endian_little(1'b0),
      .bridge_addr(cmd_addr),
      .bridge_rd(cmd_rd),
      .bridge_rd_data(cmd_rd_data),
      .bridge_wr(cmd_wr),
      .bridge_wr_data(cmd_wr_data),
      .status_boot_done(1'b1),
      .status_setup_done(1'b1),
      .status_running(cmd_reset_n),
      .dataslot_requestread(cmd_requestread),
      .dataslot_requestread_id(cmd_requestread_id),
      .dataslot_requestread_ack(cmd_requestread_ack),
      .dataslot_requestread_result(cmd_requestread_result),
      .dataslot_requestwrite(cmd_requestwrite),
      .dataslot_requestwrite_id(cmd_requestwrite_id),
      .dataslot_requestwrite_size(cmd_requestwrite_size),
      .dataslot_requestwrite_ack(1'b1),
      .dataslot_requestwrite_ok(1'b1),
      .dataslot_update(cmd_update),
      .dataslot_update_id(cmd_update_id),
      .dataslot_update_size(cmd_update_size),
      .dataslot_allcomplete(cmd_allcomplete),
      .rtc_epoch_seconds(cmd_rtc_epoch),
      .rtc_date_bcd(cmd_rtc_date),
      .rtc_time_bcd(cmd_rtc_time),
      .rtc_valid(cmd_rtc_valid),
      .savestate_supported(1'b1),
      .savestate_addr(32'h4000_0000),
      .savestate_size(32'h0006_0D18),
      .savestate_maxloadsize(32'h0006_0D18),
      .osnotify_inmenu(cmd_inmenu),
      .savestate_start(cmd_savestate_start),
      .savestate_start_ack(1'b0),
      .savestate_start_busy(1'b0),
      .savestate_start_ok(1'b0),
      .savestate_start_err(1'b0),
      .savestate_load(cmd_savestate_load),
      .savestate_load_ack(1'b0),
      .savestate_load_busy(1'b0),
      .savestate_load_ok(1'b0),
      .savestate_load_err(1'b0),
      .datatable_addr(datatable_addr),
      .datatable_wren(datatable_wren),
      .datatable_data(datatable_data),
      .datatable_q(datatable_q)
  );

  reg [31:0] exported_words [0:SAVE_DWORDS-1];
  integer zero_word_count = 0;
  integer index;
  integer timeout;
  reg [15:0] shutdown_result;

  function automatic [15:0] fixture_half(input integer half_index);
    reg [31:0] mixed;
    begin
      mixed = 32'h9e37_79b9 * half_index + 32'h6d2b_79f5;
      mixed = mixed ^ (mixed >> 11) ^ (mixed << 7);
      fixture_half = mixed[31:16] ^ mixed[15:0] ^ 16'ha55a;
    end
  endfunction

  task automatic pulse_first_write(input integer dword_index);
    reg [31:0] semantic_word;
    reg [31:0] semantic_addr;
    begin
      semantic_word = {fixture_half(2*dword_index + 1),
                       fixture_half(2*dword_index)};
      semantic_addr = SAVE_BASE + 4*dword_index;
      if (dword_index == MUTATED_DWORD)
        semantic_addr = semantic_addr ^ 32'h0000_0004;
      @(negedge clk_74a);
      first_addr = semantic_addr;
      first_data = semantic_word;
      first_wr = 1'b1;
      @(negedge clk_74a);
      first_wr = 1'b0;
      if (dword_index != SAVE_DWORDS-1)
        repeat (APF_GAP_CYCLES-2) @(negedge clk_74a);
    end
  endtask

  task automatic pulse_second_write(input integer dword_index);
    begin
      @(negedge clk_74a);
      second_addr = SAVE_BASE + 4*dword_index;
      second_data = exported_words[dword_index];
      second_wr = 1'b1;
      @(negedge clk_74a);
      second_wr = 1'b0;
      if (dword_index != SAVE_DWORDS-1)
        repeat (APF_GAP_CYCLES-2) @(negedge clk_74a);
    end
  endtask

  task automatic cmd_tick;
    begin
      @(posedge clk_74a);
      #1;
    end
  endtask

  task automatic cmd_write_word(
      input [31:0] address,
      input [31:0] value
  );
    begin
      cmd_addr = address;
      cmd_wr_data = value;
      cmd_wr = 1'b1;
      cmd_tick();
      cmd_wr = 1'b0;
      cmd_tick();
    end
  endtask

  task automatic start_command(input [15:0] command);
    begin
      cmd_write_word(HOST_STATUS_ADDR, {16'h434D, command});
      cmd_tick();
    end
  endtask

  initial begin : lifecycle_reproduction
    // Match Cyclone V power-up-zero behavior for APF reference registers that
    // have no source-level initializer.
    command_dut.hstate = 4'd0;
    command_dut.tstate = 2'd0;
    command_dut.host_cmd_start = 1'b0;
    command_dut.status_setup_done_1 = 1'b0;
    command_dut.target_0 = 32'd0;
    command_dut.bridge_rd_data_out = 32'd0;
    characterize_unsafe = $test$plusargs("CHARACTERIZE_UNSAFE");
    repeat (8) cmd_tick();

    // Launch 1: transfer every byte of a nonzero 128 KiB Ruby save.  One
    // address bit is deliberately mutated to stand in for any import fault;
    // the safety property below must hold regardless of the fault's cause.
    for (index = 0; index < SAVE_DWORDS; index = index + 1)
      pulse_first_write(index);

    first_allcomplete = 1'b1;
    if (!first_busy)
      $fatal(1, "allcomplete did not precede final ingress drain");

    timeout = 0;
    while (!first_finalized) begin
      @(negedge clk_memory);
      timeout = timeout + 1;
      if (timeout > 20000)
        $fatal(1, "first-launch finalize timed out");
    end
    if (first_accepted != SAVE_HALVES)
      $fatal(1, "full import was not drained: accepted=%0d", first_accepted);
    if (!first_failed || first_complete || !first_reset_held)
      $fatal(1, "injected import fault did not hold the first launch in reset");
    if (first_launch.memory[0] == 16'h0000)
      $fatal(1, "nonzero source fixture was not written before failure");
    $display("REPRO launch1: bytes=%0d accepted_halves=%0d body_words=%0d failed=%0b reset_held=%0b",
             SAVE_BYTES, first_accepted, first_body_words,
             first_failed, first_reset_held);

    // Official shutdown ordering: Reset Enter, then request-read for each
    // nonvolatile slot.  Slot 10 is the cart save.
    start_command(16'h0010);
    repeat (6) cmd_tick();
    cmd_write_word(HOST_PARAM0_ADDR, 32'd10);
    start_command(16'h0080);
    repeat (8) cmd_tick();
    shutdown_result = command_dut.host_resultcode;
    if (cmd_requestread_id != 16'd10)
      $fatal(1, "shutdown requested wrong slot: %0d", cmd_requestread_id);

    if (shutdown_result == 16'd1) begin
      if (characterize_unsafe)
        $fatal(1, "unsafe characterization unexpectedly received terminal failure");
      if (failed_read_en)
        $fatal(1, "failed import started an unload despite terminal result");
      $display("FAILED-IMPORT FAILSAFE PASS: slot=10 result=1 exported_bytes=0 reset_held=%0b",
               first_reset_held);
      $finish;
    end
    if (shutdown_result == 16'd2)
      $fatal(1, "finalized failed import returned transient result 2 instead of terminal result 1");
    if (shutdown_result != 16'd0 || !characterize_unsafe)
      $fatal(1, "failed import was incorrectly exportable (result=%0d)",
             shutdown_result);
    $display("REPRO shutdown: slot=10 result=%0d mem_ready=%0b unloader_ready=%0b",
             shutdown_result, first_mem_ready, failed_read_ready);

    // APF returns the currently buffered word before pulsing pmp_rd for the
    // next word.  The unloader's valid flag is not connected to that bridge.
    // With read_ready permanently low, every one of the declared 32,768 words
    // therefore remains the initialized zero value.
    for (index = 0; index < SAVE_DWORDS; index = index + 1) begin
      exported_words[index] = failed_bridge_data;
      if (failed_bridge_data === 32'h0000_0000)
        zero_word_count = zero_word_count + 1;
      failed_bridge_addr = SAVE_BASE + 4*index;
      @(negedge clk_74a);
      failed_bridge_rd = 1'b1;
      @(negedge clk_74a);
      failed_bridge_rd = 1'b0;
      repeat (2) @(negedge clk_74a);
    end
    if (zero_word_count != SAVE_DWORDS)
      $fatal(1, "blocked export was not entirely zero: %0d/%0d words",
             zero_word_count, SAVE_DWORDS);
    if (!failed_read_en || failed_read_ready || failed_bridge_valid)
      $fatal(1, "blocked unloader did not remain stalled after full host readout");
    $display("REPRO exit: declared_bytes=%0d returned_zero_words=%0d memory_responses=0",
             SAVE_BYTES, zero_word_count);

    // Launch 2: the just-written all-zero 128 KiB file is structurally exact,
    // so the same lifecycle accepts it and releases reset.  Its contents are
    // nevertheless the corrupted file observed on hardware.
    for (index = 0; index < SAVE_DWORDS; index = index + 1)
      pulse_second_write(index);

    second_allcomplete = 1'b1;
    if (!second_busy)
      $fatal(1, "second allcomplete did not precede final ingress drain");
    timeout = 0;
    while (!second_finalized) begin
      @(negedge clk_memory);
      timeout = timeout + 1;
      if (timeout > 20000)
        $fatal(1, "second-launch finalize timed out");
    end
    if (second_accepted != SAVE_HALVES || second_body_words != SAVE_HALVES ||
        !second_complete || second_failed || !second_mem_ready || second_reset_held)
      $fatal(1, "second launch did not accept exact zero file and release reset");
    for (index = 0; index < SAVE_HALVES; index = index + 1)
      if (second_launch.memory[index] !== 16'h0000)
        $fatal(1, "second-launch memory was nonzero at halfword %0d", index);
    $display("REPRO launch2: bytes=%0d accepted_halves=%0d complete=%0b reset_held=%0b all_zero=1",
             SAVE_BYTES, second_accepted, second_complete, second_reset_held);

    if (characterize_unsafe) begin
      $display("CHARACTERIZED_UNSAFE_FAILURE: black-first-launch -> accepted shutdown -> 128KiB zeros -> booting-second-launch");
      $finish;
    end

    $fatal(1,
      "SAFETY REGRESSION: slot 10 request-read succeeded while failed save import was not exportable");
  end
endmodule


// Reference contract for the production request-read interface.  A two-bit
// result is required because the old boolean cannot distinguish a permanently
// invalid import (1: not allowed) from a transiently busy path (2: retry).
module dataslot_read_guard_contract (
    input  wire        request,
    input  wire [15:0] request_id,

    input  wire        cart_finalized,
    input  wire        cart_failed,
    input  wire        cart_ready,
    input  wire        cart_quiescent,

    input  wire        rtc_finalized,
    input  wire        rtc_invalid,
    input  wire        rtc_ready,
    input  wire        rtc_quiescent,

    output wire        acknowledge,
    output reg  [1:0]  result
);
  localparam [1:0] RESULT_OK          = 2'd0;
  localparam [1:0] RESULT_NOT_ALLOWED = 2'd1;
  localparam [1:0] RESULT_RETRY       = 2'd2;

  // core_bridge_cmd raises request and latches request_id on its first ST_PARSE
  // edge. Feeding request back as ACK makes it consume result only on the next
  // edge, after request_id and the selected result have been stable a full
  // cycle. A constant ACK does not provide that guarantee.
  assign acknowledge = request;

  always @(*) begin
    case (request_id)
      16'd10: begin
        if (cart_finalized && cart_failed)
          result = RESULT_NOT_ALLOWED;
        else if (!cart_finalized || !cart_ready || !cart_quiescent)
          result = RESULT_RETRY;
        else
          result = RESULT_OK;
      end
      16'd11: begin
        if (rtc_finalized && rtc_invalid)
          result = RESULT_NOT_ALLOWED;
        else if (!rtc_finalized || !rtc_ready || !rtc_quiescent)
          result = RESULT_RETRY;
        else
          result = RESULT_OK;
      end
      default: result = RESULT_NOT_ALLOWED;
    endcase
  end
endmodule


// Minimal model of core_bridge_cmd's 0x0080 ST_PARSE behavior with the proposed
// explicit result port. It is intentionally small: the production decoder is
// already exercised above, while this model specifies the new handshake that
// the old interface cannot express.
module requestread_command_contract (
    input  wire        clk,
    input  wire        start,
    input  wire [15:0] command_id,
    output reg         request = 1'b0,
    output reg  [15:0] request_id = 16'd0,
    input  wire        acknowledge,
    input  wire [1:0]  request_result,
    output reg         done = 1'b0,
    output reg  [15:0] host_result = 16'd0
);
  localparam IDLE = 1'b0;
  localparam PARSE = 1'b1;
  reg state = IDLE;

  always @(posedge clk) begin
    done <= 1'b0;
    case (state)
      IDLE: begin
        request <= 1'b0;
        if (start)
          state <= PARSE;
      end
      PARSE: begin
        request <= 1'b1;
        request_id <= command_id;
        if (acknowledge) begin
          host_result <= {14'd0, request_result};
          request <= 1'b0;
          done <= 1'b1;
          state <= IDLE;
        end
      end
    endcase
  end
endmodule


// Once boot finalization is sticky, command 0x0080 is allowed to clear the
// allcomplete level and its derived drain counter without revoking an already
// authorized stream.  Current client activity still gates every transfer.
module finalized_export_quiescence_contract (
    input  wire reset_n_s,
    input  wire save_load_finalized,
    input  wire save_loader_busy,
    input  wire save_loader_grant,
    input  wire psram_busy,
    input  wire save_unload_pending,
    input  wire clear_client_idle,
    input  wire bus_client_idle,
    input  wire dataslot_allcomplete_s,
    input  wire save_loader_settled,
    output wire export_quiescent
);
  // dataslot_allcomplete_s and save_loader_settled are intentionally absent:
  // 0x0080 clears allcomplete before Pocket starts its pipelined reads.
  assign export_quiescent = !reset_n_s && save_load_finalized &&
      !save_loader_busy && !save_loader_grant && !psram_busy &&
      !save_unload_pending && clear_client_idle && bus_client_idle;
endmodule


module tb_dataslot_read_contract;
  localparam [1:0] RESULT_OK          = 2'd0;
  localparam [1:0] RESULT_NOT_ALLOWED = 2'd1;
  localparam [1:0] RESULT_RETRY       = 2'd2;

  reg clk = 1'b0;
  reg clk_memory = 1'b0;
  always #5 clk = ~clk;
  initial begin
    #0.173;
    forever #3.719 clk_memory = ~clk_memory;
  end

  reg start = 1'b0;
  reg [15:0] command_id = 16'd0;
  wire request;
  wire [15:0] request_id;
  wire acknowledge;
  wire [1:0] request_result;
  wire done;
  wire [15:0] host_result;

  reg cart_finalized = 1'b0;
  reg cart_failed = 1'b0;
  reg cart_ready = 1'b0;
  reg cart_quiescent = 1'b0;
  reg rtc_finalized = 1'b0;
  reg rtc_invalid = 1'b0;
  reg rtc_ready = 1'b0;
  reg rtc_quiescent = 1'b0;

  reg shutdown_reset_n_s = 1'b0;
  reg shutdown_finalized = 1'b1;
  reg shutdown_loader_busy = 1'b0;
  reg shutdown_loader_grant = 1'b0;
  reg shutdown_psram_busy = 1'b0;
  reg shutdown_unload_pending = 1'b0;
  reg shutdown_clear_idle = 1'b1;
  reg shutdown_bus_idle = 1'b1;
  reg shutdown_allcomplete = 1'b1;
  reg shutdown_loader_settled = 1'b1;
  wire shutdown_export_quiescent;

  finalized_export_quiescence_contract shutdown_guard (
      .reset_n_s(shutdown_reset_n_s),
      .save_load_finalized(shutdown_finalized),
      .save_loader_busy(shutdown_loader_busy),
      .save_loader_grant(shutdown_loader_grant),
      .psram_busy(shutdown_psram_busy),
      .save_unload_pending(shutdown_unload_pending),
      .clear_client_idle(shutdown_clear_idle),
      .bus_client_idle(shutdown_bus_idle),
      .dataslot_allcomplete_s(shutdown_allcomplete),
      .save_loader_settled(shutdown_loader_settled),
      .export_quiescent(shutdown_export_quiescent)
  );

  dataslot_read_guard_contract guard (
      .request(request),
      .request_id(request_id),
      .cart_finalized(cart_finalized),
      .cart_failed(cart_failed),
      .cart_ready(cart_ready),
      .cart_quiescent(cart_quiescent),
      .rtc_finalized(rtc_finalized),
      .rtc_invalid(rtc_invalid),
      .rtc_ready(rtc_ready),
      .rtc_quiescent(rtc_quiescent),
      .acknowledge(acknowledge),
      .result(request_result)
  );

  requestread_command_contract command (
      .clk(clk),
      .start(start),
      .command_id(command_id),
      .request(request),
      .request_id(request_id),
      .acknowledge(acknowledge),
      .request_result(request_result),
      .done(done),
      .host_result(host_result)
  );

  integer check_count = 0;
  reg previous_request = 1'b0;
  always @(posedge clk) begin
    #1;
    if (acknowledge !== request)
      $fatal(1, "ACK is not the required one-cycle request feedback");
    previous_request <= request;
  end

  task automatic issue_request(
      input [15:0] selected_id,
      input [1:0] expected_result,
      input [255:0] label_text
  );
    begin
      @(negedge clk);
      command_id = selected_id;
      start = 1'b1;
      @(posedge clk);
      #1;
      start = 1'b0;

      // First PARSE edge publishes request/id. It must not also complete: that
      // would sample the previous request ID, which is the canonical bug.
      @(posedge clk);
      #1;
      if (!request || request_id !== selected_id || done)
        $fatal(1, "%0s: request/id were not exposed before completion", label_text);
      if (!acknowledge)
        $fatal(1, "%0s: deferred ACK did not become visible", label_text);
      if (request_result !== expected_result)
        $fatal(1, "%0s: stable result=%0d expected=%0d",
               label_text, request_result, expected_result);

      // Only the following edge may consume ACK/result.
      @(posedge clk);
      #1;
      if (!done || host_result !== {14'd0, expected_result})
        $fatal(1, "%0s: host result=%0d expected=%0d",
               label_text, host_result, expected_result);
      check_count = check_count + 1;
      @(posedge clk);
      #1;
      if (done || request)
        $fatal(1, "%0s: command did not return idle", label_text);
    end
  endtask

  // Address-specific readiness required to make slot 11 independent.  The
  // current production global cart gate cannot satisfy this property.
  reg [27:0] unloader_addr = 28'h0000_000;
  wire selected_unloader_ready =
      (unloader_addr[27:24] == 4'h0 && cart_ready && !cart_failed) ||
      (unloader_addr[27:24] == 4'h1 && rtc_ready && !rtc_invalid);

  // Prove the address-specific gate with the production unloader, not just
  // with the combinational status result. A failed cart must not prevent a
  // later slot-11 read because Pocket never issues bridge reads for a slot
  // whose request-read command returned result 1.
  reg independent_bridge_rd = 1'b0;
  reg [31:0] independent_bridge_addr = 32'h2100_0000;
  wire [31:0] independent_bridge_data;
  wire independent_bridge_valid;
  wire independent_read_en;
  wire [27:0] independent_read_addr;
  wire independent_read_ready =
      (independent_read_addr[27:24] == 4'h0 && cart_ready && !cart_failed) ||
      (independent_read_addr[27:24] == 4'h1 && rtc_ready && !rtc_invalid);
  reg [15:0] independent_read_data = 16'd0;
  reg independent_read_data_valid = 1'b0;

  data_unloader #(
      .ADDRESS_MASK_UPPER_4(4'h2),
      .ADDRESS_SIZE(28),
      .READ_MEM_CLOCK_DELAY(20),
      .INPUT_WORD_SIZE(2)
  ) independent_unloader (
      .clk_74a(clk),
      .clk_memory(clk_memory),
      .bridge_rd(independent_bridge_rd),
      .bridge_endian_little(1'b1),
      .bridge_addr(independent_bridge_addr),
      .bridge_rd_data(independent_bridge_data),
      .bridge_rd_data_valid(independent_bridge_valid),
      .read_en(independent_read_en),
      .read_addr(independent_read_addr),
      .read_ready(independent_read_ready),
      .read_data(independent_read_data),
      .read_data_valid(independent_read_data_valid)
  );

  function automatic [15:0] rtc_fixture_word(input [27:0] address);
    begin
      case (address[3:1])
        3'd0: rtc_fixture_word = 16'h1357;
        3'd1: rtc_fixture_word = 16'h2468;
        default: rtc_fixture_word = 16'h0000;
      endcase
    end
  endfunction

  always @(posedge clk_memory) begin
    independent_read_data_valid <= 1'b0;
    if (independent_read_en && independent_read_ready) begin
      independent_read_data <= rtc_fixture_word(independent_read_addr);
      independent_read_data_valid <= 1'b1;
    end
  end

  task automatic prove_independent_rtc_unload;
    integer timeout;
    begin
      if (!independent_bridge_valid)
        $fatal(1, "RTC unloader did not begin with APF dummy word valid");
      @(negedge clk);
      independent_bridge_addr = 32'h2100_0000;
      independent_bridge_rd = 1'b1;
      @(negedge clk);
      independent_bridge_rd = 1'b0;

      timeout = 0;
      while (independent_bridge_valid) begin
        @(negedge clk);
        timeout = timeout + 1;
        if (timeout > 20)
          $fatal(1, "RTC unloader did not begin its transaction");
      end
      timeout = 0;
      while (!independent_bridge_valid) begin
        @(negedge clk);
        timeout = timeout + 1;
        if (timeout > 200)
          $fatal(1, "independent RTC unload timed out behind failed cart");
      end
      if (independent_bridge_data !== 32'h2468_1357)
        $fatal(1, "independent RTC unload data=%08x expected=24681357",
               independent_bridge_data);
      check_count = check_count + 1;
    end
  endtask

  task automatic prove_stream_survives_allcomplete_clear;
    begin
      #1;
      if (!shutdown_export_quiescent)
        $fatal(1, "finalized stream was not initially quiescent");

      // This is the production side effect of accepting 0x0080.  The boot
      // drain counter falls with allcomplete, but finalization remains sticky.
      shutdown_allcomplete = 1'b0;
      shutdown_loader_settled = 1'b0;
      #1;
      if (!shutdown_export_quiescent)
        $fatal(1, "0x0080 allcomplete clear revoked finalized export");

      shutdown_psram_busy = 1'b1;
      #1;
      if (shutdown_export_quiescent)
        $fatal(1, "live PSRAM activity did not block export");
      shutdown_psram_busy = 1'b0;
      #1;
      if (!shutdown_export_quiescent)
        $fatal(1, "export did not recover after PSRAM became idle");
      check_count = check_count + 1;
    end
  endtask

  initial begin
    repeat (4) @(posedge clk);

    prove_stream_survives_allcomplete_clear();

    cart_finalized = 1'b1;
    cart_failed = 1'b1;
    cart_ready = 1'b0;
    cart_quiescent = 1'b1;
    issue_request(16'd10, RESULT_NOT_ALLOWED,
                  "finalized failed cart import");

    cart_finalized = 1'b0;
    cart_failed = 1'b0;
    cart_ready = 1'b0;
    cart_quiescent = 1'b0;
    issue_request(16'd10, RESULT_RETRY,
                  "incomplete cart import");

    cart_finalized = 1'b1;
    cart_ready = 1'b1;
    cart_quiescent = 1'b0;
    issue_request(16'd10, RESULT_RETRY,
                  "verified cart still draining");

    cart_quiescent = 1'b1;
    issue_request(16'd10, RESULT_OK,
                  "verified quiescent cart");

    issue_request(16'd99, RESULT_NOT_ALLOWED,
                  "unknown nonvolatile slot");

    // RTC status is deliberately independent of the failed cart status.
    cart_failed = 1'b1;
    cart_ready = 1'b0;
    rtc_finalized = 1'b0;
    rtc_invalid = 1'b0;
    rtc_ready = 1'b0;
    rtc_quiescent = 1'b0;
    issue_request(16'd11, RESULT_RETRY,
                  "RTC initialization incomplete");

    rtc_finalized = 1'b1;
    rtc_invalid = 1'b1;
    rtc_quiescent = 1'b1;
    issue_request(16'd11, RESULT_NOT_ALLOWED,
                  "finalized invalid RTC record");

    rtc_invalid = 1'b0;
    rtc_ready = 1'b1;
    issue_request(16'd11, RESULT_OK,
                  "ready RTC despite failed cart");

    unloader_addr = 28'h0000_000;
    #1;
    if (selected_unloader_ready)
      $fatal(1, "failed cart region was incorrectly unload-ready");
    unloader_addr = 28'h1000_000;
    #1;
    if (!selected_unloader_ready)
      $fatal(1, "RTC region inherited failed cart readiness");
    check_count = check_count + 2;

    prove_independent_rtc_unload();

    if (check_count != 12)
      $fatal(1, "contract check count mismatch: %0d", check_count);
    $display("REQUESTREAD CONTRACT PASS checks=%0d results={permanent:1 transient:2 verified:0} rtc_independent=1",
             check_count);
    $finish;
  end
endmodule

`default_nettype wire
