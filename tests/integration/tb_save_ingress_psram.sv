`timescale 1ns/1ps

// Field-trigger audit only: exercise the exact dev shared APF ingress and
// registered save-loader grant against the production PSRAM controller for a
// complete 128 KiB FLASH1M import at Pocket's documented worst-case cadence.
module tb_save_ingress_psram #(
  parameter integer SAVE_HALFWORDS = 65536
);
  localparam [1:0] DEST_ROM  = 2'd1;
  localparam [1:0] DEST_SAVE = 2'd2;
  localparam [1:0] DEST_BIOS = 2'd3;
  localparam integer APF_WORDS = SAVE_HALFWORDS / 2;

  reg clk_74a = 1'b0;
  reg clk_sys = 1'b0;
  always #6.734 clk_74a = ~clk_74a;       // 74.25 MHz
  initial begin
    #0.319;
    forever #4.967 clk_sys = ~clk_sys;    // 100.66 MHz
  end

  reg pll_core_locked = 1'b0;
  reg bridge_wr = 1'b0;
  reg bridge_endian_little = 1'b1;
  reg [31:0] bridge_addr = 32'd0;
  reg [31:0] bridge_wr_data = 32'd0;
  reg dataslot_allcomplete_74 = 1'b0;

  wire ingress_valid;
  wire [1:0] ingress_dest;
  wire [27:0] ingress_addr;
  wire [15:0] ingress_data;
  wire ingress_busy;
  wire ingress_ready;
  wire ingress_accept = ingress_valid && ingress_ready;

  wire save_loader_wr = ingress_valid && ingress_dest == DEST_SAVE;
  wire save_loader_accept = ingress_accept && ingress_dest == DEST_SAVE;
  wire [27:0] save_loader_addr = ingress_addr;
  wire [15:0] save_loader_data = ingress_data;
  wire save_loader_busy = ingress_busy;
  wire save_loader_is_cart = save_loader_addr[27:24] == 4'h0;
  wire save_loader_is_rtc = save_loader_addr[27:24] == 4'h1;
  wire save_loader_known_slot = save_loader_is_cart | save_loader_is_rtc;

  wire save_loader_ready;
  assign ingress_ready = ingress_dest == DEST_SAVE ? save_loader_ready :
                         ingress_dest == DEST_ROM ? 1'b1 :
                         ingress_dest == DEST_BIOS ? 1'b1 : 1'b0;

  apf_write_ingress #(
      .ROM_WRITE_DELAY(20),
      .SAVE_WRITE_DELAY(20),
      .BIOS_WRITE_DELAY(4)
  ) ingress (
      .clk_74a(clk_74a),
      .clk_memory(clk_sys),
      .bridge_wr(bridge_wr),
      .bridge_endian_little(bridge_endian_little),
      .bridge_addr(bridge_addr),
      .bridge_wr_data(bridge_wr_data),
      .write_valid(ingress_valid),
      .write_dest(ingress_dest),
      .write_addr(ingress_addr),
      .write_data(ingress_data),
      .write_ready(ingress_ready),
      .write_busy(ingress_busy)
  );

  reg save_loader_grant = 1'b0;
  reg [21:0] save_loader_grant_addr = 22'd0;
  reg [15:0] save_loader_grant_data = 16'd0;
  wire [23:0] save_size_sys = SAVE_HALFWORDS * 2;

  always @(posedge clk_sys) begin
    save_loader_grant <= 1'b0;
    if (!pll_core_locked) begin
      save_loader_grant_addr <= 22'd0;
      save_loader_grant_data <= 16'd0;
    end else if (save_loader_accept && save_loader_is_cart &&
                 save_loader_addr[23:0] < save_size_sys) begin
      save_loader_grant <= 1'b1;
      save_loader_grant_addr <= save_loader_addr[21:1];
      save_loader_grant_data <= save_loader_data;
    end
  end

  wire psram_busy;
  wire psram_read_avail;
  wire [15:0] psram_data_out;
  wire psram_write_en = save_loader_grant;
  wire psram_read_en = 1'b0;
  wire psram_bank_sel = 1'b1;
  wire [21:0] psram_addr = save_loader_grant_addr;
  wire [15:0] psram_data_in = save_loader_grant_data;
  wire psram_write_high = 1'b1;
  wire psram_write_low = 1'b1;
  wire [21:16] cram_a;
  tri [15:0] cram_dq;
  wire cram_clk;
  wire cram_adv_n;
  wire cram_cre;
  wire cram_ce0_n;
  wire cram_ce1_n;
  wire cram_oe_n;
  wire cram_we_n;
  wire cram_ub_n;
  wire cram_lb_n;

  psram #(.CLOCK_SPEED(100.66)) save_psram (
      .clk(clk_sys),
      .bank_sel(psram_bank_sel),
      .addr(psram_addr),
      .write_en(psram_write_en),
      .data_in(psram_data_in),
      .write_high_byte(psram_write_high),
      .write_low_byte(psram_write_low),
      .read_en(psram_read_en),
      .read_avail(psram_read_avail),
      .data_out(psram_data_out),
      .busy(psram_busy),
      .cram_a(cram_a),
      .cram_dq(cram_dq),
      .cram_wait(1'b0),
      .cram_clk(cram_clk),
      .cram_adv_n(cram_adv_n),
      .cram_cre(cram_cre),
      .cram_ce0_n(cram_ce0_n),
      .cram_ce1_n(cram_ce1_n),
      .cram_oe_n(cram_oe_n),
      .cram_we_n(cram_we_n),
      .cram_ub_n(cram_ub_n),
      .cram_lb_n(cram_lb_n)
  );

  // Same acceptance gate as core_top during boot; all other clients are idle.
  assign save_loader_ready = pll_core_locked && save_loader_known_slot &&
      !save_loader_grant && !psram_busy;

  // Model the externally committed memory at the edge where the PSRAM
  // controller accepts a registered grant. This traverses the real controller
  // busy/start pipeline while avoiding a vendor-specific CRAM pin model.
  reg [15:0] committed [0:SAVE_HALFWORDS-1];
  integer physical_writes = 0;
  integer duplicate_writes = 0;
  integer rtc_accepts = 0;
  reg seen [0:SAVE_HALFWORDS-1];
  integer idx;
  always @(posedge clk_sys) begin
    if (save_loader_accept && save_loader_is_rtc)
      rtc_accepts = rtc_accepts + 1;
    if (psram_write_en && !psram_busy) begin
      if (!psram_bank_sel)
        $fatal(1, "save write selected wrong PSRAM die");
      if (psram_addr >= SAVE_HALFWORDS)
        $fatal(1, "save write address out of range: %0d", psram_addr);
      if (seen[psram_addr])
        duplicate_writes = duplicate_writes + 1;
      seen[psram_addr] <= 1'b1;
      committed[psram_addr] <= psram_data_in;
      physical_writes = physical_writes + 1;
    end
  end

  // Validator/finalization logic copied from the production save path.
  reg save_load_seen = 1'b0;
  reg save_load_complete = 1'b0;
  reg save_load_failed = 1'b0;
  reg save_load_finalized = 1'b0;
  reg save_load_sequence_ok = 1'b1;
  reg [16:0] save_load_body_words = 17'd0;
  reg [4:0] save_loader_idle_count = 5'd0;
  wire save_loader_settled = &save_loader_idle_count;

  reg [2:0] allcomplete_sync = 3'b000;
  always @(posedge clk_sys)
    allcomplete_sync <= {allcomplete_sync[1:0], dataslot_allcomplete_74};
  wire dataslot_allcomplete_s = allcomplete_sync[2];
  wire save_finalize_safe = !save_loader_busy && !save_loader_grant &&
      !psram_busy && save_loader_settled;

  always @(posedge clk_sys) begin
    if (!pll_core_locked || !dataslot_allcomplete_s || save_loader_busy ||
        save_loader_wr || save_loader_grant || psram_busy)
      save_loader_idle_count <= 5'd0;
    else if (!save_loader_settled)
      save_loader_idle_count <= save_loader_idle_count + 1'b1;
  end

  always @(posedge clk_sys) begin
    if (!pll_core_locked) begin
      save_load_seen <= 1'b0;
      save_load_complete <= 1'b0;
      save_load_failed <= 1'b0;
      save_load_finalized <= 1'b0;
      save_load_sequence_ok <= 1'b1;
      save_load_body_words <= 17'd0;
    end else begin
      if (save_loader_accept && save_loader_is_cart &&
          save_loader_addr[23:0] < save_size_sys) begin
        save_load_seen <= 1'b1;
        if (save_loader_addr[23:0] == (save_load_body_words << 1))
          save_load_body_words <= save_load_body_words + 1'b1;
        else
          save_load_sequence_ok <= 1'b0;
      end

      if (!save_load_finalized && dataslot_allcomplete_s &&
          save_finalize_safe) begin
        save_load_finalized <= 1'b1;
        if (save_load_seen) begin
          if (save_load_sequence_ok && save_load_body_words == SAVE_HALFWORDS)
            save_load_complete <= 1'b1;
          else
            save_load_failed <= 1'b1;
        end
      end
    end
  end

  function automatic [15:0] expected_half(input integer half_index);
    begin
      expected_half = ((half_index * 16'h1f3d) ^ (half_index >> 3) ^ 16'ha55a);
    end
  endfunction

  task automatic apf_write(input integer word_index);
    begin
      @(negedge clk_74a);
      bridge_addr = 32'h2000_0000 + word_index * 4;
      bridge_wr_data = {expected_half(word_index * 2 + 1),
                        expected_half(word_index * 2)};
      bridge_wr = 1'b1;
      @(negedge clk_74a);
      bridge_wr = 1'b0;
      // Total rising-edge start cadence is 88 clk_74a cycles.
      repeat (86) @(negedge clk_74a);
    end
  endtask

  task automatic apf_rtc_write(input integer word_index);
    begin
      @(negedge clk_74a);
      bridge_addr = 32'h2100_0000 + word_index * 4;
      bridge_wr_data = 32'h6a7e_0000 ^ word_index;
      bridge_wr = 1'b1;
      @(negedge clk_74a);
      bridge_wr = 1'b0;
      repeat (86) @(negedge clk_74a);
    end
  endtask

  initial begin
    for (idx = 0; idx < SAVE_HALFWORDS; idx = idx + 1) begin
      committed[idx] = 16'hxxxx;
      seen[idx] = 1'b0;
    end

    repeat (12) @(negedge clk_sys);
    pll_core_locked = 1'b1;
    repeat (12) @(negedge clk_74a);

    for (idx = 0; idx < APF_WORDS; idx = idx + 1) begin
      apf_write(idx);
      if ((idx & 4095) == 4095)
        $display("IMPORT progress APF words=%0d accepted_halves=%0d physical=%0d",
                 idx + 1, save_load_body_words, physical_writes);
    end

    // The field launch also had a separate 16-byte RTC sidecar. It shares the
    // ingress destination but must neither enter PSRAM nor perturb cart-body
    // sequence validation.
    for (idx = 0; idx < 4; idx = idx + 1)
      apf_rtc_write(idx);

    // Match Pocket: allcomplete can follow the final bridge transaction before
    // the CDC write pointer and target pipeline have fully drained.
    @(negedge clk_74a);
    dataslot_allcomplete_74 = 1'b1;

    idx = 0;
    while (!save_load_finalized) begin
      @(negedge clk_sys);
      idx = idx + 1;
      if (idx > 10000)
        $fatal(1, "save finalization timed out busy=%0b count=%0d physical=%0d",
               save_loader_busy, save_load_body_words, physical_writes);
    end

    if (!save_load_complete || save_load_failed || !save_load_sequence_ok)
      $fatal(1,
             "validator rejected full import complete=%0b failed=%0b seq=%0b count=%0d",
             save_load_complete, save_load_failed, save_load_sequence_ok,
             save_load_body_words);
    if (physical_writes != SAVE_HALFWORDS || duplicate_writes != 0)
      $fatal(1, "physical write count mismatch writes=%0d duplicates=%0d",
             physical_writes, duplicate_writes);
    if (rtc_accepts != 8)
      $fatal(1, "RTC sidecar acceptance mismatch: %0d", rtc_accepts);

    for (idx = 0; idx < SAVE_HALFWORDS; idx = idx + 1) begin
      if (!seen[idx])
        $fatal(1, "missing physical write at halfword %0d", idx);
      if (committed[idx] !== expected_half(idx))
        $fatal(1, "data mismatch at halfword %0d expected=%04x actual=%04x",
               idx, expected_half(idx), committed[idx]);
    end

    $display("FULL-128K IMPORT PASS accepted=%0d physical=%0d duplicates=%0d rtc=%0d",
             save_load_body_words, physical_writes, duplicate_writes,
             rtc_accepts);
    $finish;
  end
endmodule
