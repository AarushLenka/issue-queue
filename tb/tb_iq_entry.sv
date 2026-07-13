// =============================================================================
// tb_iq_entry.sv — Directed Testbench for ONE iq_entry (Step 1)
// =============================================================================
// Purpose:
//   Drive a single iq_entry through the lifecycle from CLAUDE.md and check
//   it behaves at every transition. Three directed tests, each isolating
//   ONE of the three ways the entry's src_ready bits get set:
//
//     test_basic  : dispatch (no imm, no same-cycle wakeup) -> wake src0
//                   -> wake src1 -> issue.   [post-dispatch wakeup + issue]
//     test_bypass : dispatch and a matching wakeup for src0 in the SAME
//                   cycle -> src0 ready immediately. [the bypass corner case]
//     test_imm    : src0 declared immediate -> ready at dispatch with no
//                   wakeup at all.          [immediate source path]
//
//   These three map exactly onto the three OR-terms of
//       entry_r.src_ready <= dispatch_src_imm | wakeup_hit   (dispatch branch)
//   so every way src_ready can become 1 is exercised in isolation.
//
// TIMING CONVENTION (used throughout this file — read once, applies everywhere):
//   We drive inputs *after* a @(posedge clk) and sample *after* the next
//   @(posedge clk) plus a #1 settle delay:
//
//        @(posedge clk);   <-- align
//        <set input regs>  <-- inputs go stable mid-cycle
//        @(posedge clk);   <-- the REGISTER CAPTURES the inputs on this edge
//        #1;               <-- let combinational ready_o settle from the new reg
//        <sample outputs>  <-- entry_o / ready_o now reflect the capture
//
//   The #1 is defensive: ready_o is `assign`ed from the register so it really
//   settles in zero time, but the explicit delta makes waveform traces
//   unambiguous (sample point is clearly after the edge, not on it).
// =============================================================================

`timescale 1ns/1ps

`ifndef TB_IQ_ENTRY_SV
`define TB_IQ_ENTRY_SV

`include "iq_pkg.sv"

// import iq_pkg::* — WILDCARD IMPORT: brings every name declared in the
// package (iq_entry_t, AGE_SAT_MAX, TAG_WIDTH, NUM_SRC, ...) into local
// scope so we can write `iq_entry_t` instead of `iq_pkg::iq_entry_t`.
// Convenient for TBs; in RTL we prefer the fully-qualified form so the
// origin of each name is obvious to a reviewer.
import iq_pkg::*;

module tb_iq_entry;

  // -------------------------------------------------------------------------
  // TB-side aliases for package parameters. Common verification pattern:
  // alias package constants to short local names so payload literals stay
  // readable (e.g. TW'h5 instead of iq_pkg::TAG_WIDTH'h5). If the package
  // widths change, these localparams follow automatically.
  // -------------------------------------------------------------------------
  localparam int unsigned TW = TAG_WIDTH;   // operand-tag width (e.g. 6)
  localparam int unsigned NS = NUM_SRC;     // sources per entry (e.g. 2)

  // -------------------------------------------------------------------------
  // Error tally and the CHK macro
  // -------------------------------------------------------------------------
  // int errors = 0;  -- declaration initializer runs at time 0; safe for a TB.
  int errors = 0;

  // CHK — the standard directed-TB checker pattern, wrapped in a do-while
  // so it expands to a single statement (safe before else / with trailing ;).
  // `cond` is evaluated in place; on PASS we print the time + message; on
  // FAIL we also dump the whole entry_o via %p (pattern format: prints a
  // struct/array member-wise — your first exposure to %p) so you can see
  // exactly what went wrong in the log without opening a waveform.
  `define CHK(cond, msg) \
    do begin \
      if (cond) begin \
        $display("    [PASS] %0t: %s", $time, msg); \
      end else begin \
        $display("    [FAIL] %0t: %s  (entry_o=%p)", $time, msg, entry_o); \
        errors = errors + 1; \
      end \
    end while (0)

  // -------------------------------------------------------------------------
  // DUT connection signals
  // -------------------------------------------------------------------------
  // Inputs are `logic` regs (procedurally driven by the TB). Outputs are
  // plain wires (read-only). Note the widths come from the package aliases
  // above, so they match the DUT ports by construction.
  logic                               clk;
  logic                               rst_n;

  logic                               dispatch_we;
  logic [TW-1:0]                      dispatch_dst_tag;
  logic [NS-1:0][TW-1:0]              dispatch_src_tag;
  logic [NS-1:0]                       dispatch_src_imm;

  logic                               wakeup_valid;
  logic [TW-1:0]                       wakeup_tag;

  logic                               issue_clear;
  logic                               squash_clear;   // tied low; Step 5 only

  iq_entry_t                          entry_o;        // struct output from DUT
  logic                               ready_o;

  // -------------------------------------------------------------------------
  // Clock: 10-time-unit period, 50% duty. Declaration initializer sets the
  // initial level; the always block toggles every 5 time units.
  // -------------------------------------------------------------------------
  initial clk = 1'b0;
  always #5 clk = ~clk;

  // -------------------------------------------------------------------------
  // DUT: instantiate with package defaults (TAG_WIDTH/NUM_SRC/AGE_WIDTH all
  // come from iq_pkg). We pass NO parameter overrides — TB and DUT share the
  // same package, so widths can't drift apart. This is the cheapest way to
  // stay consistent and is worth understanding: defaults derive from one
  // source of truth (the package).
  // -------------------------------------------------------------------------
  iq_entry dut (
      .clk              (clk),
      .rst_n            (rst_n),
      .dispatch_we      (dispatch_we),
      .dispatch_dst_tag (dispatch_dst_tag),
      .dispatch_src_tag (dispatch_src_tag),
      .dispatch_src_imm (dispatch_src_imm),
      .wakeup_valid     (wakeup_valid),
      .wakeup_tag       (wakeup_tag),
      .issue_clear      (issue_clear),
      .squash_clear     (squash_clear),
      .entry_o          (entry_o),
      .ready_o          (ready_o)
  );

  // =========================================================================
  // Pulse tasks — timing helpers
  // =========================================================================
  // WHAT IS `task automatic`: a reusable block of procedural code. `automatic`
  // gives each CALL its own private storage for locals (re-entrant), which is
  // the safe default — a non-automatic (static) task shares locals across
  // calls and would corrupt if ever called concurrently. We use tasks here
  // only to factor out the one-cycle strobe timing; the PAYLOAD (dst/src/imm
  // or wakeup_tag) is set directly in the test body so there's no
  // packed-array-literal ordering footgun in the call site.

  // Hold reset (async-low in the DUT) for a few cycles, then release.
  task automatic do_reset;
      @(posedge clk);
      rst_n = 1'b0;
      repeat (3) @(posedge clk);   // hold; async reset zeros entry_r on the
                                   // negedge of rst_n, so even one edge works,
                                   // but 3 cycles is belt-and-suspenders
      rst_n = 1'b1;
      @(posedge clk);
      #1;
  endtask

  // Strobe dispatch_we for exactly one cycle. Payload must already be on the
  // dispatch_* regs. After return we are #1 past the capturing edge and
  // dispatch_we is back to 0 (so we don't accidentally reload next cycle).
  task automatic do_dispatch_pulse;
      @(posedge clk);
      dispatch_we = 1'b1;
      @(posedge clk);    // <-- capturing edge: entry_r loads the payload
      #1;
      dispatch_we = 1'b0;
  endtask

  // Strobe wakeup_valid for exactly one cycle. wakeup_tag must already be set.
  task automatic do_wakeup_pulse;
      @(posedge clk);
      wakeup_valid = 1'b1;
      @(posedge clk);    // <-- capturing edge: src_ready ORs in any hits
      #1;
      wakeup_valid = 1'b0;
  endtask

  // Strobe issue_clear for exactly one cycle -> entry invalidates.
  task automatic do_issue_pulse;
      @(posedge clk);
      issue_clear = 1'b1;
      @(posedge clk);    // <-- capturing edge: valid clears
      #1;
      issue_clear = 1'b0;
  endtask

  // =========================================================================
  // test_basic — the CLAUDE.md Step-1 baseline lifecycle
  // =========================================================================
  // Verifies:
  //   - dispatch sets valid with NO sources ready (no imm, no same-cycle wk)
  //   - a wakeup for src0 raises src_ready[0] but NOT ready_o (src1 missing)
  //   - a wakeup for src1 raises src_ready[0] AND makes ready_o=1 (all ready)
  //   - issue clears valid and ready_o
  // Each CHK has a "why this matters" note.
  task automatic test_basic;
      $display("\n[TEST] test_basic: dispatch -> wake src0 -> wake src1 -> issue");
      // --- Dispatch: needs tag5 for src0, tag9 for src1, no immediates ---
      dispatch_dst_tag  = 'h11;
      dispatch_src_tag[0] = 'h5;    // explicit per-source assignment — no
      dispatch_src_tag[1] = 'h9;    // array-literal-ordering surprises
      dispatch_src_imm    = '0;
      do_dispatch_pulse();

      // WHY: confirms dispatch writes the slot and that a freshly-dispatched
      // entry is NOT spuriously ready — both sources are still unready and
      // no immediates are set, so ready_o must be 0.
      `CHK(entry_o.valid === 1'b1,      "basic: valid set after dispatch");
      `CHK(entry_o.src_ready === '0,    "basic: no sources ready right after dispatch");
      `CHK(ready_o === 1'b0,            "basic: not ready (both src unready)");

      // --- Wakeup src0 (broadcast tag 5) ---
      wakeup_tag = 'h5;
      do_wakeup_pulse();

      // WHY: the CAM compare must match only src0's tag, leaving src1
      // untouched. Confirms per-source independence — waking one operand
      // does NOT falsely mark the other ready.
      `CHK(entry_o.src_ready[0] === 1'b1, "basic: src0 ready after wakeup tag5");
      `CHK(entry_o.src_ready[1] === 1'b0, "basic: src1 still unready");
      `CHK(ready_o === 1'b0,              "basic: still not fully ready (src1 missing)");

      // --- Wakeup src1 (broadcast tag 9) ---
      wakeup_tag = 'h9;
      do_wakeup_pulse();

      // WHY: this is the "becomes issue-able" transition — the AND-reduction
      // of src_ready now passes, which is the selector's trigger. If this
      // fails, the queue would never issue this instruction (deadlock).
      `CHK(entry_o.src_ready[1] === 1'b1, "basic: src1 ready after wakeup tag9");
      `CHK(ready_o === 1'b1,              "basic: fully ready once both sources ready");

      // --- Issue ---
      do_issue_pulse();

      // WHY: an issued entry must FREE its slot, otherwise the allocator
      // (Step 4) would never reuse it and the queue would fill up and stall
      // forever. src_ready clearing prevents a stale ready bit from leaking
      // into the next tenant of this slot.
      `CHK(entry_o.valid === 1'b0,        "basic: valid cleared after issue");
      `CHK(ready_o === 1'b0,              "basic: ready cleared after issue");
      `CHK(entry_o.src_ready === '0,      "basic: src_ready cleared after issue");
  endtask

  // =========================================================================
  // test_bypass — same-cycle dispatch + wakeup corner case
  // =========================================================================
  // In the SAME cycle, do_dispatch AND a wakeup matching src0's tag. Because
  // the DUT's comparator uses the EFFECTIVE (incoming) src_tag — not the
  // stale registered value — the wakeup is CAUGHT and src_ready[0] is set
  // at the end of the dispatch cycle (one cycle earlier than test_basic).
  //
  // This is THE test for the big commented decision in iq_entry.sv. If the
  // bypass mux src_tag_eff were removed, src_ready[0] would stay 0 here
  // and the second CHK below would fail — that failure is a lost-wakeup
  // deadlock in disguise.
  //
  // We can't use do_dispatch_pulse + do_wakeup_pulse for the same-cycle
  // case (each pulses on its own cycle); we drive both strobes inline.
  task automatic test_bypass;
      $display("\n[TEST] test_bypass: same-cycle dispatch + wakeup for src0");
      // Set payloads first (no edge yet).
      dispatch_dst_tag    = 'h33;
      dispatch_src_tag[0] = 'h7;
      dispatch_src_tag[1] = 'h8;
      dispatch_src_imm    = '0;
      wakeup_tag          = 'h7;        // matches src0 — SAME cycle

      // Drive BOTH strobes for one cycle together.
      @(posedge clk);
      dispatch_we  = 1'b1;
      wakeup_valid = 1'b1;
      @(posedge clk);    // <-- captures dispatch + simultaneous wakeup
      #1;

      // WHY: src_ready[0] must be set THIS cycle (the bypass paid off).
      // The contrast with test_basic is the whole point: there, src0 needed
      // a SEPARATE wakeup cycle; here it's ready one cycle sooner.
      `CHK(entry_o.valid === 1'b1,        "bypass: valid after dispatch");
      `CHK(entry_o.src_ready[0] === 1'b1, "bypass: src0 caught SAME-cycle wakeup (bypass works)");
      `CHK(entry_o.src_ready[1] === 1'b0, "bypass: src1 still unready (no wakeup for tag8)");
      `CHK(ready_o === 1'b0,              "bypass: not fully ready (src1 still missing)");

      dispatch_we  = 1'b0;
      wakeup_valid = 1'b0;

      // Finish src1 the normal (next-cycle) way and confirm full readiness.
      wakeup_tag = 'h8;
      do_wakeup_pulse();
      `CHK(entry_o.src_ready[1] === 1'b1, "bypass: src1 ready after late wakeup");
      `CHK(ready_o === 1'b1,              "bypass: fully ready after src1 wakeup");

      do_issue_pulse();
      `CHK(entry_o.valid === 1'b0,        "bypass: valid cleared after issue");
  endtask

  // =========================================================================
  // test_imm — immediate source ready at dispatch with no wakeup
  // =========================================================================
  // Declare src0 an immediate (dispatch_src_imm[0]=1). It has no producer,
  // so it must be ready the instant the entry is written — no wakeup bus
  // traffic needed. src1 still needs a normal wakeup. Confirms the
  // `dispatch_src_imm` term of `dispatch_src_imm | wakeup_hit`.
  task automatic test_imm;
      $display("\n[TEST] test_imm: src0 immediate (ready at dispatch), src1 via wakeup");
      dispatch_dst_tag    = 'h44;
      dispatch_src_tag[0] = 'h0;         // don't-care: src0 is immediate
      dispatch_src_tag[1] = 'h9;
      dispatch_src_imm    = 2'b01;        // bit0=1 -> src0 is immediate
      do_dispatch_pulse();

      // WHY: an immediate must NEVER require a wakeup. If this fails, the
      // dispatch-seeding of src_ready from dispatch_src_imm is broken, and
      // every instruction carrying an immediate operand would deadlock.
      `CHK(entry_o.src_ready[0] === 1'b1, "imm: src0 ready at dispatch (immediate, no wakeup)");
      `CHK(entry_o.src_ready[1] === 1'b0, "imm: src1 still unready");
      `CHK(ready_o === 1'b0,              "imm: not fully ready yet (src1 missing)");

      // Wakeup src1 the normal way.
      wakeup_tag = 'h9;
      do_wakeup_pulse();
      `CHK(entry_o.src_ready[1] === 1'b1, "imm: src1 ready after wakeup");
      `CHK(ready_o === 1'b1,              "imm: fully ready (1 immediate + 1 wakeup)");

      do_issue_pulse();
      `CHK(entry_o.valid === 1'b0,        "imm: valid cleared after issue");
  endtask

  // =========================================================================
  // Main stimulus: reset, run tests in order, summarize, finish.
  // =========================================================================
  // `===` (case equality) is used in every CHK, not `==`: case equality
  // treats X as a distinct value, so an X-propagated signal fails the check
  // loudly instead of deceptively passing (which `==` can do when X is on
  // one side). For directed verification, always prefer `===`.
  initial begin
      // Idle all inputs before the first edge.
      rst_n            = 1'b1;
      dispatch_we      = 1'b0;
      dispatch_dst_tag = '0;
      dispatch_src_tag = '0;
      dispatch_src_imm = '0;
      wakeup_valid     = 1'b0;
      wakeup_tag       = '0;
      issue_clear      = 1'b0;
      squash_clear     = 1'b0;   // never asserted in Step 1

      do_reset();
      test_basic();
      test_bypass();
      test_imm();

      // Summary — the one line you grep for on the server.
      $display("\n============================================================");
      if (errors == 0)
          $display("RESULT: ALL TESTS PASSED (0 errors)");
      else
          $display("RESULT: %0d CHECK(S) FAILED", errors);
      $display("============================================================\n");
      $finish;
  end

  // -------------------------------------------------------------------------
  // Watchdog: if something hangs (a stuck `@(posedge clk)` wait, an
  // unhandled case), bail out loudly instead of simulating forever.
  // 100us = ~10000 cycles at our 10ns clock; these tests need ~30.
  // -------------------------------------------------------------------------
  initial begin
      #100000;
      $display("[FAIL] %0t: TIMEOUT — simulation hung", $time);
      errors = errors + 1;
      $finish;
  end

endmodule : tb_iq_entry

`endif // TB_IQ_ENTRY_SV
