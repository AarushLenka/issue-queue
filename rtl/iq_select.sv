// =============================================================================
// iq_select.sv — Age-Ordered Multi-Port Selector
// =============================================================================
// Purpose:
//   Given DEPTH entries with per-entry ready_i[] bits and age fields, select
//   up to NUM_PORTS entries for issuance each cycle, obeying:
//     1. Only READY entries are eligible (valid AND all sources ready).
//     2. Among ready entries, the OLDEST (highest age counter) wins.
//     3. No two ports select the same entry (mutual exclusion).
//     4. If fewer entries are ready than ports, excess ports get grant=0.
//
//   This is pure combinational logic — no state, no clock. It is called
//   every cycle by iq_top, which feeds the results into the entry array
//   as issue_clear signals.
// =============================================================================

`ifndef IQ_SELECT_SV
`define IQ_SELECT_SV

`include "iq_pkg.sv"

module iq_select #(
    parameter int unsigned DEPTH     = iq_pkg::DEPTH,
    parameter int unsigned AGE_WIDTH = iq_pkg::AGE_WIDTH,
    parameter int unsigned NUM_PORTS = iq_pkg::NUM_PORTS,
    parameter int unsigned TAG_WIDTH = iq_pkg::TAG_WIDTH
)(
    // --- Per-entry inputs from the wakeup CAM --------------------------------
    input  iq_pkg::iq_entry_t           entry_i [DEPTH],
    input  logic [DEPTH-1:0]            ready_i,

    // --- Per-port grant outputs to iq_top ------------------------------------
    // grant_o[p]   : port p found a ready entry to issue.
    // grant_idx_o[p]: which entry index port p selected.
    // grant_tag_o[p]: the dst_tag of the selected entry (forwarded to the
    //                 issue bus so the execution unit knows which tag to
    //                 broadcast on its wakeup bus after completing).
    // grant_age_o[p]: age of the selected entry (debug/waveform use).
    output logic [NUM_PORTS-1:0]                          grant_o,
    output logic [NUM_PORTS-1:0][$clog2(DEPTH)-1:0]       grant_idx_o,
    output logic [NUM_PORTS-1:0][TAG_WIDTH-1:0]           grant_tag_o,
    output logic [NUM_PORTS-1:0][AGE_WIDTH-1:0]           grant_age_o
);

    localparam int unsigned IDX_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH);

    // =========================================================================
    // Single-port oldest-ready selection (priority-tree)
    // =========================================================================
    // The tree compares pairs of entries bottom-up. At each node, the older
    // (higher age) entry wins. If ages are equal, the LOWER INDEX wins —
    // this is a deterministic tie-break that prevents starvation when two
    // entries are dispatched in the same cycle (same starting age).
    //
    // The tree is implemented as a function so it can be called once per port
    // with a different ready-mask.
    //
    // Returns {found, winner_idx} packed into IDX_W+1 bits.
    // found=1 means at least one ready entry exists; winner_idx is its index.

    // Internal struct to carry a candidate through the tree. Not in the package
    // because it's local to the selector's implementation detail.
    typedef struct packed {
        logic                valid;         // 1 if this candidate represents a real, ready instruction; 0 if padding or invalid
        logic [IDX_W-1:0]   idx;           // the physical slot index of this instruction in the issue queue
        logic [AGE_WIDTH-1:0] age;          // the age counter used to prioritize older instructions during selection
    } candidate_t;

    // pick_older: the pairwise comparator node. Given two candidates, return
    // the one that should win the tournament bracket.
    //
    // Rules (in priority order):
    //   1. If only one is valid, it wins trivially.
    //   2. If both are valid, the one with HIGHER age wins (older = issued first).
    //   3. If ages are equal, the one with LOWER index wins (deterministic
    //      tie-break — prevents starvation, gives a predictable debug trace).
    function automatic candidate_t pick_older(input candidate_t a,
                                               input candidate_t b);
        if (!a.valid && !b.valid) begin
            // Neither candidate is real — propagate an invalid candidate.
            pick_older = '0;
        end else if (!b.valid) begin
            pick_older = a;
        end else if (!a.valid) begin
            pick_older = b;
        end else begin
            // Both valid: compare ages. Higher age = older = winner.
            // Tie-break: lower index wins (a.idx < b.idx by construction
            // in our bottom-up tree, so a wins ties — this is the "lower
            // index priority" convention).
            if (iq_pkg::age_older_than(a.age, b.age))
                pick_older = a;       // a is strictly older
            else if (iq_pkg::age_older_than(b.age, a.age))
                pick_older = b;       // b is strictly older
            else
                pick_older = (a.idx <= b.idx) ? a : b;  // equal age: lower idx
        end
    endfunction

    // find_oldest_ready: run the full priority tree over DEPTH entries,
    // considering only entries whose bit is set in `mask`. Returns the
    // winning candidate (valid=0 if no ready entry exists in mask).
    //
    // Implementation: iterative tree reduction using a power-of-2 padded
    // array. We pad DEPTH up to the next power of 2, fill unused leaves
    // with invalid candidates, then reduce pairwise in log2 steps.
    function automatic candidate_t find_oldest_ready(
        input iq_pkg::iq_entry_t entry_arr [DEPTH],
        input logic [DEPTH-1:0]  mask
    );
        // Pad to next power of 2. localparam can't be used inside a function
        // in all tools, so we use a hardcoded max (32 is enough for DEPTH≤32).
        // For DEPTH>32, increase this. The unused slots are filled with
        // invalid candidates and don't affect the result — they lose every
        // comparison.
        localparam int unsigned TREE_SIZE = 32;  // Size of the binary tree array; must be >= DEPTH and a power of 2 for complete reduction

        candidate_t tree [TREE_SIZE]; // Array of candidates forming the tournament bracket nodes
        int half; // Variable to control the reduction loop by halving the active tree size per level

        // Initialize leaves: real entries from the mask, padding with invalids.
        for (int i = 0; i < TREE_SIZE; i++) begin
            if (i < DEPTH && mask[i]) begin
                tree[i].valid = 1'b1;
                tree[i].idx   = i[IDX_W-1:0];
                tree[i].age   = entry_arr[i].age;
            end else begin
                tree[i] = '0;     // invalid candidate
            end
        end

        // Reduce: pairwise comparison, halving the array each level.
        // Level 0: 32→16, Level 1: 16→8, ..., Level 4: 2→1.
        // This is log2(TREE_SIZE) = 5 levels of comparison.
        half = TREE_SIZE;
        while (half > 1) begin
            half = half / 2;
            for (int i = 0; i < half; i++) begin
                tree[i] = pick_older(tree[2*i], tree[2*i+1]);
            end
        end

        return tree[0];   // the tournament winner (or invalid if none ready)
    endfunction

    // =========================================================================
    // Multi-port mutual exclusion
    // =========================================================================
    // For NUM_PORTS issue ports, we run the selection tree NUM_PORTS times.
    // After port p finds its winner, we MASK OUT that entry for port p+1:
    //
    //   ready_mask_0 = ready_i                       (all ready entries)
    //   winner_0     = find_oldest_ready(ready_mask_0)
    //   ready_mask_1 = ready_mask_0 & ~(1 << winner_0.idx)
    //   winner_1     = find_oldest_ready(ready_mask_1)
    //   ...
    //
    // This guarantees mutual exclusion: no two ports select the same entry,
    // because each subsequent port can't see the previous winner.


    // The mask chain and per-port selection are computed in one always_comb
    // block so the synthesis tool can see the full combinational cone and
    // optimize across ports.
    always_comb begin : multi_port_select
        // Per-port local variables. `automatic` is implicit inside always_comb
        // for SystemVerilog, but we declare them at the top for clarity.
        logic [DEPTH-1:0] current_mask; // Bitmask of which entries are still eligible to be selected (1=ready and not yet granted)
        candidate_t       winner;       // The candidate selected by the priority tree for the current port

        // Start with all ready entries eligible.
        current_mask = ready_i;

        for (int p = 0; p < NUM_PORTS; p++) begin
            // Run the priority tree on the current mask.
            winner = find_oldest_ready(entry_i, current_mask);

            grant_o[p]     = winner.valid;
            grant_idx_o[p] = winner.idx;

            // Forward the selected entry's dst_tag and age to the issue bus.
            if (winner.valid) begin
                grant_tag_o[p] = entry_i[winner.idx].dst_tag;
                grant_age_o[p] = entry_i[winner.idx].age;
            end else begin
                grant_tag_o[p] = '0;
                grant_age_o[p] = '0;
            end

            // Mask out the winner so the next port can't pick it.
            // If no winner (grant=0), mask stays unchanged — harmless.
            if (winner.valid) begin
                current_mask[winner.idx] = 1'b0;
            end
        end
    end

endmodule : iq_select

`endif // IQ_SELECT_SV
