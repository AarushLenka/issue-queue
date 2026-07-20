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

    input  logic                               dispatch_valid,
    input  logic [TAG_WIDTH-1:0]               dispatch_dst_tag,
    input  logic [NUM_SRC-1:0][TAG_WIDTH-1:0]  dispatch_src_tag,
    input  logic [NUM_SRC-1:0]                 dispatch_src_imm,

    output logic                               dispatch_ready,
    output logic [$clog2(DEPTH)-1:0]           dispatch_slot_idx,

    input  logic                               wakeup_valid,
    input  logic [TAG_WIDTH-1:0]               wakeup_tag,
    input  logic                               spec_wakeup_valid,
    input  logic [TAG_WIDTH-1:0]               spec_wakeup_tag,

    output logic [NUM_PORTS-1:0]                          issue_valid,
    output logic [NUM_PORTS-1:0][$clog2(DEPTH)-1:0]       issue_idx,
    output logic [NUM_PORTS-1:0][TAG_WIDTH-1:0]           issue_dst_tag,
    output logic [NUM_PORTS-1:0][AGE_WIDTH-1:0]           issue_age,

    input  logic                               squash_en,
    input  logic [15:0]                        squash_seq
);

    localparam int unsigned IDX_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH);

    iq_pkg::iq_entry_t  entry_array [DEPTH];
    logic [DEPTH-1:0]   ready_array;

    logic [NUM_PORTS-1:0]                  sel_grant;
    logic [NUM_PORTS-1:0][IDX_W-1:0]       sel_idx;
    logic [NUM_PORTS-1:0][TAG_WIDTH-1:0]   sel_tag;
    logic [NUM_PORTS-1:0][AGE_WIDTH-1:0]   sel_age;

    logic [DEPTH-1:0] free_vec;
    logic [IDX_W-1:0] alloc_idx;
    logic             has_free;

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

    logic dispatch_accepted;
    assign dispatch_ready   = has_free;
    assign dispatch_accepted = dispatch_valid && has_free;
    assign dispatch_slot_idx = alloc_idx;

    logic [15:0] disp_seq_r;

    always_ff @(posedge clk or negedge rst_n) begin : disp_seq_counter
        if (!rst_n)
            disp_seq_r <= '0;
        else if (dispatch_accepted)
            disp_seq_r <= disp_seq_r + 16'd1;
    end

    always_ff @(posedge clk or negedge rst_n) begin : free_vec_update
        if (!rst_n) begin
            free_vec <= '1;
        end else begin
            for (int p = 0; p < NUM_PORTS; p++) begin
                if (sel_grant[p])
                    free_vec[sel_idx[p]] <= 1'b1;
            end

            if (squash_en) begin
                for (int i = 0; i < DEPTH; i++) begin
                    if (entry_array[i].valid && (entry_array[i].disp_seq > squash_seq))
                        free_vec[i] <= 1'b1;
                end
            end

            if (dispatch_accepted) begin
                free_vec[alloc_idx] <= 1'b0;
            end
        end
    end

    iq_wakeup_cam #(
        .DEPTH     (DEPTH),
        .TAG_WIDTH (TAG_WIDTH),
        .NUM_SRC   (NUM_SRC),
        .AGE_WIDTH (AGE_WIDTH),
        .NUM_PORTS (NUM_PORTS)
    ) u_cam (
        .clk               (clk),
        .rst_n             (rst_n),
        .dispatch_valid    (dispatch_accepted),
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

    assign issue_valid   = sel_grant;
    assign issue_idx     = sel_idx;
    assign issue_dst_tag = sel_tag;
    assign issue_age     = sel_age;

endmodule : iq_top

`endif
