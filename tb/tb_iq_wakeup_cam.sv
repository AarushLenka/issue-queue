// =============================================================================
// tb_iq_wakeup_cam.sv — Directed Testbench for iq_wakeup_cam (Step 2)
// =============================================================================
// Purpose:
//   Verify the wakeup CAM's broadcast property: a single wakeup_tag broadcast
//   must reach ALL entries whose src_tag matches, simultaneously, regardless
//   of which slot they occupy.
//
//   Tests:
//     test_broadcast       : Dispatch 3 entries sharing a common src_tag for
//                            src0. One wakeup broadcast → all 3 src_ready[0]
//                            set in the same cycle. This is the core "CAM"
//                            behavior: content-match, not address-match.
//
//     test_selective_wake  : Dispatch 2 entries with DIFFERENT src_tags.
//                            Broadcast one tag → only the matching entry wakes.
//                            Confirms comparators are per-entry, not leaking
//                            across slots.
//
//     test_issue_clear     : Dispatch, wake, issue one entry via port 0.
//                            Confirms the issue_grant/issue_idx path clears
//                            exactly the targeted entry and leaves others intact.
//
//     test_multi_port_issue: Dispatch 2 entries, wake both, issue both via
//                            different ports in the same cycle. Confirms
//                            multi-port issue clears both simultaneously.
//
// TIMING CONVENTION: same as tb_iq_entry.sv (drive after posedge, sample
//   after next posedge + #1).
// =============================================================================

`timescale 1ns/1ps

`include "iq_pkg.sv"

import iq_pkg::*;

module tb_iq_wakeup_cam;

  // -------------------------------------------------------------------------
  // Local constants — small queue for fast, readable tests
  // -------------------------------------------------------------------------
  localparam int unsigned TB_DEPTH     = 4;   // 4 entries is enough to test
  localparam int unsigned TB_TAG_WIDTH = TAG_WIDTH;
  localparam int unsigned TB_NUM_SRC   = NUM_SRC;
  localparam int unsigned TB_NUM_PORTS = NUM_PORTS;
  localparam int unsigned IDX_W        = $clog2(TB_DEPTH);

  // -------------------------------------------------------------------------
  // Error counter + CHK macro (same pattern as tb_iq_entry)
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
  logic [IDX_W-1:0]                           dispatch_slot_idx;
  logic [TB_TAG_WIDTH-1:0]                    dispatch_dst_tag;
  logic [TB_NUM_SRC-1:0][TB_TAG_WIDTH-1:0]    dispatch_src_tag;
  logic [TB_NUM_SRC-1:0]                      dispatch_src_imm;

  logic                                       wakeup_valid;
  logic [TB_TAG_WIDTH-1:0]                    wakeup_tag;

  logic [TB_NUM_PORTS-1:0]                    issue_grant;
  logic [TB_NUM_PORTS-1:0][IDX_W-1:0]         issue_idx;

  logic                                       squash_en;

  iq_entry_t                                  entry_array_o [TB_DEPTH];
  logic [TB_DEPTH-1:0]                        ready_array_o;

  // -------------------------------------------------------------------------
  // Clock
  // -------------------------------------------------------------------------
  initial clk = 1'b0;
  always #5 clk = ~clk;

  // -------------------------------------------------------------------------
  // DUT instantiation
  // -------------------------------------------------------------------------
  iq_wakeup_cam #(
      .DEPTH     (TB_DEPTH),
      .TAG_WIDTH (TB_TAG_WIDTH),
      .NUM_SRC   (TB_NUM_SRC),
      .AGE_WIDTH (AGE_WIDTH),
      .NUM_PORTS (TB_NUM_PORTS)
  ) dut (
      .clk               (clk),
      .rst_n             (rst_n),
      .dispatch_valid    (dispatch_valid),
      .dispatch_slot_idx (dispatch_slot_idx),
      .dispatch_dst_tag  (dispatch_dst_tag),
      .dispatch_src_tag  (dispatch_src_tag),
      .dispatch_src_imm  (dispatch_src_imm),
      .dispatch_disp_seq (16'd0),
      .wakeup_valid      (wakeup_valid),
      .wakeup_tag        (wakeup_tag),
      .issue_grant       (issue_grant),
      .issue_idx         (issue_idx),
      .squash_en         (squash_en),
      .squash_seq        (16'd0),
      .entry_array_o     (entry_array_o),
      .ready_array_o     (ready_array_o)
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

  // Dispatch one instruction into a specific slot. Pulses dispatch_valid
  // for exactly one cycle with the given payload.
  task automatic dispatch_to_slot(
      input logic [IDX_W-1:0]                        slot,
      input logic [TB_TAG_WIDTH-1:0]                 dst,
      input logic [TB_NUM_SRC-1:0][TB_TAG_WIDTH-1:0] src,
      input logic [TB_NUM_SRC-1:0]                   imm
  );
      @(posedge clk);
      dispatch_valid    = 1'b1;
      dispatch_slot_idx = slot;
      dispatch_dst_tag  = dst;
      dispatch_src_tag  = src;
      dispatch_src_imm  = imm;
      @(posedge clk);   // capturing edge
      #1;
      dispatch_valid    = 1'b0;
  endtask

  // Broadcast one wakeup tag for exactly one cycle.
  task automatic do_wakeup(input logic [TB_TAG_WIDTH-1:0] tag);
      @(posedge clk);
      wakeup_valid = 1'b1;
      wakeup_tag   = tag;
      @(posedge clk);   // capturing edge
      #1;
      wakeup_valid = 1'b0;
  endtask

  // Issue one entry via a specific port for one cycle.
  task automatic do_issue(input int port, input logic [IDX_W-1:0] idx);
      @(posedge clk);
      issue_grant       = '0;
      issue_grant[port] = 1'b1;
      issue_idx[port]   = idx;
      @(posedge clk);   // capturing edge
      #1;
      issue_grant = '0;
  endtask

  // =========================================================================
  // test_broadcast — THE key Step 2 verification
  // =========================================================================
  // Dispatch entries 0, 1, 2 all depending on producer tag 'hA for src0.
  // One wakeup broadcast of tag 'hA → all three src_ready[0] set together.
  // This proves the wakeup bus truly broadcasts (fan-out to all entries)
  // rather than point-to-point (only hitting one).
  task automatic test_broadcast;
      logic [TB_NUM_SRC-1:0][TB_TAG_WIDTH-1:0] src;
      $display("\n[TEST] test_broadcast: 3 entries share src0 tag, one broadcast wakes all");

      // Entry 0: src0=0xA, src1=0xB
      src[0] = 'hA;  src[1] = 'hB;
      dispatch_to_slot(2'h0, 'h10, src, '0);

      // Entry 1: src0=0xA, src1=0xC (different src1, same src0)
      src[0] = 'hA;  src[1] = 'hC;
      dispatch_to_slot(2'h1, 'h11, src, '0);

      // Entry 2: src0=0xA, src1=0xD
      src[0] = 'hA;  src[1] = 'hD;
      dispatch_to_slot(2'h2, 'h12, src, '0);

      // Confirm all 3 are valid, none ready yet.
      `CHK(entry_array_o[0].valid === 1'b1, "broadcast: entry 0 valid");
      `CHK(entry_array_o[1].valid === 1'b1, "broadcast: entry 1 valid");
      `CHK(entry_array_o[2].valid === 1'b1, "broadcast: entry 2 valid");
      `CHK(ready_array_o[2:0] === 3'b000,   "broadcast: none ready before wakeup");

      // Broadcast tag 0xA — should hit src0 of entries 0, 1, 2 simultaneously.
      do_wakeup('hA);

      // WHY: this is the broadcast property — ONE bus transaction, MULTIPLE
      // entries waking up. If only one woke, the distributed CAM is broken
      // (the fan-out isn't reaching all comparators).
      `CHK(entry_array_o[0].src_ready[0] === 1'b1, "broadcast: entry 0 src0 ready");
      `CHK(entry_array_o[1].src_ready[0] === 1'b1, "broadcast: entry 1 src0 ready");
      `CHK(entry_array_o[2].src_ready[0] === 1'b1, "broadcast: entry 2 src0 ready");

      // src1 should still be unready for all — tag 0xA doesn't match 0xB/0xC/0xD.
      `CHK(entry_array_o[0].src_ready[1] === 1'b0, "broadcast: entry 0 src1 still unready");
      `CHK(entry_array_o[1].src_ready[1] === 1'b0, "broadcast: entry 1 src1 still unready");
      `CHK(entry_array_o[2].src_ready[1] === 1'b0, "broadcast: entry 2 src1 still unready");

      // None are fully ready (src1 missing for all).
      `CHK(ready_array_o[2:0] === 3'b000,           "broadcast: none fully ready (src1 missing)");

      // Now wake each entry's src1 individually to clean up.
      do_wakeup('hB);
      `CHK(ready_array_o[0] === 1'b1, "broadcast: entry 0 fully ready after src1 wake");

      do_wakeup('hC);
      `CHK(ready_array_o[1] === 1'b1, "broadcast: entry 1 fully ready after src1 wake");

      do_wakeup('hD);
      `CHK(ready_array_o[2] === 1'b1, "broadcast: entry 2 fully ready after src1 wake");

      // Issue all to clean up for next test.
      do_issue(0, 2'h0);
      do_issue(0, 2'h1);
      do_issue(0, 2'h2);
  endtask

  // =========================================================================
  // test_selective_wake — confirms per-entry isolation
  // =========================================================================
  // Entry 0: src0=0x1. Entry 1: src0=0x2. Broadcast tag 0x1 — only entry 0
  // should wake. Entry 1 must remain asleep. Proves comparators are local
  // (not accidentally sharing hit signals between entries).
  task automatic test_selective_wake;
      logic [TB_NUM_SRC-1:0][TB_TAG_WIDTH-1:0] src;
      $display("\n[TEST] test_selective_wake: different tags, only matching entry wakes");

      // Entry 0: depends on tag 0x1
      src[0] = 'h1;  src[1] = 'hF;
      dispatch_to_slot(2'h0, 'h20, src, '0);

      // Entry 1: depends on tag 0x2
      src[0] = 'h2;  src[1] = 'hF;
      dispatch_to_slot(2'h1, 'h21, src, '0);

      // Broadcast tag 0x1 — should ONLY hit entry 0.
      do_wakeup('h1);

      `CHK(entry_array_o[0].src_ready[0] === 1'b1, "selective: entry 0 src0 woke (tag 0x1 match)");
      `CHK(entry_array_o[1].src_ready[0] === 1'b0, "selective: entry 1 src0 still asleep (tag 0x2 != 0x1)");

      // Broadcast tag 0x2 — now entry 1 wakes.
      do_wakeup('h2);
      `CHK(entry_array_o[1].src_ready[0] === 1'b1, "selective: entry 1 src0 woke (tag 0x2 match)");

      // Clean up.
      do_issue(0, 2'h0);
      do_issue(0, 2'h1);
  endtask

  // =========================================================================
  // test_issue_clear — verifies issue_grant/issue_idx targeting
  // =========================================================================
  // Dispatch entry 0, wake it fully, issue it via port 0. Entry must go
  // invalid. Entry 1 (dispatched but not issued) must remain valid.
  task automatic test_issue_clear;
      logic [TB_NUM_SRC-1:0][TB_TAG_WIDTH-1:0] src;
      $display("\n[TEST] test_issue_clear: issue one entry, other stays valid");

      // Entry 0: both sources immediate → ready at dispatch.
      src[0] = 'h0;  src[1] = 'h0;
      dispatch_to_slot(2'h0, 'h30, src, 2'b11);

      // Entry 1: both sources immediate too.
      src[0] = 'h0;  src[1] = 'h0;
      dispatch_to_slot(2'h1, 'h31, src, 2'b11);

      `CHK(ready_array_o[0] === 1'b1, "issue_clear: entry 0 ready (both imm)");
      `CHK(ready_array_o[1] === 1'b1, "issue_clear: entry 1 ready (both imm)");

      // Issue entry 0 only.
      do_issue(0, 2'h0);

      `CHK(entry_array_o[0].valid === 1'b0, "issue_clear: entry 0 cleared after issue");
      `CHK(entry_array_o[1].valid === 1'b1, "issue_clear: entry 1 still valid (untouched)");

      // Clean up.
      do_issue(0, 2'h1);
  endtask

  // =========================================================================
  // test_multi_port_issue — two entries issued by two ports same cycle
  // =========================================================================
  // Confirms the issue_clear_oh OR-reduction works for multi-port: both
  // entries clear in one cycle.
  task automatic test_multi_port_issue;
      logic [TB_NUM_SRC-1:0][TB_TAG_WIDTH-1:0] src;
      $display("\n[TEST] test_multi_port_issue: 2 entries issued by 2 ports same cycle");

      // Both entries: all-immediate → ready at dispatch.
      src[0] = 'h0;  src[1] = 'h0;
      dispatch_to_slot(2'h0, 'h40, src, 2'b11);
      dispatch_to_slot(2'h1, 'h41, src, 2'b11);

      `CHK(ready_array_o[0] === 1'b1, "multi_issue: entry 0 ready");
      `CHK(ready_array_o[1] === 1'b1, "multi_issue: entry 1 ready");

      // Issue BOTH in one cycle: port 0 → entry 0, port 1 → entry 1.
      @(posedge clk);
      issue_grant    = '0;
      issue_grant[0] = 1'b1;
      issue_grant[1] = 1'b1;
      issue_idx[0]   = 2'h0;
      issue_idx[1]   = 2'h1;
      @(posedge clk);   // capturing edge
      #1;
      issue_grant = '0;

      `CHK(entry_array_o[0].valid === 1'b0, "multi_issue: entry 0 cleared");
      `CHK(entry_array_o[1].valid === 1'b0, "multi_issue: entry 1 cleared");
  endtask

  // =========================================================================
  // Main stimulus
  // =========================================================================
  initial begin
      // Idle all inputs.
      rst_n             = 1'b1;
      dispatch_valid    = 1'b0;
      dispatch_slot_idx = '0;
      dispatch_dst_tag  = '0;
      dispatch_src_tag  = '0;
      dispatch_src_imm  = '0;
      wakeup_valid      = 1'b0;
      wakeup_tag        = '0;
      issue_grant       = '0;
      issue_idx         = '0;
      squash_en         = 1'b0;

      do_reset();
      test_broadcast();
      test_selective_wake();
      test_issue_clear();
      test_multi_port_issue();

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
      #200000;
      $display("[FAIL] %0t: TIMEOUT — simulation hung", $time);
      errors = errors + 1;
      $finish;
  end

endmodule : tb_iq_wakeup_cam
