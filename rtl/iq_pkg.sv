// =============================================================================
// iq_pkg.sv — Issue Queue Package
// =============================================================================
// Purpose:
//   Central package holding all type definitions, constants, and helper
//   tasks/functions used across the issue queue RTL.
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
  parameter int unsigned TAG_WIDTH = 6;  // 6-bit tag width for addressing up to 64 in-flight instruction destinations
  parameter int unsigned NUM_SRC   = 2;  // Maximum 2 source operands per instruction (e.g., rs1 and rs2)
  parameter int unsigned DEPTH     = 16; // 16 entries in the issue queue available for dispatch
  parameter int unsigned NUM_PORTS = 2;  // 2 parallel execution ports available for issuing ready instructions

  // ---------------------------------------------------------------------------
  parameter int unsigned AGE_WIDTH = (DEPTH <= 16) ? 4   // Use 4 bits for age if queue depth is 16 or fewer
                                   : (DEPTH <= 256) ? 8  // Scale to 8 bits for age if depth is up to 256
                                   : 12;                 // Use 12 bits for very deep queues to prevent frequent saturation

  // Local parameter derived from AGE_WIDTH for use inside expressions.
  localparam logic [AGE_WIDTH-1:0] AGE_SAT_MAX = '1;  // all-ones = saturated


  // ---------------------------------------------------------------------------
  // Packed struct: one issue-queue entry's payload
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic [TAG_WIDTH-1:0]        dst_tag;    // Tag broadcasted on the wakeup bus when this instruction completes
    logic [NUM_SRC-1:0][TAG_WIDTH-1:0] src_tag;    // Tags of the producer instructions this entry depends on
    logic [NUM_SRC-1:0]          src_ready;  // One-hot ready status per source operand (1 = data is available)
    logic                        valid;      // Indicates if this issue queue slot holds a live, undispatched instruction
    logic [AGE_WIDTH-1:0]        age;        // Tracks cycles since dispatch for oldest-first arbitration
    logic [15:0]                 disp_seq;   // 16-bit monotonic sequence number to determine relative dispatch order for flushing
  } iq_entry_t;                              // Structure representing a single instruction's state in the queue

  // ---------------------------------------------------------------------------
  // Helper: "is entry with age `a` strictly older than entry with age `b`?"
  // Age starts at 0 on dispatch and increments each cycle.
  // ---------------------------------------------------------------------------
  function automatic logic age_older_than(input logic [AGE_WIDTH-1:0] a,
                                           input logic [AGE_WIDTH-1:0] b);
    return (a > b);  // Returns 1 if entry 'a' has a higher age counter (older) than entry 'b'
  endfunction

  // ---------------------------------------------------------------------------
  // Helper: ready-to-issue predicate
  // ---------------------------------------------------------------------------
  // A entry is issue-able when valid AND all sources' src_ready bits are set.
  // Combinational; selector queries this every cycle.
  // ---------------------------------------------------------------------------
  function automatic logic is_ready(input iq_entry_t e);

    // AND-reduction — &src_ready is 1 iff every bit is set.
    return e.valid & (&e.src_ready);  // Ready to issue only if entry is valid and all required source operands are ready
  endfunction

endpackage : iq_pkg

`endif // IQ_PKG_SV
