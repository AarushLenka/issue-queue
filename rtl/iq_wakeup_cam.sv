// =============================================================================
// iq_wakeup_cam.sv — Wakeup CAM: Broadcast-Match Array
// =============================================================================
// Purpose:
//   This module instantiates DEPTH iq_entry modules and fans the wakeup bus
//   (wakeup_valid + wakeup_tag) to ALL of them in parallel. Every entry
//   performs its own tag comparison independently.
//
// What this module actually does:
//   1. Instantiates DEPTH iq_entry modules (the "entry array").
//   2. Fans the global wakeup bus to all entries (broadcast).
//   3. Fans dispatch signals to the entry selected by dispatch_slot_idx.
//   4. Fans issue_clear to entries selected by the selector grants.
//   5. Exports per-entry state (entry_o[], ready_o[]) upward to the selector.
// =============================================================================

`ifndef IQ_WAKEUP_CAM_SV
`define IQ_WAKEUP_CAM_SV

`include "iq_pkg.sv"

module iq_wakeup_cam #(
    parameter int unsigned DEPTH     = iq_pkg::DEPTH,
    parameter int unsigned TAG_WIDTH = iq_pkg::TAG_WIDTH,
    parameter int unsigned NUM_SRC   = iq_pkg::NUM_SRC,
    parameter int unsigned AGE_WIDTH = iq_pkg::AGE_WIDTH,
    parameter int unsigned NUM_PORTS = iq_pkg::NUM_PORTS
)(
    input  logic                               clk,
    input  logic                               rst_n,

    // --- Dispatch (from the free-slot allocator in iq_top) ------------------
    // dispatch_valid: a new instruction is being dispatched this cycle.
    // dispatch_slot_idx: which physical entry slot to write into.
    // The allocator guarantees dispatch_slot_idx points to an invalid (free)
    // entry, unless dispatch_valid is 0 (in which case the idx is don't-care).
    input  logic                               dispatch_valid,
    input  logic [$clog2(DEPTH)-1:0]           dispatch_slot_idx,
    input  logic [TAG_WIDTH-1:0]               dispatch_dst_tag,
    input  logic [NUM_SRC-1:0][TAG_WIDTH-1:0]  dispatch_src_tag,
    input  logic [NUM_SRC-1:0]                 dispatch_src_imm,
    input  logic [15:0]                        dispatch_disp_seq,

    // --- Wakeup broadcast (from execution writeback) ------------------------
    // One bus for now; extending to multiple buses is a parameter change plus
    // widening these two signals into arrays — the per-entry comparator loop
    // already handles one bus, and a second bus just adds a second hit-OR term.
    input  logic                               wakeup_valid,
    input  logic [TAG_WIDTH-1:0]               wakeup_tag,
    input  logic                               spec_wakeup_valid,
    input  logic [TAG_WIDTH-1:0]               spec_wakeup_tag,

    // --- Issue clear (from the selector in iq_top) --------------------------
    // NUM_PORTS parallel issue grants. issue_grant[p]=1 means port p has
    // selected entry issue_idx[p] for issuance; that entry must be cleared.
    input  logic [NUM_PORTS-1:0]                        issue_grant,
    input  logic [NUM_PORTS-1:0][$clog2(DEPTH)-1:0]     issue_idx,

    // --- Squash (age-threshold based) ----------------------------------------
    // squash_en : active-high, a branch misprediction occurred.
    // squash_seq: dispatch sequence number of the mispredicted branch.
    //            All entries with disp_seq > squash_seq are younger than the
    //            misprediction and must be flushed. Entries with disp_seq <=
    //            squash_seq are older (dispatched before the branch) and survive.
    input  logic                               squash_en,
    input  logic [15:0]                        squash_seq,

    // --- Per-entry state (read by the selector every cycle) -----------------
    // Packed arrays: entry_array_o[i] is the full struct for entry i,
    // ready_array_o[i] is the combinational is_ready() for entry i.
    output iq_pkg::iq_entry_t                  entry_array_o [DEPTH],
    output logic [DEPTH-1:0]                   ready_array_o
);

    // =========================================================================
    // Derived one-hot decode signals
    // =========================================================================
    // We pre-decode dispatch_slot_idx and issue_idx into one-hot vectors so
    // each entry's dispatch_we and issue_clear are simple single-bit lookups.
    // This avoids DEPTH separate (idx == i) comparisons per entry, replacing
    // them with one shared decoder + per-entry bit-select — fewer gates and
    // shorter critical path.

    // Dispatch write-enable: one-hot, bit i = 1 means entry i is the target.
    logic [DEPTH-1:0] dispatch_we_oh; // One-hot vector identifying the specific IQ slot being written to this cycle

    always_comb begin : dispatch_decode
        dispatch_we_oh = '0;
        if (dispatch_valid)
            dispatch_we_oh[dispatch_slot_idx] = 1'b1;
    end

    // Issue clear: OR-reduction across all ports. An entry can be issued by
    // at most one port per cycle (enforced by the selector's mutual-exclusion
    // logic in Step 3), but we OR all ports' contributions here defensively.
    // OR all ports' contributions here defensively.
    // If port p selects entry i, issue_clear_oh[i] goes high.
    logic [DEPTH-1:0] issue_clear_oh; // One-hot (or multi-hot) vector indicating which entries are being issued and thus cleared

    always_comb begin : issue_decode
        issue_clear_oh = '0;
        for (int p = 0; p < NUM_PORTS; p++) begin
            if (issue_grant[p])
                issue_clear_oh[issue_idx[p]] = 1'b1;
        end
    end

    // =========================================================================
    // Per-entry squash comparison
    // =========================================================================
    // Each entry stores its disp_seq at dispatch time. On squash, we compare:
    //   squash_clear = squash_en && (entry.disp_seq > squash_seq)
    // This correctly identifies entries dispatched after the branch.
    // =========================================================================
    logic [DEPTH-1:0] squash_clear_oh; // Bitvector indicating which entries are younger than the mispredicted branch and must be flushed

    always_comb begin : squash_decode
        for (int i = 0; i < DEPTH; i++) begin
            // Squash entries dispatched AFTER the mispredicted branch.
            // entry_array_o is combinational from entry_r, so we can read
            // disp_seq directly. Only valid entries can be squashed.
            squash_clear_oh[i] = squash_en
                               && entry_array_o[i].valid
                               && (entry_array_o[i].disp_seq > squash_seq);
        end
    end

    // =========================================================================
    // Entry array instantiation
    // =========================================================================
    // Each entry receives:
    //   - dispatch_we from the one-hot decode (only ONE entry gets we=1)
    //   - the SAME dispatch payload (dst_tag, src_tag, src_imm)
    //   - the SAME wakeup bus (broadcast)
    //   - issue_clear from the issue one-hot decode
    //   - squash_clear per-entry from squash_clear_oh
    // =========================================================================

    genvar gi; // Generate variable used to stamp out DEPTH instances of iq_entry at elaboration time
    generate
        for (gi = 0; gi < DEPTH; gi++) begin : gen_entry
            iq_entry #(
                .TAG_WIDTH (TAG_WIDTH),
                .NUM_SRC   (NUM_SRC),
                .AGE_WIDTH (AGE_WIDTH)
            ) u_entry (
                .clk              (clk),
                .rst_n            (rst_n),

                // Dispatch: only entry gi latches when dispatch_we_oh[gi]=1.
                // All entries see the same payload, but only the selected one
                // writes — classic "broadcast data, point-to-point enable" pattern.
                .dispatch_we      (dispatch_we_oh[gi]),
                .dispatch_dst_tag (dispatch_dst_tag),
                .dispatch_src_tag (dispatch_src_tag),
                .dispatch_src_imm (dispatch_src_imm),
                .dispatch_disp_seq(dispatch_disp_seq),

                // Wakeup: TRUE broadcast — every entry gets the same bus.
                // This is the distributed CAM in action: the bus fans out,
                // and each entry's local comparators decide independently
                // whether to set their src_ready bits. No central arbiter.
                .wakeup_valid     (wakeup_valid),
                .wakeup_tag       (wakeup_tag),
                .spec_wakeup_valid(spec_wakeup_valid),
                .spec_wakeup_tag  (spec_wakeup_tag),

                // Clear signals: per-entry from the one-hot decodes.
                .issue_clear      (issue_clear_oh[gi]),
                .squash_clear     (squash_clear_oh[gi]),  // per-entry: only younger-than-branch

                // State output: feeds the selector (Step 3) and debug.
                .entry_o          (entry_array_o[gi]),
                .ready_o          (ready_array_o[gi])
            );
        end
    endgenerate

endmodule : iq_wakeup_cam

`endif // IQ_WAKEUP_CAM_SV
