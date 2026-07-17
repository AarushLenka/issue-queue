// =============================================================================
// iq_top.sv — Issue Queue Top-Level Integration
// =============================================================================
// Purpose:
//   Wires together the three sub-blocks built in Steps 1-3:
//     1. iq_wakeup_cam  : DEPTH entries with distributed wakeup comparators
//     2. iq_select       : multi-port oldest-ready priority-tree selector
//     3. Free-slot allocator: picks which physical slot to write a newly-dispatched instruction into
//
//   This module sits between the iq_if interface (external bus contract)
//   and the internal datapath. It translates the interface signals into
//   the per-entry control signals the sub-blocks expect.
// =============================================================================

`ifndef IQ_TOP_SV
`define IQ_TOP_SV

`include "iq_pkg.sv"


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
    // We use explicit ports that mirror iq_if's iq_mp modport to keep iq_top
    // portable for any testbench without instantiating the interface directly.
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
    input  logic                               spec_wakeup_valid,
    input  logic [TAG_WIDTH-1:0]               spec_wakeup_tag,

    // Issue outputs (to execution units):
    output logic [NUM_PORTS-1:0]                          issue_valid,
    output logic [NUM_PORTS-1:0][$clog2(DEPTH)-1:0]       issue_idx,
    output logic [NUM_PORTS-1:0][TAG_WIDTH-1:0]           issue_dst_tag,
    output logic [NUM_PORTS-1:0][AGE_WIDTH-1:0]           issue_age,

    // Squash inputs:
    // squash_en  : active-high, a branch misprediction occurred this cycle.
    // squash_seq : dispatch sequence number of the mispredicted branch.
    //              Entries with disp_seq > squash_seq are flushed.
    input  logic                               squash_en,
    input  logic [15:0]                        squash_seq
);

    localparam int unsigned IDX_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH);

    // =========================================================================
    // Internal wires
    // =========================================================================

    // Per-entry state from the wakeup CAM.
    iq_pkg::iq_entry_t  entry_array [DEPTH];  // Array holding the full state (struct) of every entry in the queue
    logic [DEPTH-1:0]   ready_array;          // Bitvector where bit i=1 if entry i is valid and all its sources are ready

    // Selector outputs.
    logic [NUM_PORTS-1:0]                  sel_grant; // High if the respective port has granted an instruction for issue
    logic [NUM_PORTS-1:0][IDX_W-1:0]       sel_idx;   // The slot index of the instruction selected by each port
    logic [NUM_PORTS-1:0][TAG_WIDTH-1:0]   sel_tag;   // The destination tag of the instruction selected by each port
    logic [NUM_PORTS-1:0][AGE_WIDTH-1:0]   sel_age;   // The age of the instruction selected by each port

    // =========================================================================
    // Free-slot allocator (priority encoder)
    // =========================================================================
    // free_vec[i] = 1 means entry i is available for dispatch. Updated
    // each cycle based on dispatch (consumes a slot) and issue/squash
    // (frees slots). The priority encoder finds the lowest-indexed 1-bit.

    logic [DEPTH-1:0] free_vec;     // Bitvector tracking availability of IQ slots (1 = free/invalid, 0 = occupied)
    logic [IDX_W-1:0] alloc_idx;    // lowest free slot index, output from the priority encoder
    logic             has_free;     // at least one slot is free, indicated by reduction OR of free_vec

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

    // =========================================================================
    // Global dispatch sequence counter
    // =========================================================================
    // Monotonically increasing 16-bit counter, incremented once per accepted
    // dispatch. Each dispatched instruction stores this value as its disp_seq,
    // establishing a total order among all dispatched instructions. This is
    // the key to correct squash: comparing disp_seq against the branch's
    // sequence number tells us unambiguously whether an entry is younger.
    //
    // The counter is NOT reset on squash — only on full pipeline reset.
    // This preserves ordering for surviving entries across partial flushes.
    logic [15:0] disp_seq_r; // 16-bit monotonic sequence counter to maintain global dispatch order for squashing

    always_ff @(posedge clk or negedge rst_n) begin : disp_seq_counter
        if (!rst_n)
            disp_seq_r <= '0;
        else if (dispatch_accepted)
            disp_seq_r <= disp_seq_r + 16'd1;
    end

    // Free-vector update: sequential logic maintaining the allocation state.
    // Four events modify free_vec:
    //   1. Reset      → all slots free.
    //   2. Issue      → issued slot(s) become free (set bit).
    //   3. Squash     → squashed slot(s) become free.
    //   4. Dispatch   → allocated slot becomes occupied (clear bit).
    always_ff @(posedge clk or negedge rst_n) begin : free_vec_update
        if (!rst_n) begin
            free_vec <= '1;    // all slots free on reset (DEPTH ones)
        end else begin
            // Step 1: free slots that were just issued.
            for (int p = 0; p < NUM_PORTS; p++) begin
                if (sel_grant[p])
                    free_vec[sel_idx[p]] <= 1'b1;
            end

            // Step 2: free slots whose entries are being squashed.
            // The CAM computes per-entry squash_clear_oh based on disp_seq
            // comparison. We mirror that logic here so free_vec stays in sync.
            if (squash_en) begin
                for (int i = 0; i < DEPTH; i++) begin
                    if (entry_array[i].valid && (entry_array[i].disp_seq > squash_seq))
                        free_vec[i] <= 1'b1;
                end
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
        .dispatch_disp_seq (disp_seq_r),

        .wakeup_valid      (wakeup_valid),
        .wakeup_tag        (wakeup_tag),
        .spec_wakeup_valid (spec_wakeup_valid),
        .spec_wakeup_tag   (spec_wakeup_tag),

        .issue_grant       (sel_grant),
        .issue_idx         (sel_idx),

        .squash_en         (squash_en),
        .squash_seq        (squash_seq),

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
