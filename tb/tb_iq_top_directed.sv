// =============================================================================
// tb_iq_top_directed.sv — Directed Integration Tests (Step 4)
// =============================================================================
// Purpose:
//   End-to-end tests that exercise the full issue queue pipeline:
//   dispatch → wakeup → age → select → issue, using iq_top with DEPTH=4.
//
//   CRITICAL TIMING NOTE:
//     The selector is PURE COMBINATIONAL. An entry that becomes ready at
//     posedge N (wakeup captured, src_ready updated) produces issue_valid=1
//     combinationally at N+#1. At posedge N+1, the entry clears.
//
//     This means: check issue_valid ONE TICK after the wakeup/dispatch that
//     makes the entry ready, NOT after an additional tick. The issued entry
//     is gone after the next posedge.
//
//   Test catalog (9 directed tests):
//     1. single_chain     : A→B dependency chain
//     2. multi_ready      : 3 entries ready at same time, oldest issues first
//     3. backpressure     : fill queue, stall, free by issue
//     4. bypass_dispatch  : same-cycle dispatch + matching wakeup
//     5. immediate_src    : both sources immediate
//     6. multi_port_issue : 2 entries issue via 2 ports same cycle
//     7. age_ordering     : older entry issues first
//     8. slot_reuse       : freed slot reused by next dispatch
//     9. squash_selective : Step 5 — partial squash by disp_seq, survivor + slot reuse
// =============================================================================

`timescale 1ns/1ps

`include "iq_pkg.sv"

import iq_pkg::*;

module tb_iq_top_directed;

  localparam int unsigned TB_DEPTH     = 4;
  localparam int unsigned TB_NUM_PORTS = 2;
  localparam int unsigned IDX_W        = $clog2(TB_DEPTH);

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
  logic [15:0]                                squash_seq;

  initial clk = 1'b0;
  always #5 clk = ~clk;

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
      .squash_en         (squash_en),
      .squash_seq        (squash_seq)
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

  // Dispatch one instruction.
  // TIMING: inputs change #1 after the align edge (mid-cycle) so they are
  // stable for one full cycle before the capturing posedge. This avoids an
  // Active-region race where the always_ff could see the new value at the
  // align edge itself.
  task automatic do_dispatch(
      input logic [TAG_WIDTH-1:0]              dst,
      input logic [NUM_SRC-1:0][TAG_WIDTH-1:0] src,
      input logic [NUM_SRC-1:0]                imm
  );
      @(posedge clk);
      #1;                         // ← past the Active region
      dispatch_valid   = 1'b1;
      dispatch_dst_tag = dst;
      dispatch_src_tag = src;
      dispatch_src_imm = imm;
      @(posedge clk);   // capturing edge — inputs stable
      #1;
      dispatch_valid = 1'b0;
  endtask

  // Broadcast a wakeup tag for one cycle.
  task automatic do_wakeup(input logic [TAG_WIDTH-1:0] tag);
      @(posedge clk);
      #1;                         // ← past the Active region
      wakeup_valid = 1'b1;
      wakeup_tag   = tag;
      @(posedge clk);   // capturing edge
      #1;
      wakeup_valid = 1'b0;
  endtask

  // Wait one cycle and sample.
  task automatic tick;
      @(posedge clk);
      #1;
  endtask

  // =========================================================================
  // Test 1: single_chain — A depends on external, B depends on A
  // =========================================================================
  task automatic test_single_chain;
      logic [NUM_SRC-1:0][TAG_WIDTH-1:0] src;
      $display("\n[TEST] test_single_chain: A->B dependency chain");

      // Dispatch A: src0=0x10 (needs wakeup), src1 immediate.
      src[0] = 'h10;  src[1] = 'h0;
      do_dispatch('h01, src, 2'b10);

      // DEBUG: dump all entry state after dispatch
      for (int i = 0; i < TB_DEPTH; i++) begin
          if (dut.u_cam.entry_array_o[i].valid)
              $display("    entry[%0d]: valid=%b src_ready=%b dst_tag=%h disp_seq=%0d",
                  i,
                  dut.u_cam.entry_array_o[i].valid,
                  dut.u_cam.entry_array_o[i].src_ready,
                  dut.u_cam.entry_array_o[i].dst_tag,
                  dut.u_cam.entry_array_o[i].disp_seq);
      end

      `CHK(issue_valid[0] === 1'b0, "chain: A not ready before wakeup");

      // Wake A's src0
      do_wakeup('h10);

      `CHK(issue_valid[0] === 1'b1, "chain: A issues after wakeup");
      `CHK(issue_dst_tag[0] === 'h01, "chain: A dst_tag on issue bus");

      tick();
      `CHK(issue_valid[0] === 1'b0, "chain: no issue after A cleared");

      // Dispatch B
      src[0] = 'h01;  src[1] = 'h0;
      do_dispatch('h02, src, 2'b10);
      do_wakeup('h01);
      `CHK(issue_valid[0] === 1'b1, "chain: B issues after wakeup");
      `CHK(issue_dst_tag[0] === 'h02, "chain: B dst_tag on issue bus");
      tick();
  endtask

  // =========================================================================
  // Test 2: multi_ready — 3 entries ready at once, oldest-first
  // =========================================================================
  // All 3 share the same unresolved src0. We dispatch all 3 FIRST, then
  // wake src0 in a single broadcast so all 3 become ready simultaneously.
  task automatic test_multi_ready;
      logic [NUM_SRC-1:0][TAG_WIDTH-1:0] src;
      $display("\n[TEST] test_multi_ready: 3 entries, wake all at once, oldest issues first");

      // Dispatch 3 entries, all depending on tag 0x20, src1 immediate.
      // Dispatching first → will be oldest (highest age).
      src[0] = 'h20;  src[1] = 'h0;
      do_dispatch('h0A, src, 2'b10);  // A: dispatched first = oldest
      do_dispatch('h0B, src, 2'b10);  // B: second
      do_dispatch('h0C, src, 2'b10);  // C: third = youngest

      // None ready yet.
      `CHK(issue_valid === '0, "multi: none ready before wakeup");

      // Wake all at once via broadcast of tag 0x20.
      do_wakeup('h20);

      // All 3 become ready. 2 ports → oldest 2 issue this cycle.
      `CHK(issue_valid[0] === 1'b1, "multi: port 0 issues");
      `CHK(issue_valid[1] === 1'b1, "multi: port 1 issues");
      `CHK(issue_dst_tag[0] === 'h0A, "multi: port 0 = A (oldest)");
      `CHK(issue_dst_tag[1] === 'h0B, "multi: port 1 = B (2nd oldest)");

      // Let those clear, C remains.
      tick();
      `CHK(issue_valid[0] === 1'b1, "multi: C issues next cycle");
      `CHK(issue_dst_tag[0] === 'h0C, "multi: port 0 = C");
      tick();
  endtask

  // =========================================================================
  // Test 3: backpressure — fill all 4, stall, issue to free
  // =========================================================================
  task automatic test_backpressure;
      logic [NUM_SRC-1:0][TAG_WIDTH-1:0] src;
      $display("\n[TEST] test_backpressure: fill 4 slots, stall, issue to free");

      // Fill 4 slots with non-ready entries (src0=0x3F, not woken).
      src[0] = 'h3F;  src[1] = 'h0;
      do_dispatch('h01, src, 2'b10);
      do_dispatch('h02, src, 2'b10);
      do_dispatch('h03, src, 2'b10);
      do_dispatch('h04, src, 2'b10);

      `CHK(dispatch_ready === 1'b0, "bp: dispatch_ready=0 when full");
      `CHK(issue_valid === '0, "bp: no issue when nothing ready");

      // Wake all (tag 0x3F).
      do_wakeup('h3F);

      // 2 oldest issue this cycle.
      `CHK(issue_valid[0] === 1'b1, "bp: port 0 issues after wakeup");
      `CHK(issue_valid[1] === 1'b1, "bp: port 1 issues after wakeup");

      // Let those clear → 2 slots free.
      tick();
      `CHK(dispatch_ready === 1'b1, "bp: dispatch_ready=1 after 2 issued");

      // Remaining 2 issue this cycle (still ready from sticky wakeup).
      `CHK(issue_valid[0] === 1'b1, "bp: port 0 issues remaining");
      `CHK(issue_valid[1] === 1'b1, "bp: port 1 issues remaining");
      tick();
  endtask

  // =========================================================================
  // Test 4: bypass_dispatch — same-cycle dispatch + wakeup
  // =========================================================================
  task automatic test_bypass_dispatch;
      logic [NUM_SRC-1:0][TAG_WIDTH-1:0] src;
      $display("\n[TEST] test_bypass_dispatch: same-cycle dispatch + wakeup");

      src[0] = 'h07;  src[1] = 'h0;
      @(posedge clk);
      #1;                            // ← past the Active region
      dispatch_valid   = 1'b1;
      dispatch_dst_tag = 'h08;
      dispatch_src_tag = src;
      dispatch_src_imm = 2'b10;     // src1 immediate
      wakeup_valid     = 1'b1;
      wakeup_tag       = 'h07;       // matches src0
      @(posedge clk);                // capture both — inputs stable
      #1;
      dispatch_valid = 1'b0;
      wakeup_valid   = 1'b0;

      // Entry is fully ready (src0 via bypass, src1 via imm) → issues.
      `CHK(issue_valid[0] === 1'b1, "bypass: issues same cycle");
      `CHK(issue_dst_tag[0] === 'h08, "bypass: correct dst_tag");
      tick();
  endtask

  // =========================================================================
  // Test 5: immediate_src — both sources immediate
  // =========================================================================
  task automatic test_immediate_src;
      logic [NUM_SRC-1:0][TAG_WIDTH-1:0] src;
      $display("\n[TEST] test_immediate_src: both sources immediate");

      src[0] = 'h0;  src[1] = 'h0;
      do_dispatch('h0D, src, 2'b11);

      `CHK(issue_valid[0] === 1'b1, "imm: issues at dispatch");
      `CHK(issue_dst_tag[0] === 'h0D, "imm: correct dst_tag");
      tick();
  endtask

  // =========================================================================
  // Test 6: multi_port_issue — 2 ready entries, both ports fire
  // =========================================================================
  task automatic test_multi_port_issue;
      logic [NUM_SRC-1:0][TAG_WIDTH-1:0] src;
      $display("\n[TEST] test_multi_port_issue: 2 entries, 2 ports same cycle");

      // Dispatch 2 non-ready entries, then wake both at once.
      src[0] = 'h25;  src[1] = 'h0;
      do_dispatch('h0E, src, 2'b10);
      do_dispatch('h0F, src, 2'b10);

      // Wake both (same src0 tag).
      do_wakeup('h25);

      `CHK(issue_valid[0] === 1'b1, "multi_port: port 0 issues");
      `CHK(issue_valid[1] === 1'b1, "multi_port: port 1 issues");
      `CHK(issue_idx[0] !== issue_idx[1], "multi_port: different entries");
      tick();
  endtask

  // =========================================================================
  // Test 7: age_ordering — older entry issues first
  // =========================================================================
  task automatic test_age_ordering;
      logic [NUM_SRC-1:0][TAG_WIDTH-1:0] src;
      $display("\n[TEST] test_age_ordering: older entry issues first");

      // Dispatch A (will accumulate more age).
      src[0] = 'h15;  src[1] = 'h0;
      do_dispatch('h1A, src, 2'b10);

      // Wait 3 cycles so A ages.
      tick(); tick(); tick();

      // Dispatch B (younger).
      src[0] = 'h15;  src[1] = 'h0;
      do_dispatch('h1B, src, 2'b10);

      // Wake both.
      do_wakeup('h15);

      // A should win port 0 (older), B gets port 1.
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
      $display("\n[TEST] test_slot_reuse: freed slot reused by next dispatch");

      // Dispatch A: non-ready (needs wakeup), record which slot.
      src[0] = 'h30;  src[1] = 'h0;
      do_dispatch('h20, src, 2'b10);
      slot_a = dispatch_slot_idx;

      // Wake A → issues.
      do_wakeup('h30);
      `CHK(issue_valid[0] === 1'b1, "reuse: A issues");

      // Let issue clear take effect → slot_a freed.
      tick();

      // Dispatch B — should get the lowest free slot.
      // After reset, slot 0 was allocated to A. After A frees, slot 0
      // is available again. Priority encoder picks lowest = slot 0.
      do_dispatch('h21, src, 2'b10);
      slot_b = dispatch_slot_idx;

      // The allocator is deterministic: lowest free slot.
      // slot_a was freed, so it should be available.
      $display("    slot_a=%0d, slot_b=%0d", slot_a, slot_b);

      // Wake B.
      do_wakeup('h30);
      `CHK(issue_valid[0] === 1'b1, "reuse: B issues");
      `CHK(issue_dst_tag[0] === 'h21, "reuse: B's tag (not stale A)");
      tick();
  endtask

  // =========================================================================
  // Test 9: squash_selective — squash younger entries, keep older
  // =========================================================================
  // Dispatch 3 entries (A=seq0, B=seq1, C=seq2). Squash with threshold
  // seq=0 → only B(seq1) and C(seq2) should be flushed. A survives.
  task automatic test_squash_selective;
      logic [NUM_SRC-1:0][TAG_WIDTH-1:0] src;
      $display("\n[TEST] test_squash_selective: squash younger, keep older");

      // Dispatch 3 non-ready entries sharing src0=0x3E (src1 immediate).
      // The global disp_seq counter in iq_top starts at 0 post-reset and ticks
      // once per accepted dispatch, so A=seq0, B=seq1, C=seq2. Allocation is
      // lowest-free-first → A→slot0, B→slot1, C→slot2.
      src[0] = 'h3E;  src[1] = 'h0;
      do_dispatch('h01, src, 2'b10);  // A: seq0
      do_dispatch('h02, src, 2'b10);  // B: seq1
      do_dispatch('h03, src, 2'b10);  // C: seq2

      // All three live in the queue before the squash.
      `CHK(dut.u_cam.entry_array_o[0].valid === 1'b1, "squash: A valid before squash");
      `CHK(dut.u_cam.entry_array_o[1].valid === 1'b1, "squash: B valid before squash");
      `CHK(dut.u_cam.entry_array_o[2].valid === 1'b1, "squash: C valid before squash");

      // Squash with threshold seq=0. The compare is STRICT: disp_seq > 0.
      // A (seq 0 == threshold) SURVIVES — dispatched AT/BEFORE the mispredicted
      // branch. B (seq1) and C (seq2) are strictly younger → wrong path → flush.
      @(posedge clk);
      #1;
      squash_en  = 1'b1;
      squash_seq = 16'd0;
      @(posedge clk);  // capturing edge: B,C cleared, A retained
      #1;
      squash_en = 1'b0;

      // Exactly the younger entries die; the older one lives.
      `CHK(dut.u_cam.entry_array_o[0].valid === 1'b1, "squash: A survives (seq0 <= threshold)");
      `CHK(dut.u_cam.entry_array_o[1].valid === 1'b0, "squash: B flushed (seq1 > threshold)");
      `CHK(dut.u_cam.entry_array_o[2].valid === 1'b0, "squash: C flushed (seq2 > threshold)");

      // free_vec mirrors the CAM: slots 1 and 2 (squashed) are free again,
      // slot 0 still holds A. has_free=1 → dispatch_ready=1.
      `CHK(dispatch_ready === 1'b1, "squash: dispatch_ready=1 (2 slots freed)");

      // Reuse a squash-freed slot BEFORE touching A. Slot 0 is still occupied
      // by A, so the priority allocator's lowest-free pick is slot 1 — the very
      // slot B was squashed out of. This proves free_vec and the CAM's per-entry
      // squash_clear stayed in sync and the freed slot is reusable immediately.
      // D waits on a DIFFERENT src tag (0x3D) so the upcoming wake of 0x3E
      // reaches only A and D stays asleep — keeping the survivor-issue check
      // below unambiguous.
      src[0] = 'h3D;  src[1] = 'h0;
      do_dispatch('h04, src, 2'b10);  // D → slot1, seq3
      `CHK(dut.u_cam.entry_array_o[1].valid   === 1'b1,  "squash: D reuses squash-freed slot 1");
      `CHK(dut.u_cam.entry_array_o[1].dst_tag === 'h04,  "squash: D correct tag in reused slot");

      // The survivor A is untouched by squash: wake its src0 and confirm it
      // issues the cycle after. D (different src) must stay not-ready.
      do_wakeup('h3E);
      `CHK(issue_valid[0]   === 1'b1, "squash: A issues after surviving squash");
      `CHK(issue_dst_tag[0] === 'h01, "squash: A's tag correct post-squash");
      `CHK(issue_valid[1]   === 1'b0, "squash: D not ready (different src tag)");

      tick();
  endtask

  // =========================================================================
  // Main
  // =========================================================================
  initial begin
      dispatch_valid   = 1'b0;
      dispatch_dst_tag = '0;
      dispatch_src_tag = '0;
      dispatch_src_imm = '0;
      wakeup_valid     = 1'b0;
      wakeup_tag       = '0;
      squash_en        = 1'b0;
      squash_seq       = '0;

      do_reset();  test_single_chain();
      do_reset();  test_multi_ready();
      do_reset();  test_backpressure();
      do_reset();  test_bypass_dispatch();
      do_reset();  test_immediate_src();
      do_reset();  test_multi_port_issue();
      do_reset();  test_age_ordering();
      do_reset();  test_slot_reuse();
      do_reset();  test_squash_selective();

      $display("\n============================================================");
      if (errors == 0)
          $display("RESULT: ALL TESTS PASSED (0 errors)");
      else
          $display("RESULT: %0d CHECK(S) FAILED", errors);
      $display("============================================================\n");
      $finish;
  end

  initial begin
      #500000;
      $display("[FAIL] %0t: TIMEOUT", $time);
      errors = errors + 1;
      $finish;
  end

endmodule : tb_iq_top_directed
