// =============================================================================
// iq_entry.sv — One Issue-Queue Entry (Step 1)
// =============================================================================
// Purpose:
//   Holds exactly ONE in-flight instruction and tracks whether each of its
//   source operands has become ready. In the kitchen analogy: this is one
//   cubby on the shelf — an order sits here until all its ingredients arrive,
//   then it's eligible to be picked (issued) by the selector.
//
//   Responsibilities (CLAUDE.md Step 1):
//     1. Dispatch write  : load a new instruction when this slot is allocated.
//     2. Wakeup snoop   : per-source CAM-style tag compare; set src_ready[i]
//                         when a matching tag broadcasts on the wakeup bus.
//     3. Age increment  : saturating counter, ticks every cycle while valid.
//     4. Clear on issue/squash: drop the entry when it issues or is flushed.
//
//   THE BIG IDEA for this step is the same-cycle dispatch+wakeup BYPASS,
//   explained in detail where it is implemented below. Read that comment
//   block carefully — it is the interview-worthy part of Step 1.
//
//   Why explicit ports (not the iq_if interface) here:
//     iq_if.sv bundles the WHOLE queue's bus for the top level. A single
//     entry only needs its own sliver: one dispatch-we, the global wakeup
//     bus, an issue/squash clear, and its own state output. Wiring a full
//     interface into a leaf would expose signals the entry must never
//     touch. Leaf modules take explicit ports; the top level (Step 4)
//     fans the interface out to all entries. This contrast is itself a
//     lesson: interface = inter-module bundling, ports = intra-module API.
// =============================================================================

`ifndef IQ_ENTRY_SV
`define IQ_ENTRY_SV

`include "iq_pkg.sv"   // brings in iq_entry_t, parameters, helper functions

module iq_entry #(
    parameter int unsigned TAG_WIDTH = iq_pkg::TAG_WIDTH,
    parameter int unsigned NUM_SRC   = iq_pkg::NUM_SRC,
    parameter int unsigned AGE_WIDTH = iq_pkg::AGE_WIDTH
)(
    input  logic                               clk,
    input  logic                               rst_n,

    // --- Dispatch write (this slot is the allocation target this cycle) -----
    // dispatch_we is the slot's write-enable: the free-slot allocator in
    // iq_top asserts it for exactly one entry per dispatched instruction.
    input  logic                               dispatch_we,
    input  logic [TAG_WIDTH-1:0]               dispatch_dst_tag,
    input  logic [NUM_SRC-1:0][TAG_WIDTH-1:0]  dispatch_src_tag,
    // Immediate mask: bit i = 1 means source i is an immediate (no producer),
    // so it is ready the instant the entry is written — no wakeup needed.
    input  logic [NUM_SRC-1:0]                 dispatch_src_imm,
    input  logic [15:0]                        dispatch_disp_seq,

    // --- Wakeup snoop (global broadcast; every entry sees the same bus) -----
    input  logic                               wakeup_valid,
    input  logic [TAG_WIDTH-1:0]               wakeup_tag,

    // --- Clear events --------------------------------------------------------
    // issue_clear  : this entry was granted by the selector this cycle.
    // squash_clear : this entry is being flushed — gated per-entry by the CAM
    //                 (Step 5): only entries with disp_seq > squash_seq clear.
    input  logic                               issue_clear,
    input  logic                               squash_clear,

    // --- State output (read by the selector each cycle) ---------------------
    output iq_pkg::iq_entry_t                  entry_o,
    output logic                               ready_o     // = is_ready(entry)
);

    // -------------------------------------------------------------------------
    // Storage: the one entry's worth of state, as the packed struct from
    // the package. Declared as register storage typed by the struct.
    // -------------------------------------------------------------------------
    iq_pkg::iq_entry_t entry_r;

    // =========================================================================
    // SAME-CYCLE DISPATCH + WAKEUP BYPASS — read this twice
    // =========================================================================
    // The corner case:
    //   Cycle N: this slot is the dispatch target (dispatch_we=1) carrying a
    //   payload whose src_tag[0]=5. Simultaneously, a wakeup bus broadcasts
    //   wakeup_tag=5 — some producer just completed and is announcing "tag 5
    //   is ready".
    //
    //   NAIVE (WRONG) design: the wakeup comparator reads the REGISTERED
    //   src_tag[] — but that still holds the OLD (stale) value until the end
    //   of cycle N. The comparator compares wakeup_tag=5 against garbage,
    //   misses, and src_ready[0] is never set. The freshly-dispatched entry
    //   is now stuck waiting for a "tag 5 ready" broadcast that already came
    //   and went. If no other instruction ever produces tag 5 again, the
    //   entry DEADLOCKS — a lost-wakeup bug. This is exactly the class of
    //   subtlety that makes out-of-order cores hard.
    //
    //   CORRECT (THIS) design: the comparator compares wakeup_tag against the
    //   EFFECTIVE source tag — i.e. what src_tag[] WILL be next cycle:
    //       src_tag_eff[i] = dispatch_we ? dispatch_src_tag[i]
    //                                    : entry_r.src_tag[i]
    //   So a wakeup broadcast in the same cycle as dispatch is caught by the
    //   freshly-loaded payload. src_ready[0] is set at the end of cycle N,
    //   the entry is fully ready in cycle N+1, and the selector can issue it.
    //
    //   DECISION: implement the bypass. Cost is one 2:1 mux per source feeding
    //   the existing comparator — trivial. The alternative (no bypass, hope
    //   the broadcast repeats) is a correctness hazard. Real OoO cores do
    //   exactly this; it is the mechanism that lets an instruction dispatched
    //   the same cycle a producer issues catch that producer's wakeup.
    //
    //   Timing note: this makes the entry READY one cycle AFTER dispatch
    //   (registered). It does NOT create a combinational ready output —
    //   ready_o reads the registered entry_r, so there is no combinational
    //   loop back into the selector.
    // =========================================================================

    // Effective (next-cycle) source tags: bypass mux per source.
    logic [NUM_SRC-1:0][TAG_WIDTH-1:0] src_tag_eff;

    // The procedural `for` loop inside always_comb unrolls at elaboration
    // because NUM_SRC is a compile-time constant — no runtime loop, no HW cost
    // beyond the unrolled copies.
    always_comb begin : src_tag_eff_calc
        for (int i = 0; i < NUM_SRC; i++) begin
            src_tag_eff[i] = dispatch_we ? dispatch_src_tag[i]
                                         : entry_r.src_tag[i];
        end
    end

    // Per-source wakeup hit. This is the "CAM-style compare": each source
    // independently ANDs the bus-valid with a tag-equality check against its
    // own effective tag. NUM_SRC independent comparators run in parallel —
    // no priority among sources, they're peers. (The "CAM" name comes from
    // content-addressable memory: you query "who has tag 5?" and every
    // entry answers in parallel. Here each source is a tiny CAM line.)
    logic [NUM_SRC-1:0] wakeup_hit;
    always_comb begin : wakeup_compare
        for (int i = 0; i < NUM_SRC; i++) begin
            // wakeup_hit[i] fires when the broadcast tag matches source i's
            // producer tag. Using the EFFECTIVE tag is what makes the
            // same-cycle bypass work — see the big comment block above.
            wakeup_hit[i] = wakeup_valid && (wakeup_tag == src_tag_eff[i]);
        end
    end

    // =========================================================================
    // Sequential state update
    // =========================================================================
    // This always_ff implements the four Step-1 behaviors. Priority order:
    //   1. reset          -> zero everything
    //   2. dispatch_we    -> load new payload (DOMINATES; handles same-cycle
    //                        slot reuse where an issuing slot is redispatched)
    //   3. issue/squash   -> invalidate (entry leaves the queue)
    //   4. valid & idle   -> sticky wakeup OR + saturating age++
    //
    // Why dispatch dominates over issue_clear: in Step 4 the free-slot
    // allocator may reuse a slot in the very cycle its old instruction issues
    // ("same-cycle slot reuse", a real-core utilization trick). If both fire,
    // the NEW instruction must win — it overwrites the issuing old one.
    // Putting dispatch first in the if-else chain makes that fall out for free.
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin : entry_state
        if (!rst_n) begin
            entry_r <= '0;                       // packed-struct literal zero
        end else if (dispatch_we) begin
            // Fresh dispatch. src_ready seeds from: imm mask OR same-cycle
            // wakeup catch (the bypass). An entry can be fully ready at the
            // end of the dispatch cycle if every source is immediate or
            // wakeup-matched — the best case.
            entry_r.valid     <= 1'b1;
            entry_r.dst_tag   <= dispatch_dst_tag;
            entry_r.src_tag   <= dispatch_src_tag;
            entry_r.src_ready <= dispatch_src_imm | wakeup_hit;
            entry_r.age       <= '0;
            entry_r.disp_seq  <= dispatch_disp_seq;   // monotonic sequence number for squash comparison
        end else if (issue_clear || squash_clear) begin
            // Entry leaves the queue. Payload left don't-care (overwritten on
            // next dispatch); we clear validity + src_ready + age for clean
            // waveforms and so no stale ready bit leaks into a future tenant.
            entry_r.valid     <= 1'b0;
            entry_r.src_ready <= '0;
            entry_r.age       <= '0;
        end else if (entry_r.valid) begin
            // Sticky wakeup: once a source is ready it stays ready; OR-in any
            // new hits this cycle. Saturating age: count up to all-ones then
            // hold — that all-ones value is the "I am very old" sentinel the
            // selector understands (see iq_pkg::age_older_than).
            entry_r.src_ready <= entry_r.src_ready | wakeup_hit;
            entry_r.age       <= (entry_r.age == iq_pkg::AGE_SAT_MAX)
                                  ? iq_pkg::AGE_SAT_MAX
                                  : entry_r.age + 1'b1;
        end
        // else: entry invalid and idle -> hold state (remains invalid).
    end

    // -------------------------------------------------------------------------
    // Combinational outputs. ready_o uses the package helper so the
    // "valid AND all-sources-ready" predicate is defined in exactly one place
    // (the package) and shared by RTL, TB, and SVA. One definition = one
    // place for a reviewer to check = one place for a bug to hide.
    // -------------------------------------------------------------------------
    assign entry_o = entry_r;
    assign ready_o = iq_pkg::is_ready(entry_r);

endmodule : iq_entry

`endif // IQ_ENTRY_SV
