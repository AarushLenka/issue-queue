// =============================================================================
// tb_iq_select.sv — Directed Testbench for iq_select (Step 3)
// =============================================================================
// Purpose:
//   Verify the three key properties of the multi-port oldest-ready selector:
//
//     test_oldest_wins       : Among multiple ready entries with DIFFERENT ages,
//                              port 0 selects the strictly oldest.
//     test_no_double_grant   : With 2 ports and ≥2 ready entries, no two ports
//                              ever select the same entry index.
//     test_no_grant_empty    : When fewer ready entries exist than ports, excess
//                              ports correctly report grant=0.
//     test_tie_break         : When two entries have equal age, the one with the
//                              lower index wins (deterministic tie-break).
//     test_mask_chain        : Port 1 gets second-oldest after port 0 takes oldest.
//
// NOTE: iq_select is PURE COMBINATIONAL — no clock, no reset. We still use a
//   clock for structured test sequencing (drive inputs, #1 settle, check
//   outputs), but the DUT itself has no posedge sensitivity.
// =============================================================================

`timescale 1ns/1ps

`include "iq_pkg.sv"

import iq_pkg::*;

module tb_iq_select;

  // -------------------------------------------------------------------------
  // TB parameters — small queue for clear, readable tests
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
  iq_entry_t                                     entry_i [TB_DEPTH];
  logic [TB_DEPTH-1:0]                           ready_i;

  logic [TB_NUM_PORTS-1:0]                       grant_o;
  logic [TB_NUM_PORTS-1:0][IDX_W-1:0]            grant_idx_o;
  logic [TB_NUM_PORTS-1:0][TAG_WIDTH-1:0]        grant_tag_o;
  logic [TB_NUM_PORTS-1:0][AGE_WIDTH-1:0]        grant_age_o;

  // -------------------------------------------------------------------------
  // Clock (for structured test timing only — DUT is combinational)
  // -------------------------------------------------------------------------
  logic clk;
  initial clk = 1'b0;
  always #5 clk = ~clk;

  // -------------------------------------------------------------------------
  // DUT
  // -------------------------------------------------------------------------
  iq_select #(
      .DEPTH     (TB_DEPTH),
      .AGE_WIDTH (AGE_WIDTH),
      .NUM_PORTS (TB_NUM_PORTS),
      .TAG_WIDTH (TAG_WIDTH)
  ) dut (
      .entry_i     (entry_i),
      .ready_i     (ready_i),
      .grant_o     (grant_o),
      .grant_idx_o (grant_idx_o),
      .grant_tag_o (grant_tag_o),
      .grant_age_o (grant_age_o)
  );

  // =========================================================================
  // Helper: build a fake entry with specific fields
  // =========================================================================
  // Since the selector reads entry_i[] directly (no clock), we construct
  // entries procedurally as packed structs. This lets us control age, valid,
  // src_ready, and dst_tag for each test scenario without needing a full
  // dispatch/wakeup cycle.
  function automatic iq_entry_t make_entry(
      input logic                valid,
      input logic [AGE_WIDTH-1:0] age,
      input logic [TAG_WIDTH-1:0] dst_tag,
      input logic [NUM_SRC-1:0]   src_ready
  );
      iq_entry_t e;
      e = '0;
      e.valid     = valid;
      e.age       = age;
      e.dst_tag   = dst_tag;
      e.src_ready = src_ready;
      return e;
  endfunction

  // Helper: set all entries to invalid.
  task automatic clear_all;
      for (int i = 0; i < TB_DEPTH; i++) begin
          entry_i[i] = '0;
      end
      ready_i = '0;
  endtask

  // =========================================================================
  // test_oldest_wins — port 0 picks the entry with the highest age
  // =========================================================================
  task automatic test_oldest_wins;
      $display("\n[TEST] test_oldest_wins: port 0 picks strictly oldest ready entry");
      clear_all();

      // Entry 0: age=2, ready
      entry_i[0] = make_entry(1'b1, 4'd2, 'h10, '1);
      // Entry 1: age=5, ready  ← oldest
      entry_i[1] = make_entry(1'b1, 4'd5, 'h11, '1);
      // Entry 2: age=3, ready
      entry_i[2] = make_entry(1'b1, 4'd3, 'h12, '1);
      // Entry 3: age=1, ready
      entry_i[3] = make_entry(1'b1, 4'd1, 'h13, '1);

      ready_i = 4'b1111;

      #1;  // combinational settle

      // Port 0 must select entry 1 (age=5, the oldest).
      `CHK(grant_o[0] === 1'b1,               "oldest: port 0 grants");
      `CHK(grant_idx_o[0] === IDX_W'(1),       "oldest: port 0 picks entry 1 (age=5)");
      `CHK(grant_age_o[0] === 4'd5,            "oldest: port 0 reports age=5");
      `CHK(grant_tag_o[0] === 'h11,            "oldest: port 0 forwards dst_tag 0x11");
  endtask

  // =========================================================================
  // test_no_double_grant — two ports, no entry overlap
  // =========================================================================
  task automatic test_no_double_grant;
      $display("\n[TEST] test_no_double_grant: 2 ports never select the same entry");
      clear_all();

      // Entry 0: age=4, ready  ← second oldest
      entry_i[0] = make_entry(1'b1, 4'd4, 'h20, '1);
      // Entry 1: age=7, ready  ← oldest
      entry_i[1] = make_entry(1'b1, 4'd7, 'h21, '1);
      // Entry 2: age=2, ready
      entry_i[2] = make_entry(1'b1, 4'd2, 'h22, '1);
      // Entry 3: NOT ready (src_ready=01, only src0 ready)
      entry_i[3] = make_entry(1'b1, 4'd9, 'h23, 2'b01);

      ready_i = 4'b0111;  // entries 0, 1, 2 ready; entry 3 not

      #1;

      // Port 0: entry 1 (age=7, oldest ready)
      `CHK(grant_o[0] === 1'b1,               "no_dbl: port 0 grants");
      `CHK(grant_idx_o[0] === IDX_W'(1),       "no_dbl: port 0 picks entry 1 (age=7)");

      // Port 1: entry 0 (age=4, second oldest among remaining {0, 2})
      `CHK(grant_o[1] === 1'b1,               "no_dbl: port 1 grants");
      `CHK(grant_idx_o[1] === IDX_W'(0),       "no_dbl: port 1 picks entry 0 (age=4)");

      // KEY: the two selected indices must be different.
      `CHK(grant_idx_o[0] !== grant_idx_o[1],  "no_dbl: port 0 != port 1 (mutual exclusion)");
  endtask

  // =========================================================================
  // test_no_grant_empty — more ports than ready entries
  // =========================================================================
  task automatic test_no_grant_empty;
      $display("\n[TEST] test_no_grant_empty: 1 ready entry, 2 ports → port 1 gets no grant");
      clear_all();

      // Only entry 2 is ready.
      entry_i[2] = make_entry(1'b1, 4'd3, 'h32, '1);

      ready_i = 4'b0100;

      #1;

      `CHK(grant_o[0] === 1'b1,               "empty: port 0 grants (entry 2)");
      `CHK(grant_idx_o[0] === IDX_W'(2),       "empty: port 0 picks entry 2");
      `CHK(grant_o[1] === 1'b0,               "empty: port 1 has NO grant (nothing left)");
  endtask

  // =========================================================================
  // test_all_empty — no ready entries at all
  // =========================================================================
  task automatic test_all_empty;
      $display("\n[TEST] test_all_empty: 0 ready entries → all ports get no grant");
      clear_all();

      // All entries valid but NOT ready (src_ready = 0).
      for (int i = 0; i < TB_DEPTH; i++) begin
          entry_i[i] = make_entry(1'b1, 4'd5, 'h30, '0);
      end
      ready_i = '0;

      #1;

      `CHK(grant_o[0] === 1'b0, "all_empty: port 0 no grant");
      `CHK(grant_o[1] === 1'b0, "all_empty: port 1 no grant");
  endtask

  // =========================================================================
  // test_tie_break — equal ages, lower index wins
  // =========================================================================
  task automatic test_tie_break;
      $display("\n[TEST] test_tie_break: equal age → lower index wins");
      clear_all();

      // Entries 1 and 3 both ready, both age=6.
      entry_i[1] = make_entry(1'b1, 4'd6, 'h31, '1);
      entry_i[3] = make_entry(1'b1, 4'd6, 'h33, '1);

      ready_i = 4'b1010;

      #1;

      // Lower index (1) should win port 0 on tie.
      `CHK(grant_o[0] === 1'b1,               "tie: port 0 grants");
      `CHK(grant_idx_o[0] === IDX_W'(1),       "tie: port 0 picks entry 1 (lower index)");

      // Port 1 gets entry 3 (the remaining one).
      `CHK(grant_o[1] === 1'b1,               "tie: port 1 grants");
      `CHK(grant_idx_o[1] === IDX_W'(3),       "tie: port 1 picks entry 3");
  endtask

  // =========================================================================
  // test_mask_chain — verify port 1 gets second-oldest correctly
  // =========================================================================
  task automatic test_mask_chain;
      $display("\n[TEST] test_mask_chain: port 1 gets second-oldest after port 0 takes oldest");
      clear_all();

      // Entry 0: age=10, ready  ← oldest
      entry_i[0] = make_entry(1'b1, 4'd10, 'h3A, '1);
      // Entry 1: age=8, ready   ← second oldest
      entry_i[1] = make_entry(1'b1, 4'd8,  'h3B, '1);
      // Entry 2: age=3, ready   ← third
      entry_i[2] = make_entry(1'b1, 4'd3,  'h3C, '1);

      ready_i = 4'b0111;

      #1;

      `CHK(grant_o[0] === 1'b1,               "chain: port 0 grants");
      `CHK(grant_idx_o[0] === IDX_W'(0),       "chain: port 0 picks entry 0 (age=10)");
      `CHK(grant_o[1] === 1'b1,               "chain: port 1 grants");
      `CHK(grant_idx_o[1] === IDX_W'(1),       "chain: port 1 picks entry 1 (age=8)");
  endtask

  // =========================================================================
  // Main stimulus
  // =========================================================================
  initial begin
      clear_all();

      test_oldest_wins();
      test_no_double_grant();
      test_no_grant_empty();
      test_all_empty();
      test_tie_break();
      test_mask_chain();

      $display("\n============================================================");
      if (errors == 0)
          $display("RESULT: ALL TESTS PASSED (0 errors)");
      else
          $display("RESULT: %0d CHECK(S) FAILED", errors);
      $display("============================================================\n");
      $finish;
  end

  // Watchdog (safety net even for combinational-only tests).
  initial begin
      #100000;
      $display("[FAIL] %0t: TIMEOUT", $time);
      errors = errors + 1;
      $finish;
  end

endmodule : tb_iq_select
