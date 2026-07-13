// =============================================================================
// tb_iq_top_directed.sv — Directed Integration Tests (Step 4)
// =============================================================================
// Purpose:
//   End-to-end tests that exercise the full issue queue pipeline:
//   dispatch → wakeup → age → select → issue, using iq_top with a small
//   DEPTH=4 queue. Each test targets a specific microarchitectural scenario.
//
//   Test catalog (8 directed tests):
//     1. single_chain     : A→B dependency, dispatch A, wake A, issue A,
//                           wake B (via A's dst_tag), issue B.
//     2. multi_ready      : 3 entries ready simultaneously, oldest issues first.
//     3. backpressure     : fill all 4 slots, confirm dispatch_ready=0,
//                           issue one, confirm dispatch_ready=1.
//     4. bypass_dispatch  : same-cycle dispatch + matching wakeup.
//     5. immediate_src    : dispatch with immediate source, ready at dispatch.
//     6. multi_port_issue : 2 entries ready → both ports issue same cycle.
//     7. age_ordering     : 3 entries dispatched at different times, oldest
//                           ready wins even if dispatched first.
//     8. slot_reuse       : issue entry 0, dispatch new into entry 0's slot,
//                           verify the new instruction works correctly.
// =============================================================================

`timescale 1ns/1ps

`include "iq_pkg.sv"

import iq_pkg::*;

module tb_iq_top_directed;

  // -------------------------------------------------------------------------
  // TB parameters
  // -------------------------------------------------------------------------
  localparam int unsigned TB_DEPTH     = 4;
  localparam int unsigned TB_NUM_PORTS = 2;
  localparam int unsigned IDX_W        = $clog2(TB_DEPTH);

  // -------------------------------------------------------------------------
  // Error counter + CHK macro
  // -------------------------------------------------------------------------
  int errors = 0;

  `define CHK(cond, msg) \
    do begin \
      if (cond) begin \
        $display("    [PASS] %0t: %s", $time, msg); \
      end else begin \
        $display("    [FAIL] %0t: %s", $time, msg); \
        errors = errors + 1; \
      end \
    end while (0)

  // -------------------------------------------------------------------------
  // DUT signals
  // -------------------------------------------------------------------------
  logic                                       clk;
  logic                                       rst_n;

  logic                                       dispatch_valid;
  logic [TAG_WIDTH-1:0]                       dispatch_dst_tag;
  logic [NUM_SRC-1:0][TAG_WIDTH-1:0]          dispatch_src_tag;
  logic [NUM_SRC-1:0]                         dispatch_src_imm;

  logic                                       dispatch_ready;
  logic [IDX_W-1:0]                           dispatch_slot_idx;

  logic                                       wakeup_valid;
  logic [TAG_WIDTH-1:0]                       wakeup_tag;

  logic [TB_NUM_PORTS-1:0]                    issue_valid;
  logic [TB_NUM_PORTS-1:0][IDX_W-1:0]         issue_idx;
  logic [TB_NUM_PORTS-1:0][TAG_WIDTH-1:0]     issue_dst_tag;
  logic [TB_NUM_PORTS-1:0][AGE_WIDTH-1:0]     issue_age;

  logic                                       squash_en;

  // -------------------------------------------------------------------------
  // Clock
  // -------------------------------------------------------------------------
  initial clk = 1'b0;
  always #5 clk = ~clk;

  // -------------------------------------------------------------------------
  // DUT
  // -------------------------------------------------------------------------
  iq_top #(
      .DEPTH     (TB_DEPTH),
      .TAG_WIDTH (TAG_WIDTH),
      .NUM_SRC   (NUM_SRC),
      .AGE_WIDTH (AGE_WIDTH),
      .NUM_PORTS (TB_NUM_PORTS)
  ) dut (
      .clk               (clk),
      .rst_n             (rst_n),
      .dispatch_valid    (dispatch_valid),
      .dispatch_dst_tag  (dispatch_dst_tag),
      .dispatch_src_tag  (dispatch_src_tag),
      .dispatch_src_imm  (dispatch_src_imm),
      .dispatch_ready    (dispatch_ready),
      .dispatch_slot_idx (dispatch_slot_idx),
      .wakeup_valid      (wakeup_valid),
      .wakeup_tag        (wakeup_tag),
      .issue_valid       (issue_valid),
      .issue_idx         (issue_idx),
      .issue_dst_tag     (issue_dst_tag),
      .issue_age         (issue_age),
      .squash_en         (squash_en)
  );

  // =========================================================================
  // Helper tasks
  // =========================================================================

  task automatic do_reset;
      @(posedge clk);
      rst_n = 1'b0;
      repeat (3) @(posedge clk);
      rst_n = 1'b1;
      @(posedge clk);
      #1;
  endtask

  // Dispatch one instruction. Returns the allocated slot index.
  task automatic do_dispatch(
      input logic [TAG_WIDTH-1:0]              dst,
      input logic [NUM_SRC-1:0][TAG_WIDTH-1:0] src,
      input logic [NUM_SRC-1:0]                imm,
      output logic [IDX_W-1:0]                 slot
  );
      @(posedge clk);
      dispatch_valid   = 1'b1;
      dispatch_dst_tag = dst;
      dispatch_src_tag = src;
      dispatch_src_imm = imm;
      @(posedge clk);   // capturing edge
      #1;
      slot = dispatch_slot_idx;
      dispatch_valid = 1'b0;
  endtask

  // Broadcast a wakeup tag for one cycle.
  task automatic do_wakeup(input logic [TAG_WIDTH-1:0] tag);
      @(posedge clk);
      wakeup_valid = 1'b1;
      wakeup_tag   = tag;
      @(posedge clk);
      #1;
      wakeup_valid = 1'b0;
  endtask

  // Wait one cycle and sample outputs (for letting issues take effect).
  task automatic tick;
      @(posedge clk);
      #1;
  endtask

  // =========================================================================
  // Test 1: single_chain — A depends on external, B depends on A
  // =========================================================================
  // Dispatch A (dst=0x01, src0=0x10, src1 imm).
  // Wake A's src0 (tag 0x10) → A becomes ready → A issues.
  // Dispatch B (dst=0x02, src0=0x01, src1 imm) — B depends on A's result.
  // Wake B's src0 (tag 0x01, which is A's dst) → B issues.
  task automatic test_single_chain;
      logic [IDX_W-1:0] slot;
      logic [NUM_SRC-1:0][TAG_WIDTH-1:0] src;
      $display("\n[TEST] test_single_chain: A→B dependency chain");

      // Dispatch A: needs tag 0x10 for src0, src1 is immediate.
      src[0] = 'h10;  src[1] = 'h0;
      do_dispatch('h01, src, 2'b10, slot);  // src1 imm
      `CHK(dispatch_ready === 1'b1, "chain: dispatch_ready after A");

      // Wake A's src0.
      do_wakeup('h10);
      // A should now be ready and issued by port 0.
      `CHK(issue_valid[0] === 1'b1, "chain: A issues after wakeup");
      `CHK(issue_dst_tag[0] === 'h01, "chain: A's dst_tag on issue bus");

      // Let A's issue clear take effect.
      tick();
      `CHK(issue_valid[0] === 1'b0, "chain: no issue after A cleared");

      // Dispatch B: depends on A's output (tag 0x01), src1 immediate.
      src[0] = 'h01;  src[1] = 'h0;
      do_dispatch('h02, src, 2'b10, slot);

      // Wake B's src0 with A's dst_tag (0x01).
      do_wakeup('h01);
      `CHK(issue_valid[0] === 1'b1, "chain: B issues after wakeup with A's tag");
      `CHK(issue_dst_tag[0] === 'h02, "chain: B's dst_tag on issue bus");

      tick();
  endtask

  // =========================================================================
  // Test 2: multi_ready — 3 entries ready, oldest issues first
  // =========================================================================
  task automatic test_multi_ready;
      logic [IDX_W-1:0] slot;
      logic [NUM_SRC-1:0][TAG_WIDTH-1:0] src;
      $display("\n[TEST] test_multi_ready: 3 entries, oldest-first issue order");

      // Dispatch 3 entries, all with both sources immediate → ready at dispatch.
      // Entry dispatched first will be oldest (highest age counter).
      src[0] = 'h0;  src[1] = 'h0;
      do_dispatch('h0A, src, 2'b11, slot);  // first = will be oldest
      do_dispatch('h0B, src, 2'b11, slot);  // second
      do_dispatch('h0C, src, 2'b11, slot);  // third = youngest

      // All 3 are ready. With 2 ports, the two oldest should issue.
      // The first-dispatched entry has had the most ticks → highest age.
      `CHK(issue_valid[0] === 1'b1, "multi: port 0 issues (oldest)");
      `CHK(issue_valid[1] === 1'b1, "multi: port 1 issues (2nd oldest)");
      `CHK(issue_dst_tag[0] === 'h0A, "multi: port 0 = entry A (oldest)");
      `CHK(issue_dst_tag[1] === 'h0B, "multi: port 1 = entry B (2nd oldest)");

      // Let those issue, then the third should issue next cycle.
      tick();
      `CHK(issue_valid[0] === 1'b1, "multi: port 0 issues C (last remaining)");
      `CHK(issue_dst_tag[0] === 'h0C, "multi: port 0 = entry C");

      tick();
  endtask

  // =========================================================================
  // Test 3: backpressure — fill queue, confirm stall, issue to free
  // =========================================================================
  task automatic test_backpressure;
      logic [IDX_W-1:0] slot;
      logic [NUM_SRC-1:0][TAG_WIDTH-1:0] src;
      $display("\n[TEST] test_backpressure: fill 4 slots, stall, issue to free");

      // Fill all 4 slots with non-ready entries (src0=0x3F, not woken).
      src[0] = 'h3F;  src[1] = 'h0;
      do_dispatch('h01, src, 2'b10, slot);
      do_dispatch('h02, src, 2'b10, slot);
      do_dispatch('h03, src, 2'b10, slot);
      do_dispatch('h04, src, 2'b10, slot);

      // Queue should be full now.
      `CHK(dispatch_ready === 1'b0, "bp: dispatch_ready=0 when full");

      // No entries are ready → no issue.
      `CHK(issue_valid === '0, "bp: no issue when nothing ready");

      // Wake all entries' src0 (tag 0x3F).
      do_wakeup('h3F);

      // Oldest two should issue (2 ports).
      `CHK(issue_valid[0] === 1'b1, "bp: port 0 issues after wakeup");
      `CHK(issue_valid[1] === 1'b1, "bp: port 1 issues after wakeup");

      // After issue clears, 2 slots free → dispatch_ready back to 1.
      tick();
      `CHK(dispatch_ready === 1'b1, "bp: dispatch_ready=1 after 2 issued");

      // Issue remaining 2.
      // They should be ready already (wakeup was sticky).
      `CHK(issue_valid[0] === 1'b1, "bp: port 0 issues remaining");
      `CHK(issue_valid[1] === 1'b1, "bp: port 1 issues remaining");
      tick();
  endtask

  // =========================================================================
  // Test 4: bypass_dispatch — same-cycle dispatch + wakeup
  // =========================================================================
  task automatic test_bypass_dispatch;
      logic [IDX_W-1:0] slot;
      logic [NUM_SRC-1:0][TAG_WIDTH-1:0] src;
      $display("\n[TEST] test_bypass_dispatch: same-cycle dispatch + wakeup");

      // Drive dispatch AND wakeup simultaneously.
      src[0] = 'h07;  src[1] = 'h0;
      @(posedge clk);
      dispatch_valid   = 1'b1;
      dispatch_dst_tag = 'h08;
      dispatch_src_tag = src;
      dispatch_src_imm = 2'b10;     // src1 immediate
      wakeup_valid     = 1'b1;
      wakeup_tag       = 'h07;       // matches src0
      @(posedge clk);
      #1;
      dispatch_valid = 1'b0;
      wakeup_valid   = 1'b0;

      // Entry should be fully ready (src0 from bypass, src1 from imm)
      // and issued this cycle.
      `CHK(issue_valid[0] === 1'b1, "bypass: entry issues (same-cycle wakeup caught)");
      `CHK(issue_dst_tag[0] === 'h08, "bypass: correct dst_tag");

      tick();
  endtask

  // =========================================================================
  // Test 5: immediate_src — both sources immediate, ready at dispatch
  // =========================================================================
  task automatic test_immediate_src;
      logic [IDX_W-1:0] slot;
      logic [NUM_SRC-1:0][TAG_WIDTH-1:0] src;
      $display("\n[TEST] test_immediate_src: both sources immediate");

      src[0] = 'h0;  src[1] = 'h0;
      do_dispatch('h0D, src, 2'b11, slot);  // both immediate

      // Should be ready and issue immediately.
      `CHK(issue_valid[0] === 1'b1, "imm: issues immediately");
      `CHK(issue_dst_tag[0] === 'h0D, "imm: correct dst_tag");

      tick();
  endtask

  // =========================================================================
  // Test 6: multi_port_issue — 2 ready entries, both ports fire
  // =========================================================================
  task automatic test_multi_port_issue;
      logic [IDX_W-1:0] slot;
      logic [NUM_SRC-1:0][TAG_WIDTH-1:0] src;
      $display("\n[TEST] test_multi_port_issue: 2 entries, 2 ports, simultaneous issue");

      src[0] = 'h0;  src[1] = 'h0;
      do_dispatch('h0E, src, 2'b11, slot);
      do_dispatch('h0F, src, 2'b11, slot);

      `CHK(issue_valid[0] === 1'b1, "multi_port: port 0 issues");
      `CHK(issue_valid[1] === 1'b1, "multi_port: port 1 issues");
      `CHK(issue_idx[0] !== issue_idx[1], "multi_port: different entries");

      tick();
  endtask

  // =========================================================================
  // Test 7: age_ordering — entries dispatched at different times
  // =========================================================================
  task automatic test_age_ordering;
      logic [IDX_W-1:0] slot;
      logic [NUM_SRC-1:0][TAG_WIDTH-1:0] src;
      $display("\n[TEST] test_age_ordering: older entry issues first");

      // Dispatch entry A (will be older — dispatched first, accumulates age).
      src[0] = 'h15;  src[1] = 'h0;
      do_dispatch('h1A, src, 2'b10, slot);

      // Wait 3 cycles (A ages).
      tick(); tick(); tick();

      // Dispatch entry B (younger).
      src[0] = 'h15;  src[1] = 'h0;
      do_dispatch('h1B, src, 2'b10, slot);

      // Wake both (they share src0 tag 0x15).
      do_wakeup('h15);

      // A should win port 0 (older); B gets port 1.
      `CHK(issue_valid[0] === 1'b1, "age: port 0 issues");
      `CHK(issue_dst_tag[0] === 'h1A, "age: port 0 = A (older)");
      `CHK(issue_valid[1] === 1'b1, "age: port 1 issues");
      `CHK(issue_dst_tag[1] === 'h1B, "age: port 1 = B (younger)");

      tick();
  endtask

  // =========================================================================
  // Test 8: slot_reuse — issue frees slot, new dispatch uses it
  // =========================================================================
  task automatic test_slot_reuse;
      logic [IDX_W-1:0] slot_a, slot_b;
      logic [NUM_SRC-1:0][TAG_WIDTH-1:0] src;
      $display("\n[TEST] test_slot_reuse: freed slot is reused by next dispatch");

      // Dispatch A (immediate, will issue immediately).
      src[0] = 'h0;  src[1] = 'h0;
      do_dispatch('h20, src, 2'b11, slot_a);
      $display("    slot_a = %0d", slot_a);

      `CHK(issue_valid[0] === 1'b1, "reuse: A issues");

      // Let A's issue clear take effect → slot_a is freed.
      tick();

      // Dispatch B — should get the same slot (priority encoder picks lowest).
      do_dispatch('h21, src, 2'b11, slot_b);
      $display("    slot_b = %0d", slot_b);

      `CHK(slot_a === slot_b, "reuse: B got same slot as A (lowest free)");
      `CHK(issue_valid[0] === 1'b1, "reuse: B issues");
      `CHK(issue_dst_tag[0] === 'h21, "reuse: B's tag on issue bus (not A's stale tag)");

      tick();
  endtask

  // =========================================================================
  // Main stimulus
  // =========================================================================
  initial begin
      // Idle all inputs.
      dispatch_valid   = 1'b0;
      dispatch_dst_tag = '0;
      dispatch_src_tag = '0;
      dispatch_src_imm = '0;
      wakeup_valid     = 1'b0;
      wakeup_tag       = '0;
      squash_en        = 1'b0;

      do_reset();

      test_single_chain();
      do_reset();

      test_multi_ready();
      do_reset();

      test_backpressure();
      do_reset();

      test_bypass_dispatch();
      do_reset();

      test_immediate_src();
      do_reset();

      test_multi_port_issue();
      do_reset();

      test_age_ordering();
      do_reset();

      test_slot_reuse();

      $display("\n============================================================");
      if (errors == 0)
          $display("RESULT: ALL TESTS PASSED (0 errors)");
      else
          $display("RESULT: %0d CHECK(S) FAILED", errors);
      $display("============================================================\n");
      $finish;
  end

  // Watchdog.
  initial begin
      #500000;
      $display("[FAIL] %0t: TIMEOUT", $time);
      errors = errors + 1;
      $finish;
  end

endmodule : tb_iq_top_directed
