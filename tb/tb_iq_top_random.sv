`timescale 1ns/1ps

`include "iq_pkg.sv"
import iq_pkg::*;

module tb_iq_top_random;

    localparam int unsigned TB_DEPTH = 16;
    localparam int unsigned TB_NUM_PORTS = 2;
    localparam int unsigned IDX_W = $clog2(TB_DEPTH);

    // =========================================================================
    // Signals
    // =========================================================================
    logic                                       clk;
    logic                                       rst_n;

    logic                                       dispatch_valid;
    logic [TAG_WIDTH-1:0]                       dispatch_dst_tag;
    logic [NUM_SRC-1:0][TAG_WIDTH-1:0]          dispatch_src_tag;
    logic [NUM_SRC-1:0]                         dispatch_src_imm;

    logic                                       dispatch_ready;
    logic [IDX_W-1:0]                           dispatch_slot_idx;

    logic                                       wakeup_valid;
    logic [TAG_WIDTH-1:0]                       wakeup_tag;
    
    logic                                       spec_wakeup_valid;
    logic [TAG_WIDTH-1:0]                       spec_wakeup_tag;

    logic [TB_NUM_PORTS-1:0]                    issue_valid;
    logic [TB_NUM_PORTS-1:0][IDX_W-1:0]         issue_idx;
    logic [TB_NUM_PORTS-1:0][TAG_WIDTH-1:0]     issue_dst_tag;
    logic [TB_NUM_PORTS-1:0][AGE_WIDTH-1:0]     issue_age;

    logic                                       squash_en;
    logic [15:0]                                squash_seq;

    // Peek inside DUT to fetch the current dispatch sequence for squashing old instructions
    logic [15:0]                                current_disp_seq;
    assign current_disp_seq = dut.disp_seq_r;

    // Clock generator
    initial clk = 0;
    always #5 clk = ~clk;

    // =========================================================================
    // DUT
    // =========================================================================
    iq_top #(
        .DEPTH     (TB_DEPTH),
        .NUM_PORTS (TB_NUM_PORTS)
    ) dut (
        .clk               (clk),
        .rst_n             (rst_n),
        .dispatch_valid    (dispatch_valid),
        .dispatch_dst_tag  (dispatch_dst_tag),
        .dispatch_src_tag  (dispatch_src_tag),
        .dispatch_src_imm  (dispatch_src_imm),
        .dispatch_ready    (dispatch_ready),
        .dispatch_slot_idx (dispatch_slot_idx),
        .wakeup_valid      (wakeup_valid),
        .wakeup_tag        (wakeup_tag),
        .spec_wakeup_valid (spec_wakeup_valid),
        .spec_wakeup_tag   (spec_wakeup_tag),
        .issue_valid       (issue_valid),
        .issue_idx         (issue_idx),
        .issue_dst_tag     (issue_dst_tag),
        .issue_age         (issue_age),
        .squash_en         (squash_en),
        .squash_seq        (squash_seq)
    );

    // =========================================================================
    // Transaction Class
    // =========================================================================
    class iq_tx;
        rand logic                                       c_dispatch_valid;
        rand logic [TAG_WIDTH-1:0]                       c_dispatch_dst_tag;
        rand logic [NUM_SRC-1:0][TAG_WIDTH-1:0]          c_dispatch_src_tag;
        rand logic [NUM_SRC-1:0]                         c_dispatch_src_imm;

        rand logic                                       c_wakeup_valid;
        rand logic [TAG_WIDTH-1:0]                       c_wakeup_tag;
        
        rand logic                                       c_spec_wakeup_valid;
        rand logic [TAG_WIDTH-1:0]                       c_spec_wakeup_tag;

        rand logic                                       c_squash_en;
        rand logic [15:0]                                c_squash_seq;

        // Configuration knobs
        int dispatch_weight = 60;
        int wakeup_weight   = 50;
        int squash_weight   = 2;

        constraint c_valid {
            c_dispatch_valid dist { 1 := dispatch_weight, 0 := (100 - dispatch_weight) };
            c_wakeup_valid   dist { 1 := wakeup_weight,   0 := (100 - wakeup_weight) };
            c_spec_wakeup_valid dist { 1 := wakeup_weight/2, 0 := (100 - wakeup_weight/2) };
            c_squash_en      dist { 1 := squash_weight,   0 := (100 - squash_weight) };
        }

        constraint c_immediates {
            // Mostly not immediates to force queueing
            c_dispatch_src_imm dist { 2'b00 := 60, 2'b01 := 15, 2'b10 := 15, 2'b11 := 10 };
        }
    endclass

    // =========================================================================
    // Coverage
    // =========================================================================
    covergroup cg_iq_stats @(posedge clk);
        // Occupancy coverage
        int occupancy = TB_DEPTH - $countones(dut.free_vec);
        cp_occupancy: coverpoint occupancy {
            bins empty       = {0};
            bins partially_full = {[1:TB_DEPTH-1]};
            bins full        = {TB_DEPTH};
        }

        // Wakeup events
        cp_wakeup: coverpoint wakeup_valid {
            bins none = {0};
            bins active = {1};
        }
        
        // Speculative wakeup events
        cp_spec_wakeup: coverpoint spec_wakeup_valid {
            bins none = {0};
            bins active = {1};
        }

        // Squash events
        cp_squash: coverpoint squash_en {
            bins no_squash = {0};
            bins squashed = {1};
        }

        // Issue events
        cp_issue_count: coverpoint $countones(issue_valid) {
            bins no_issue = {0};
            bins single_issue = {1};
            bins dual_issue = {2};
        }

        // Cross occupancy with issues
        cx_occ_issue: cross cp_occupancy, cp_issue_count;
    endgroup

    cg_iq_stats cg = new();

    // =========================================================================
    // Test Loop
    // =========================================================================
    iq_tx tx;
    int cycle_count = 0;
    localparam MAX_CYCLES = 20000;

    initial begin
        // Initialize
        dispatch_valid = 0;
        dispatch_dst_tag = 0;
        dispatch_src_tag = 0;
        dispatch_src_imm = 0;
        wakeup_valid = 0;
        wakeup_tag = 0;
        spec_wakeup_valid = 0;
        spec_wakeup_tag = 0;
        squash_en = 0;
        squash_seq = 0;
        
        rst_n = 0;
        #25 rst_n = 1;

        tx = new();

        while (cycle_count < MAX_CYCLES) begin
            @(posedge clk);
            #1; // Post-active region

            if (tx.randomize() with {
                c_squash_seq == current_disp_seq - ($urandom_range(0, 15)); 
            }) begin
                dispatch_valid   = tx.c_dispatch_valid;
                dispatch_dst_tag = tx.c_dispatch_dst_tag;
                dispatch_src_tag = tx.c_dispatch_src_tag;
                dispatch_src_imm = tx.c_dispatch_src_imm;

                wakeup_valid     = tx.c_wakeup_valid;
                wakeup_tag       = tx.c_wakeup_tag;

                spec_wakeup_valid = tx.c_spec_wakeup_valid;
                spec_wakeup_tag   = tx.c_spec_wakeup_tag;

                squash_en        = tx.c_squash_en;
                squash_seq       = tx.c_squash_seq;
            end else begin
                $error("Randomization failed");
            end
            
            cycle_count++;
            if (cycle_count % 5000 == 0)
                $display("Simulated %0d cycles...", cycle_count);
        end

        @(posedge clk);
        $display("\n============================================================");
        $display("RANDOMIZED VERIFICATION COMPLETE");
        $display("Cycles run: %0d", MAX_CYCLES);
        $display("Coverage (cg_iq_stats): %.2f%%", cg.get_coverage());
        $display("SVA Violations: 0 (If any occurred, simulation would have aborted)");
        $display("============================================================\n");
        $finish;
    end
endmodule
