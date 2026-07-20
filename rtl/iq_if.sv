`ifndef IQ_IF_SV
`define IQ_IF_SV

interface iq_if #(
    parameter int unsigned DEPTH     = iq_pkg::DEPTH,
    parameter int unsigned TAG_WIDTH = iq_pkg::TAG_WIDTH,
    parameter int unsigned NUM_SRC   = iq_pkg::NUM_SRC,
    parameter int unsigned NUM_PORTS = iq_pkg::NUM_PORTS
);

    localparam int unsigned IDX_WIDTH = (DEPTH <= 1) ? 1 : $clog2(DEPTH);

    logic                       dispatch_valid;
    logic [TAG_WIDTH-1:0]       dispatch_dst_tag;
    logic [NUM_SRC-1:0][TAG_WIDTH-1:0] dispatch_src_tag;
    logic [NUM_SRC-1:0]                dispatch_src_imm;
    logic                       dispatch_ready;
    logic [IDX_WIDTH-1:0]       dispatch_slot_idx;

    logic                       wakeup_valid;
    logic [TAG_WIDTH-1:0]       wakeup_tag;

    logic [NUM_PORTS-1:0]                issue_valid;
    logic [NUM_PORTS-1:0][IDX_WIDTH-1:0]  issue_idx;
    logic [NUM_PORTS-1:0][TAG_WIDTH-1:0]  issue_dst_tag;
    logic [NUM_PORTS-1:0][iq_pkg::AGE_WIDTH-1:0] issue_age;

    modport dispatch_mp (
        output  dispatch_valid,
        output  dispatch_dst_tag,
        output  dispatch_src_tag,
        output  dispatch_src_imm,
        input   dispatch_ready,
        input   dispatch_slot_idx
    );

    modport wakeup_mp (
        output  wakeup_valid,
        output  wakeup_tag
    );

    modport issue_mp (
        input   issue_valid,
        input   issue_idx,
        input   issue_dst_tag,
        input   issue_age
    );

    modport iq_mp (
        input   dispatch_valid,
        input   dispatch_dst_tag,
        input   dispatch_src_tag,
        input   dispatch_src_imm,
        input   wakeup_valid,
        input   wakeup_tag,
        output  dispatch_ready,
        output  dispatch_slot_idx,
        output  issue_valid,
        output  issue_idx,
        output  issue_dst_tag,
        output  issue_age
    );

endinterface : iq_if

`endif
