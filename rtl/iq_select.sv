// =============================================================================
// iq_select.sv — Age-Ordered Multi-Port Selector (Step 3)
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
//
// =============================================================================
// DESIGN DECISION: PRIORITY-TREE vs. AGE-MATRIX (INTERVIEW Q&A)
// =============================================================================
//
// The two classic approaches for oldest-first selection in an issue queue:
//
// --- APPROACH A: PRIORITY-TREE COMPARATOR (what we implement) ---------------
//   Walk a pairwise reduction tree across all DEPTH entries. At each node,
//   compare two candidates' ages and pass the older one up. The tree root
//   is the globally-oldest ready entry. Depth = ceil(log2(DEPTH)) levels
//   of 2:1 age-comparator + mux.
//
//   For DEPTH=16: 4 levels, 15 comparators total (a binary tree of 16 leaves
//   has 15 internal nodes). Each comparator is an AGE_WIDTH-bit magnitude
//   compare — about 2×AGE_WIDTH gates. Total ≈ 15 × 2×4 = 120 gates for
//   the age comparison, plus 15 muxes for the index forwarding.
//
//   Pros:
//     - Simple to implement and understand — it's just a tournament bracket.
//     - Combinational delay is O(log(DEPTH)) — scales well for timing.
//     - Stateless: no bookkeeping to maintain across cycles.
//
//   Cons:
//     - Must recompute the entire tree from scratch every cycle, even if
//       only one entry changed. Wasted work if the queue is mostly stable.
//     - Multi-port extension requires masking and re-running (see Step 3b).
//
// --- APPROACH B: AGE-MATRIX (documented, not implemented) -------------------
//   Maintain a DEPTH×DEPTH matrix M where M[i][j] = 1 iff entry i is older
//   than entry j. Updated incrementally:
//     - On dispatch of entry k: set M[k][*] = 0 (k is youngest vs. everyone),
//       set M[*][k] = 1 (everyone is older than k).
//     - On issue of entry k: clear row k and column k.
//
//   To find the oldest ready entry: for each ready entry i, AND-reduce
//   row M[i][*] masked with valid bits. If all bits are 1, entry i is
//   older than every other valid entry → it wins.
//
//   Pros:
//     - Incremental update: the matrix is maintained cycle-over-cycle with
//       O(DEPTH) writes per dispatch/issue, NOT recomputed from scratch.
//     - Selection is a simple row AND-reduce + priority encode — no
//       deep comparison tree.
//     - Multi-port: mask out the first winner's column and re-AND-reduce
//       for the next port (one extra gate delay per port, not a full retree).
//
//   Cons:
//     - Storage: DEPTH² flip-flops for the matrix. DEPTH=16 → 256 FFs.
//       DEPTH=64 → 4096 FFs. That's expensive in area for a small block.
//     - Update logic: each dispatch/issue writes an entire row AND column —
//       O(DEPTH) muxes on every matrix element. Routing congestion.
//     - Harder to reason about correctness (is the matrix always consistent
//       after a squash? after a same-cycle dispatch+issue?).
//
//   DECISION: Priority-tree (Approach A). At DEPTH≤32, the log2 timing and
//   ~30 comparators are well within budget. The age-matrix becomes attractive
//   only at DEPTH≥64 where the tree depth (6+ levels) starts to hurt cycle
//   time, but the FF overhead is severe. For this project's scope, the tree
//   is simpler to verify and explain. If asked in an interview: "I know the
//   age-matrix alternative, here's the tradeoff, and I chose the tree because
//   it's simpler at this queue depth."
//
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
    // Sub-step 3a: Single-port oldest-ready selection (priority-tree)
    // =========================================================================
    // The tree compares pairs of entries bottom-up. At each node, the older
    // (higher age) entry wins. If ages are equal, the LOWER INDEX wins —
    // this is a deterministic tie-break that prevents starvation when two
    // entries are dispatched in the same cycle (same starting age).
    //
    // The tree is implemented as a function so it can be called once per port
    // with a different ready-mask (see Sub-step 3b for multi-port masking).
    //
    // Returns {found, winner_idx} packed into IDX_W+1 bits.
    // found=1 means at least one ready entry exists; winner_idx is its index.

    // Internal struct to carry a candidate through the tree. Not in the package
    // because it's local to the selector's implementation detail.
    typedef struct packed {
        logic                valid;         // is this candidate real?
        logic [IDX_W-1:0]   idx;           // which entry
        logic [AGE_WIDTH-1:0] age;          // for comparison
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
        localparam int unsigned TREE_SIZE = 32;  // must be >= DEPTH and a power of 2

        candidate_t tree [TREE_SIZE];
        int half;

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
    // Sub-step 3b: Multi-port mutual exclusion
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
    //
    // -------------------------------------------------------------------------
    // FAIRNESS CAVEAT (INTERVIEW TALKING POINT):
    //   Port 0 ALWAYS gets first pick (the globally-oldest ready entry).
    //   Port 1 gets what's left. This means port 0 has PRIORITY over port 1.
    //
    //   Why this is usually acceptable:
    //     - In real cores, different ports map to different execution unit TYPES
    //       (e.g. port 0 = ALU, port 1 = load/store). An ALU instruction and
    //       a load instruction don't compete — they go to different ports by
    //       type. The "unfairness" only matters when two instructions of the
    //       SAME type are both ready, and even then the age-ordering within
    //       each port prevents starvation (the overlooked entry just gets
    //       older and wins next cycle).
    //     - Making ports truly FAIR (e.g. rotating which port picks first)
    //       adds a mux on the mask chain and complicates timing. Not worth it
    //       for the common case where port types don't overlap.
    //
    //   If you're asked "what if both ports serve the same unit type?":
    //     Acknowledge the unfairness, note that age-ordering still prevents
    //     starvation (just adds one cycle of latency to the second-oldest
    //     instruction), and mention the rotating-priority extension as a
    //     known fix if needed.
    // -------------------------------------------------------------------------

    // The mask chain and per-port selection are computed in one always_comb
    // block so the synthesis tool can see the full combinational cone and
    // optimize across ports.
    always_comb begin : multi_port_select
        // Per-port local variables. `automatic` is implicit inside always_comb
        // for SystemVerilog, but we declare them at the top for clarity.
        logic [DEPTH-1:0] current_mask;
        candidate_t       winner;

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
