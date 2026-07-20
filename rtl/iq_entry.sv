`ifndef IQ_ENTRY_SV
`define IQ_ENTRY_SV

`include "iq_pkg.sv"

module iq_entry #(
    parameter int unsigned TAG_WIDTH = iq_pkg::TAG_WIDTH,
    parameter int unsigned NUM_SRC   = iq_pkg::NUM_SRC,
    parameter int unsigned AGE_WIDTH = iq_pkg::AGE_WIDTH
)(
    input  logic                               clk,
    input  logic                               rst_n,

    input  logic                               dispatch_we,
    input  logic [TAG_WIDTH-1:0]               dispatch_dst_tag,
    input  logic [NUM_SRC-1:0][TAG_WIDTH-1:0]  dispatch_src_tag,
    input  logic [NUM_SRC-1:0]                 dispatch_src_imm,
    input  logic [15:0]                        dispatch_disp_seq,

    input  logic                               wakeup_valid,
    input  logic [TAG_WIDTH-1:0]               wakeup_tag,
    input  logic                               spec_wakeup_valid,
    input  logic [TAG_WIDTH-1:0]               spec_wakeup_tag,

    input  logic                               issue_clear,
    input  logic                               squash_clear,

    output iq_pkg::iq_entry_t                  entry_o,
    output logic                               ready_o
);

    iq_pkg::iq_entry_t entry_r;

    logic [NUM_SRC-1:0][TAG_WIDTH-1:0] src_tag_eff;

    always_comb begin : src_tag_eff_calc
        for (int i = 0; i < NUM_SRC; i++) begin
            src_tag_eff[i] = dispatch_we ? dispatch_src_tag[i]
                                         : entry_r.src_tag[i];
        end
    end

    logic [NUM_SRC-1:0] wakeup_hit;
    logic [NUM_SRC-1:0] spec_wakeup_hit;
    always_comb begin : wakeup_compare
        for (int i = 0; i < NUM_SRC; i++) begin
            wakeup_hit[i] = wakeup_valid && (wakeup_tag == src_tag_eff[i]);
            spec_wakeup_hit[i] = spec_wakeup_valid && (spec_wakeup_tag == src_tag_eff[i]);
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin : entry_state
        if (!rst_n) begin
            entry_r <= '0;
        end else if (dispatch_we) begin
            entry_r.valid     <= 1'b1;
            entry_r.dst_tag   <= dispatch_dst_tag;
            entry_r.src_tag   <= dispatch_src_tag;
            entry_r.src_ready <= dispatch_src_imm | wakeup_hit | spec_wakeup_hit;
            entry_r.age       <= '0;
            entry_r.disp_seq  <= dispatch_disp_seq;
        end else if (issue_clear || squash_clear) begin
            entry_r.valid     <= 1'b0;
            entry_r.src_ready <= '0;
            entry_r.age       <= '0;
        end else if (entry_r.valid) begin
            entry_r.src_ready <= entry_r.src_ready | wakeup_hit | spec_wakeup_hit;
            entry_r.age       <= (entry_r.age == iq_pkg::AGE_SAT_MAX)
                                  ? iq_pkg::AGE_SAT_MAX
                                  : entry_r.age + 1'b1;
        end
    end

    assign entry_o = entry_r;
    assign ready_o = iq_pkg::is_ready(entry_r);

endmodule : iq_entry

`endif
