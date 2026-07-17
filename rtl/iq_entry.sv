// =============================================================================
// iq_entry.sv — One Issue-Queue Entry
// =============================================================================
// Purpose:
//   Holds exactly ONE in-flight instruction and tracks whether each of its
//   source operands has become ready. In the kitchen analogy: this is one
//   cubby on the shelf — an order sits here until all its ingredients arrive,
//   then it's eligible to be picked (issued) by the selector.
//
//   Responsibilities:
//     1. Dispatch write  : load a new instruction when this slot is allocated.
//     2. Wakeup snoop   : per-source tag compare; set src_ready[i] when a match broadcasts.
//     3. Age increment  : saturating counter, ticks every cycle while valid.
//     4. Clear on issue/squash: drop the entry when it issues or is flushed.
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
    input  logic                               wakeup_valid,       // Global broadcast valid signal from execution unit writeback
    input  logic [TAG_WIDTH-1:0]               wakeup_tag,         // Global broadcast tag to compare against entry's source tags
    input  logic                               spec_wakeup_valid,  // Speculative broadcast valid signal
    input  logic [TAG_WIDTH-1:0]               spec_wakeup_tag,    // Speculative broadcast tag for early wakeup

    // --- Clear events --------------------------------------------------------
    // issue_clear  : this entry was granted by the selector this cycle.
    // squash_clear : this entry is being flushed — gated per-entry by the CAM
    input  logic                               issue_clear,        // Signal from selector to invalidate this entry upon issue
    input  logic                               squash_clear,       // Signal to flush this entry during a pipeline squash

    // --- State output (read by the selector each cycle) ---------------------
    output iq_pkg::iq_entry_t                  entry_o,    // Full state of this entry broadcasted to the selector
    output logic                               ready_o     // = is_ready(entry) - High when valid and all operands are ready
);

    // -------------------------------------------------------------------------
    // Storage: the one entry's worth of state, as the packed struct from
    // the package. Declared as register storage typed by the struct.
    // -------------------------------------------------------------------------
    iq_pkg::iq_entry_t entry_r; // Internal register storing the state of this entry

    // =========================================================================
    // SAME-CYCLE DISPATCH + WAKEUP BYPASS
    // =========================================================================
    // The comparator compares wakeup_tag against the EFFECTIVE source tag
    // (what src_tag[] WILL be next cycle). This prevents a lost-wakeup bug
    // if a producer broadcasts its tag in the same cycle this instruction
    // is dispatched.
    // =========================================================================

    // Effective (next-cycle) source tags: bypass mux per source.
    logic [NUM_SRC-1:0][TAG_WIDTH-1:0] src_tag_eff; // Next-cycle tags, bypassing stale registers for same-cycle wakeup

    // Procedural for-loop unrolled into NUM_SRC bypass muxes
    always_comb begin : src_tag_eff_calc
        for (int i = 0; i < NUM_SRC; i++) begin
            src_tag_eff[i] = dispatch_we ? dispatch_src_tag[i]
                                         : entry_r.src_tag[i];
        end
    end

    // Per-source wakeup hit comparators
    logic [NUM_SRC-1:0] wakeup_hit;       // 1 if source i matches the normal broadcast tag
    logic [NUM_SRC-1:0] spec_wakeup_hit;  // 1 if source i matches the speculative broadcast tag
    always_comb begin : wakeup_compare
        for (int i = 0; i < NUM_SRC; i++) begin
            // wakeup_hit[i] fires when the broadcast tag matches source i's
            // producer tag. Using the EFFECTIVE tag is what makes the
            // same-cycle bypass work — see the big comment block above.
            wakeup_hit[i] = wakeup_valid && (wakeup_tag == src_tag_eff[i]);
            spec_wakeup_hit[i] = spec_wakeup_valid && (spec_wakeup_tag == src_tag_eff[i]);
        end
    end

    // =========================================================================
    // Sequential state update
    // =========================================================================
    // Priority order: reset -> dispatch -> issue/squash -> age++.
    // Dispatch dominates over issue_clear to support same-cycle slot reuse.
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
            // Both normal and speculative wakeups can set the ready bit. 
            // In a full replay architecture, we would also need to track whether
            // we became ready speculatively, so we know to flush this entry 
            // if the speculation fails (a "poison" or "replay" bit).
            entry_r.src_ready <= dispatch_src_imm | wakeup_hit | spec_wakeup_hit;
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
            entry_r.src_ready <= entry_r.src_ready | wakeup_hit | spec_wakeup_hit;
            entry_r.age       <= (entry_r.age == iq_pkg::AGE_SAT_MAX)
                                  ? iq_pkg::AGE_SAT_MAX
                                  : entry_r.age + 1'b1;
        end
        // else: entry invalid and idle -> hold state (remains invalid).
    end

    // -------------------------------------------------------------------------
    // Combinational outputs connecting entry state to the selector
    // -------------------------------------------------------------------------
    assign entry_o = entry_r;
    assign ready_o = iq_pkg::is_ready(entry_r);

endmodule : iq_entry

`endif // IQ_ENTRY_SV
