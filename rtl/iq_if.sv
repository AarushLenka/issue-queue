// =============================================================================
// iq_if.sv — Issue Queue Bus Interface
// =============================================================================
// Purpose:
//   One SystemVerilog `interface` groups every wire connecting the issue
//   queue to its three neighbors:
//     1. Dispatch unit (writes new entries into the queue)
//     2. Execution/writeback (broadcasts wakeup tags)
//     3. Execution units (read issued instructions)
//
//   Each neighbor sees the bundle through a `modport` — a customized view
//   that lists only the signals that neighbor is allowed to touch, with
//   directions fixed from THAT neighbor's perspective.
//
//   This makes the bus contract unambiguous at the type level: a module
//   declared with `dispatch_mp vif` literally cannot drive a wakeup signal
//   by accident. Compile-time error > runtime X-prop.
//
// This is your first real exposure to SystemVerilog interfaces and modports.
// Comments call out each new construct the first time it appears.
// =============================================================================

`ifndef IQ_IF_SV
`define IQ_IF_SV

// WHAT IS AN INTERFACE: a named bundle of signals + (optionally) modports,
// clocking blocks, and assertions that travel together. You `instantiate` it
// once and pass the whole handle to every connected module, instead of
// re-declaring each wire in every port list of every module.
//
// We pull TYPE parameters (TAG_WIDTH, NUM_SRC, NUM_PORTS) from `iq_pkg`.
// DEPTH is taken explicitly because the interface allocates index buses
// sized by DEPTH (issue_idx, dispatch_slot_idx), and most testbenches want
// to override DEPTH without rebuilding the package.

interface iq_if #(
    parameter int unsigned DEPTH     = iq_pkg::DEPTH,
    parameter int unsigned TAG_WIDTH = iq_pkg::TAG_WIDTH,
    parameter int unsigned NUM_SRC   = iq_pkg::NUM_SRC,
    parameter int unsigned NUM_PORTS = iq_pkg::NUM_PORTS
);

    // -------------------------------------------------------------------------
    // Local derived widths
    // -------------------------------------------------------------------------
    // $clog2(N) returns ceil(log2(N)) and is the canonical way to size an
    // index bus that addresses N items. For DEPTH=16, $clog2(DEPTH)=4.
    localparam int unsigned IDX_WIDTH = (DEPTH <= 1) ? 1 : $clog2(DEPTH);

    // -------------------------------------------------------------------------
    // Signal group 1: Dispatch (dispatch unit → IQ)
    // -------------------------------------------------------------------------
    // The dispatch unit drives `dispatch_*` and the IQ returns `dispatch_ready`
    // plus `dispatch_slot_idx` (which physical slot was allocated, useful for
    // debugging in waveforms and for future features like squashing by slot).
    logic                       dispatch_valid;      // Indicates a valid instruction is being dispatched this cycle
    logic [TAG_WIDTH-1:0]       dispatch_dst_tag;    // The destination tag allocated to the incoming instruction

    // Per-source operand tag and a one-hot "is this source immediate" mask.
    // An immediate source has no producer dependency and is ready the moment
    // the entry is written. Without src_imm the dispatch unit would have to
    // pick a reserved tag value to mean "immediate" — possible, but muddy.
    logic [NUM_SRC-1:0][TAG_WIDTH-1:0] dispatch_src_tag; // Source tags the dispatched instruction depends on
    logic [NUM_SRC-1:0]                dispatch_src_imm; // Bitmask indicating if each source operand is an immediate (1=immediate, ready immediately)

    // Backpressure from the IQ (0 = queue full, hold off dispatch).
    // Backpressure from the IQ (0 = queue full, hold off dispatch).
    logic                       dispatch_ready;      // High when the IQ has at least one free slot to accept a new dispatch
    // Allocated slot index. Even when `dispatch_ready=0`, the signal still
    // reports what slot *would* be used next — useful for tracing resets.
    logic [IDX_WIDTH-1:0]       dispatch_slot_idx;   // Index of the IQ entry being allocated for this dispatch

    // -------------------------------------------------------------------------
    // Signal group 2: Wakeup (execution writeback → IQ)
    // -------------------------------------------------------------------------
    // One wakeup channel per cycle for clarity. Production cores often have
    // a wide wakeup bus (e.g. 8 tags/cycle) because many ops complete in
    // parallel. Adding a second channel is a clean extension; modport and
    // CAM compare logic are unaffected structurally.
    logic                       wakeup_valid;        // Indicates a valid result is being broadcasted on the wakeup bus this cycle
    logic [TAG_WIDTH-1:0]       wakeup_tag;          // The tag of the completed instruction, causing dependent instructions to wake up

    // -------------------------------------------------------------------------
    // Signal group 3: Issue (IQ → execution)
    // -------------------------------------------------------------------------
    // NUM_PORTS parallel issue bundles. Each port asserts `issue_valid[i]`
    // when the selector grants entry `issue_idx[i]` for issuance this cycle.
    // The execution unit samples the bundle; no handshake reply is required
    // because the issued entry clears next cycle from inside the IQ.
    logic [NUM_PORTS-1:0]                issue_valid;    // High if the corresponding issue port is granting an instruction this cycle
    logic [NUM_PORTS-1:0][IDX_WIDTH-1:0]  issue_idx;     // The IQ slot index of the instruction being issued on each port
    logic [NUM_PORTS-1:0][TAG_WIDTH-1:0]  issue_dst_tag; // Destination tag of the issuing instruction, useful for debug/tracking
    // Age reported on the issue port lets downstream stages reproduce
    // selection order in waveforms; it is NOT architecturally required.
    logic [NUM_PORTS-1:0][iq_pkg::AGE_WIDTH-1:0] issue_age; // The age value of the issued instruction, primarily for debug/verification

    // -------------------------------------------------------------------------
    // MODPORTS — restricted views per connected module
    // -------------------------------------------------------------------------
    // WHAT IS A MODPORT: a named projection of an interface that lists each
    // signal as input/output FROM THE MODULE THAT USES THE MODPORT's view.
    // A signal listed as `output` inside a modport is driven by the module
    // that instantiated the interface with that modport; `input` is read.
    //
    // This is the interface equivalent of a "port list" on a module. Without
    // modports, every connected module could see every signal as a `logic`
    // inside the interface scope, which defeats the encapsulation.

    // dispatch_mp — view used by the dispatch unit module
    modport dispatch_mp (
        // Dispatch unit DRIVES the instruction into the IQ:
        output  dispatch_valid,
        output  dispatch_dst_tag,
        output  dispatch_src_tag,
        output  dispatch_src_imm,
        // Dispatch unit READS backpressure and slot index:
        input   dispatch_ready,
        input   dispatch_slot_idx
    );

    // wakeup_mp — view used by the execution/writeback producer.
    // Both signals are outputs from the producer's perspective; the IQ
    // will read them through iq_mp's input list below.
    modport wakeup_mp (
        output  wakeup_valid,
        output  wakeup_tag
    );

    // issue_mp — view used by the execution unit consuming an issue grant.
    // IQ DRIVES these; exec READS them.
    modport issue_mp (
        input   issue_valid,
        input   issue_idx,
        input   issue_dst_tag,
        input   issue_age
    );

    // iq_mp — view used INSIDE iq_top. By convention, the queue sees
    // everything as `input` (it samples) or `output` (it drives). This
    // modport is the keystone that wires the three external modports
    // together cleanly in iq_top.sv.
    modport iq_mp (
        // Sampled from neighbors:
        input   dispatch_valid,
        input   dispatch_dst_tag,
        input   dispatch_src_tag,
        input   dispatch_src_imm,
        input   wakeup_valid,
        input   wakeup_tag,
        // Driven into neighbors:
        output  dispatch_ready,
        output  dispatch_slot_idx,
        output  issue_valid,
        output  issue_idx,
        output  issue_dst_tag,
        output  issue_age
    );

endinterface : iq_if

`endif // IQ_IF_SV
