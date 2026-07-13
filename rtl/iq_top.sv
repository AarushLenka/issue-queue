// =============================================================================
// iq_top.sv — Issue Queue Top-Level Integration (Step 4)
// =============================================================================
// Purpose:
//   Wires together the three sub-blocks built in Steps 1-3:
//     1. iq_wakeup_cam  : DEPTH entries with distributed wakeup comparators
//     2. iq_select       : multi-port oldest-ready priority-tree selector
//     3. Free-slot allocator (NEW, implemented here): picks which physical
//        slot to write a newly-dispatched instruction into
//
//   This module sits between the iq_if interface (external bus contract)
//   and the internal datapath. It translates the interface signals into
//   the per-entry control signals the sub-blocks expect.
//
// =============================================================================
// FREE-SLOT ALLOCATOR — DESIGN DECISION (INTERVIEW Q&A)
// =============================================================================
//
// The allocator answers: "which entry slot should a newly dispatched
// instruction be written into?"
//
// --- OPTION A: PRIORITY-ENCODER OVER FREE-SLOTS (what we implement) ---------
//   Maintain a DEPTH-bit `free_vec` where bit i = 1 means entry i is invalid
//   (available). On dispatch, a priority encoder finds the lowest-indexed
//   free slot and allocates it.
//
//   How free_vec is maintained:
//     - On reset: free_vec = all-ones (every slot is free).
//     - On dispatch: clear the allocated bit (slot is now occupied).
//     - On issue/squash: set the cleared entry's bit (slot is freed).
//     - These updates happen in the same always_ff, so same-cycle
//       dispatch+issue of DIFFERENT slots is handled naturally.
//
//   Pros:
//     - Zero storage beyond the free_vec register (DEPTH bits).
//     - Deterministic: always picks the lowest free index, making
//       waveform debugging trivial (you know where to look).
//     - Naturally handles fragmentation — any free slot is usable.
//
//   Cons:
//     - Priority encoder is O(DEPTH) logic depth. For DEPTH=16 this is
//       a 4-level OR tree — fast. For DEPTH=128+ it would need pipelining.
//     - Not fair: lower-indexed slots are reused more often. This doesn't
//       matter for correctness but creates uneven toggle activity (minor
//       power concern at very high DEPTH).
//
// --- OPTION B: ROUND-ROBIN ALLOCATION POINTER (alternative) -----------------
//   A single $clog2(DEPTH)-bit pointer that advances after each allocation,
//   wrapping around. On dispatch, use the pointer's slot if it's free;
//   otherwise scan forward.
//
//   Pros:
//     - Spreads writes evenly across slots (better toggle balance).
//     - O(1) for the common case (pointer slot is free).
//
//   Cons:
//     - Scan-forward on a non-free slot reintroduces a priority encoder.
//     - Pointer register adds state and a mux on the scan start point.
//     - Harder to debug (allocation pattern is less predictable).
//
//   DECISION: Priority-encoder (Option A). At DEPTH≤32, the encoder is
//   trivially fast. The deterministic allocation order simplifies waveform
//   analysis during development. Round-robin becomes attractive only at
//   DEPTH≥64 for power uniformity.
// =============================================================================

`ifndef IQ_TOP_SV
`define IQ_TOP_SV

`include "iq_pkg.sv"
`include "iq_if.sv"
`include "iq_entry.sv"
`include "iq_wakeup_cam.sv"
`include "iq_select.sv"

module iq_top #(
    parameter int unsigned DEPTH     = iq_pkg::DEPTH,
    parameter int unsigned TAG_WIDTH = iq_pkg::TAG_WIDTH,
    parameter int unsigned NUM_SRC   = iq_pkg::NUM_SRC,
    parameter int unsigned AGE_WIDTH = iq_pkg::AGE_WIDTH,
    parameter int unsigned NUM_PORTS = iq_pkg::NUM_PORTS
)(
    input  logic clk,
    input  logic rst_n,

    // --- External interface (the iq_if modport facing inward) ----------------
    // Instead of using the interface modport directly (which would require
    // the caller to instantiate iq_if), we use explicit ports that mirror
    // iq_if's iq_mp modport. This keeps iq_top portable — any testbench
    // can drive it without instantiating the interface.
    //
    // Dispatch inputs (from dispatch unit):
    input  logic                               dispatch_valid,
    input  logic [TAG_WIDTH-1:0]               dispatch_dst_tag,
    input  logic [NUM_SRC-1:0][TAG_WIDTH-1:0]  dispatch_src_tag,
    input  logic [NUM_SRC-1:0]                 dispatch_src_imm,

    // Dispatch outputs (backpressure to dispatch unit):
    output logic                               dispatch_ready,
    output logic [$clog2(DEPTH)-1:0]           dispatch_slot_idx,

    // Wakeup inputs (from execution writeback):
    input  logic                               wakeup_valid,
    input  logic [TAG_WIDTH-1:0]               wakeup_tag,

    // Issue outputs (to execution units):
    output logic [NUM_PORTS-1:0]                          issue_valid,
    output logic [NUM_PORTS-1:0][$clog2(DEPTH)-1:0]       issue_idx,
    output logic [NUM_PORTS-1:0][TAG_WIDTH-1:0]           issue_dst_tag,
    output logic [NUM_PORTS-1:0][AGE_WIDTH-1:0]           issue_age,

    // Squash input (Step 5 — active-high, clears ALL valid entries for now):
    input  logic                               squash_en
);

    localparam int unsigned IDX_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH);

    // =========================================================================
    // Internal wires
    // =========================================================================

    // Per-entry state from the wakeup CAM.
    iq_pkg::iq_entry_t  entry_array [DEPTH];
    logic [DEPTH-1:0]   ready_array;

    // Selector outputs.
    logic [NUM_PORTS-1:0]                  sel_grant;
    logic [NUM_PORTS-1:0][IDX_W-1:0]       sel_idx;
    logic [NUM_PORTS-1:0][TAG_WIDTH-1:0]   sel_tag;
    logic [NUM_PORTS-1:0][AGE_WIDTH-1:0]   sel_age;

    // =========================================================================
    // Free-slot allocator (priority encoder)
    // =========================================================================
    // free_vec[i] = 1 means entry i is available for dispatch. Updated
    // each cycle based on dispatch (consumes a slot) and issue/squash
    // (frees slots). The priority encoder finds the lowest-indexed 1-bit.

    logic [DEPTH-1:0] free_vec;
    logic [IDX_W-1:0] alloc_idx;    // lowest free slot index
    logic             has_free;     // at least one slot is free

    // Priority encoder: find the lowest set bit in free_vec.
    // This is a standard "find-first-one" pattern. We walk from bit 0 upward
    // and take the first 1 — synthesizes into a priority tree that is
    // O(log(DEPTH)) deep, well within timing for DEPTH≤32.
    always_comb begin : find_free_slot
        alloc_idx = '0;
        has_free  = 1'b0;
        for (int i = 0; i < DEPTH; i++) begin
            if (free_vec[i] && !has_free) begin
                alloc_idx = i[IDX_W-1:0];
                has_free  = 1'b1;
            end
        end
    end

    // Dispatch is accepted only when the caller asserts dispatch_valid AND
    // there is a free slot. dispatch_ready signals the upstream dispatch unit
    // whether the queue can accept.
    logic dispatch_accepted;
    assign dispatch_ready   = has_free;
    assign dispatch_accepted = dispatch_valid && has_free;
    assign dispatch_slot_idx = alloc_idx;

    // Free-vector update: sequential logic maintaining the allocation state.
    // Three events modify free_vec:
    //   1. Reset      → all slots free.
    //   2. Dispatch   → allocated slot becomes occupied (clear bit).
    //   3. Issue      → issued slot(s) become free (set bit).
    //   4. Squash     → squashed slots become free (Step 5 will refine).
    //
    // Priority: issue/squash frees happen BEFORE dispatch consume in the
    // same cycle. This means if entry X issues and entry X is also the
    // dispatch target (same-cycle slot reuse), dispatch_we in iq_entry
    // dominates (it's first in the if-else chain), and free_vec correctly
    // stays occupied. The entry sees the new instruction, not a stale clear.
    always_ff @(posedge clk or negedge rst_n) begin : free_vec_update
        if (!rst_n) begin
            free_vec <= '1;    // all slots free on reset (DEPTH ones)
        end else begin
            // Step 1: free slots that were just issued.
            for (int p = 0; p < NUM_PORTS; p++) begin
                if (sel_grant[p])
                    free_vec[sel_idx[p]] <= 1'b1;
            end

            // Step 2: free all slots on squash (Step 5 will make this
            // selective based on dispatch sequence numbers).
            if (squash_en) begin
                free_vec <= '1;
            end

            // Step 3: consume slot on dispatch (after frees, so if the
            // same slot is freed and re-dispatched in one cycle, the
            // dispatch write wins — slot stays occupied with new data).
            if (dispatch_accepted) begin
                free_vec[alloc_idx] <= 1'b0;
            end
        end
    end

    // =========================================================================
    // Sub-block instantiation
    // =========================================================================

    // --- Wakeup CAM: entry array + broadcast wakeup -------------------------
    iq_wakeup_cam #(
        .DEPTH     (DEPTH),
        .TAG_WIDTH (TAG_WIDTH),
        .NUM_SRC   (NUM_SRC),
        .AGE_WIDTH (AGE_WIDTH),
        .NUM_PORTS (NUM_PORTS)
    ) u_cam (
        .clk               (clk),
        .rst_n             (rst_n),

        .dispatch_valid    (dispatch_accepted),    // only write if accepted
        .dispatch_slot_idx (alloc_idx),
        .dispatch_dst_tag  (dispatch_dst_tag),
        .dispatch_src_tag  (dispatch_src_tag),
        .dispatch_src_imm  (dispatch_src_imm),

        .wakeup_valid      (wakeup_valid),
        .wakeup_tag        (wakeup_tag),

        .issue_grant       (sel_grant),
        .issue_idx         (sel_idx),

        .squash_en         (squash_en),

        .entry_array_o     (entry_array),
        .ready_array_o     (ready_array)
    );

    // --- Selector: combinational oldest-ready pick --------------------------
    iq_select #(
        .DEPTH     (DEPTH),
        .AGE_WIDTH (AGE_WIDTH),
        .NUM_PORTS (NUM_PORTS),
        .TAG_WIDTH (TAG_WIDTH)
    ) u_select (
        .entry_i     (entry_array),
        .ready_i     (ready_array),

        .grant_o     (sel_grant),
        .grant_idx_o (sel_idx),
        .grant_tag_o (sel_tag),
        .grant_age_o (sel_age)
    );

    // =========================================================================
    // Issue bus outputs
    // =========================================================================
    // Wire the selector's grants directly to the external issue ports.
    // The selector is combinational, so these outputs are valid in the same
    // cycle the entries are ready — the entry clears on the NEXT posedge
    // (driven by issue_grant feeding back into the CAM).
    assign issue_valid   = sel_grant;
    assign issue_idx     = sel_idx;
    assign issue_dst_tag = sel_tag;
    assign issue_age     = sel_age;

endmodule : iq_top

`endif // IQ_TOP_SV
