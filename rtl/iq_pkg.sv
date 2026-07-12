// =============================================================================
// iq_pkg.sv — Issue Queue Package
// =============================================================================
// Purpose:
//   Central package holding all type definitions, constants, and helper
//   tasks/functions used across the issue queue RTL. Placing these in a
//   package lets every module (entry, wakeup CAM, selector, top, TB, SVA)
//   import the same definitions without re-declaring them.
//
//   This is your first exposure to a SystemVerilog `package`. A package is
//   a namespace for declarations that exist in elaboration scope globally,
//   so you don't have to thread parameters through every `*.sv` file by
//   hand. Every module that uses these types will include:
//       `include "iq_pkg.sv"`  OR  import iq_pkg::*;  inside the module.
// =============================================================================

`ifndef IQ_PKG_SV
`define IQ_PKG_SV

package iq_pkg;

  // ---------------------------------------------------------------------------
  // Parameter defaults
  // ---------------------------------------------------------------------------
  // TAG_WIDTH : width of the architectural destination tag used for wakeup.
  //             Larger tags support more in-flight instructions but cost more
  //             comparator area in the wakeup CAM. 6 bits = 64 in-flight, a
  //             reasonable starting point for a small out-of-order core.
  // NUM_SRC   : maximum number of source operands per entry. Most RISC ISAs
  //             cap at 3 (e.g. RISC-V `rd = rs1 OP rs2`, plus a load/store
  //             base+offset use case). Used to size src_tag[] and src_ready[].
  // DEPTH     : number of entries in the issue queue. Real cores use 32-128;
  //             we keep it parameterizable so testbenches can scale down.
  // NUM_PORTS : number of issue ports (max instructions issued per cycle).
  //             2 ports is a common minimum (one ALU + one load/store).
  // AGE_WIDTH : width of the per-entry age counter. Explained in detail
  //             below — this is a deliberate design decision.
  // ---------------------------------------------------------------------------
  parameter int unsigned TAG_WIDTH = 6;
  parameter int unsigned NUM_SRC   = 2;
  parameter int unsigned DEPTH     = 16;
  parameter int unsigned NUM_PORTS = 2;

  // ---------------------------------------------------------------------------
  // AGE_WIDTH sizing decision — INTERVIEW Q&A WORTHY
  // ---------------------------------------------------------------------------
  // The age counter tells "how old is this entry relative to its neighbors?"
  // for age-ordered arbitration (oldest-ready wins). The question is whether
  // to use a SATURATING counter or a WRAPPING (modular) counter.
  //
  // SATURATING (what we use, AGE_WIDTH = DEPTH):
  //   - Counter starts at 0, increments each cycle, HITS A MAX at (2^AGE_WIDTH)-1
  //     and stays there.
  //   - At any moment, "older" means lower-count-or-saturated-too.
  //     We compare with an OR-reduction: (a.age == SAT) | (b.age < a.age).
  //   - Advantage: monotonic interpretation per entry — once saturated, an
  //     entry is provably the oldest contender forever, which simplifies
  //     multi-port fairness arguments.
  //   - Cost: a saturating adder per entry per cycle → cheap, but uses more
  //     cells than a wrapping counter.
  //
  // WRAPPING (alternative, AGE_WIDTH = $clog2(DEPTH+1)):
  //   - Counter just wraps. "Older" becomes ambiguous when both entries have
  //     wrapped; you'd need a separate "I have wrapped" sticky bit per entry
  //     and a careful tie-break rule.
  //   - Advantage: smaller counter area.
  //   - Cost: extra wrapper logic, harder to argue correctness in interview.
  //
  // DECISION: saturating. Depth=16 → AGE_WIDTH=4 bits is plenty (counter
  // counts microseconds in real terms at GHz). If you deepen the queue to
  // say 64, AGE_WIDTH naturally grows to 6 bits — same rule.
  // ---------------------------------------------------------------------------
  parameter int unsigned AGE_WIDTH = (DEPTH <= 16) ? 4
                                   : (DEPTH <= 256) ? 8
                                   : 12;

  // Local parameter derived from AGE_WIDTH for use inside expressions.
  localparam logic [AGE_WIDTH-1:0] AGE_SAT_MAX = '1;  // all-ones = saturated

  // ---------------------------------------------------------------------------
  // Packed struct: one issue-queue entry's payload
  // ---------------------------------------------------------------------------
  // In SystemVerilog, a `struct` inside a package becomes a single type
  // you can use as one signal. When you pack it (`packed struct`), the
  // fields are concatenated into one bit-vector so it can be assigned
  // and stored as a regular logic value (e.g. in an array of regs).
  //
  // Why a packed struct instead of separate logic vectors per field?
  //   - One storage element per entry (one always_ff block drives all fields).
  //   - Assignment with `{...}` literal is concise and synthesis-friendly.
  //   - Easy to extend with new fields later without rewiring every module.
  //
  // Field semantics:
  //   dst_tag    : tag broadcast on the wakeup bus when this entry issues.
  //                Sleepers holding this tag in their src_tag[] will wake up.
  //   src_tag[]  : operand source tags. Each entry depends on the producer
  //                with that tag. Slot is "ready" only when src_ready[i]=1.
  //   src_ready[]: per-source ready bits, updated by the wakeup CAM each
  //                cycle. AND-reduced with `valid` form the "ready to issue"
  //                predicate.
  //   valid      : entry is live. Cleared on issue or squash.
  //   age        : saturating counter described above; used by the selector.
  //   disp_seq   : monotonic dispatch sequence number (added in Step 5 for
  //                squash comparison — see CLAUDE.md notes on monotonicity).
  //                Declared here so the struct shape is stable across steps.
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic [TAG_WIDTH-1:0]        dst_tag;
    logic [NUM_SRC-1:0][TAG_WIDTH-1:0] src_tag;
    logic [NUM_SRC-1:0]          src_ready;
    logic                        valid;
    logic [AGE_WIDTH-1:0]        age;
    logic [15:0]                 disp_seq;   // 16-bit dispatch sequence (Step 5)
  } iq_entry_t;

  // ---------------------------------------------------------------------------
  // Helper: "is entry `a` older-or-equal than entry `b`?"
  // ---------------------------------------------------------------------------
  // Returns 1 if `a` should be considered strictly older than `b` for
  // arbitration purposes. Modelled after the saturating-age scheme:
  //   - If `a` is saturated, `a` is older than any non-saturated `b`.
  //   - Otherwise, lower raw age wins.
  //
  // We intentionally do NOT say "equal age" — in a tied-age worst case
  // the selector breaks ties by lower index, which is handled there.
  // ---------------------------------------------------------------------------
  function automatic logic age_older_than(input logic [AGE_WIDTH-1:0] a,
                                           input logic [AGE_WIDTH-1:0] b);
    return (a == AGE_SAT_MAX) | (a < b);
  endfunction

  // ---------------------------------------------------------------------------
  // Helper: ready-to-issue predicate
  // ---------------------------------------------------------------------------
  // A entry is issue-able when valid AND all sources' src_ready bits are set.
  // Combinational; selector queries this every cycle.
  // ---------------------------------------------------------------------------
  function automatic logic is_ready(input iq_entry_t e);

    // AND-reduction — &src_ready is 1 iff every bit is set.
    return e.valid & (&e.src_ready);
  endfunction

endpackage : iq_pkg

`endif // IQ_PKG_SV
