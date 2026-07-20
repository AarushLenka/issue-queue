`ifndef IQ_SELECT_SV
`define IQ_SELECT_SV

`include "iq_pkg.sv"

module iq_select #(
    parameter int unsigned DEPTH     = iq_pkg::DEPTH,
    parameter int unsigned AGE_WIDTH = iq_pkg::AGE_WIDTH,
    parameter int unsigned NUM_PORTS = iq_pkg::NUM_PORTS,
    parameter int unsigned TAG_WIDTH = iq_pkg::TAG_WIDTH
)(
    input  iq_pkg::iq_entry_t           entry_i [DEPTH],
    input  logic [DEPTH-1:0]            ready_i,

    output logic [NUM_PORTS-1:0]                          grant_o,
    output logic [NUM_PORTS-1:0][$clog2(DEPTH)-1:0]       grant_idx_o,
    output logic [NUM_PORTS-1:0][TAG_WIDTH-1:0]           grant_tag_o,
    output logic [NUM_PORTS-1:0][AGE_WIDTH-1:0]           grant_age_o
);

    localparam int unsigned IDX_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH);

    typedef struct packed {
        logic                 valid;
        logic [IDX_W-1:0]     idx;
        logic [AGE_WIDTH-1:0] age;
    } candidate_t;

    function automatic candidate_t pick_older(input candidate_t a,
                                               input candidate_t b);
        if (!a.valid && !b.valid) begin
            pick_older = '0;
        end else if (!b.valid) begin
            pick_older = a;
        end else if (!a.valid) begin
            pick_older = b;
        end else begin
            if (iq_pkg::age_older_than(a.age, b.age))
                pick_older = a;
            else if (iq_pkg::age_older_than(b.age, a.age))
                pick_older = b;
            else
                pick_older = (a.idx <= b.idx) ? a : b;
        end
    endfunction

    function automatic candidate_t find_oldest_ready(
        input iq_pkg::iq_entry_t entry_arr [DEPTH],
        input logic [DEPTH-1:0]  mask
    );
        localparam int unsigned TREE_SIZE = 32;

        candidate_t tree [TREE_SIZE];
        int half;

        for (int i = 0; i < TREE_SIZE; i++) begin
            if (i < DEPTH && mask[i]) begin
                tree[i].valid = 1'b1;
                tree[i].idx   = i[IDX_W-1:0];
                tree[i].age   = entry_arr[i].age;
            end else begin
                tree[i] = '0;
            end
        end

        half = TREE_SIZE;
        while (half > 1) begin
            half = half / 2;
            for (int i = 0; i < half; i++) begin
                tree[i] = pick_older(tree[2*i], tree[2*i+1]);
            end
        end

        return tree[0];
    endfunction

    always_comb begin : multi_port_select
        logic [DEPTH-1:0] current_mask;
        candidate_t       winner;

        current_mask = ready_i;

        for (int p = 0; p < NUM_PORTS; p++) begin
            winner = find_oldest_ready(entry_i, current_mask);

            grant_o[p]     = winner.valid;
            grant_idx_o[p] = winner.idx;

            if (winner.valid) begin
                grant_tag_o[p] = entry_i[winner.idx].dst_tag;
                grant_age_o[p] = entry_i[winner.idx].age;
            end else begin
                grant_tag_o[p] = '0;
                grant_age_o[p] = '0;
            end

            if (winner.valid) begin
                current_mask[winner.idx] = 1'b0;
            end
        end
    end

endmodule : iq_select

`endif
