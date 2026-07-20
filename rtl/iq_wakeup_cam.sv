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

    input  logic                               dispatch_valid,
    input  logic [$clog2(DEPTH)-1:0]           dispatch_slot_idx,
    input  logic [TAG_WIDTH-1:0]               dispatch_dst_tag,
    input  logic [NUM_SRC-1:0][TAG_WIDTH-1:0]  dispatch_src_tag,
    input  logic [NUM_SRC-1:0]                 dispatch_src_imm,
    input  logic [15:0]                        dispatch_disp_seq,

    input  logic                               wakeup_valid,
    input  logic [TAG_WIDTH-1:0]               wakeup_tag,
    input  logic                               spec_wakeup_valid,
    input  logic [TAG_WIDTH-1:0]               spec_wakeup_tag,

    input  logic [NUM_PORTS-1:0]                        issue_grant,
    input  logic [NUM_PORTS-1:0][$clog2(DEPTH)-1:0]     issue_idx,

    input  logic                               squash_en,
    input  logic [15:0]                        squash_seq,

    output iq_pkg::iq_entry_t                  entry_array_o [DEPTH],
    output logic [DEPTH-1:0]                   ready_array_o
);

    logic [DEPTH-1:0] dispatch_we_oh;

    always_comb begin : dispatch_decode
        dispatch_we_oh = '0;
        if (dispatch_valid)
            dispatch_we_oh[dispatch_slot_idx] = 1'b1;
    end

    logic [DEPTH-1:0] issue_clear_oh;

    always_comb begin : issue_decode
        issue_clear_oh = '0;
        for (int p = 0; p < NUM_PORTS; p++) begin
            if (issue_grant[p])
                issue_clear_oh[issue_idx[p]] = 1'b1;
        end
    end

    logic [DEPTH-1:0] squash_clear_oh;

    always_comb begin : squash_decode
        for (int i = 0; i < DEPTH; i++) begin
            squash_clear_oh[i] = squash_en
                               && entry_array_o[i].valid
                               && (entry_array_o[i].disp_seq > squash_seq);
        end
    end

    genvar gi;
    generate
        for (gi = 0; gi < DEPTH; gi++) begin : gen_entry
            iq_entry #(
                .TAG_WIDTH (TAG_WIDTH),
                .NUM_SRC   (NUM_SRC),
                .AGE_WIDTH (AGE_WIDTH)
            ) u_entry (
                .clk              (clk),
                .rst_n            (rst_n),
                .dispatch_we      (dispatch_we_oh[gi]),
                .dispatch_dst_tag (dispatch_dst_tag),
                .dispatch_src_tag (dispatch_src_tag),
                .dispatch_src_imm (dispatch_src_imm),
                .dispatch_disp_seq(dispatch_disp_seq),
                .wakeup_valid     (wakeup_valid),
                .wakeup_tag       (wakeup_tag),
                .spec_wakeup_valid(spec_wakeup_valid),
                .spec_wakeup_tag  (spec_wakeup_tag),
                .issue_clear      (issue_clear_oh[gi]),
                .squash_clear     (squash_clear_oh[gi]),
                .entry_o          (entry_array_o[gi]),
                .ready_o          (ready_array_o[gi])
            );
        end
    endgenerate

endmodule : iq_wakeup_cam

`endif
