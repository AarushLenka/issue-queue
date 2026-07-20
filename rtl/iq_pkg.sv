`ifndef IQ_PKG_SV
`define IQ_PKG_SV

package iq_pkg;

  parameter int unsigned TAG_WIDTH = 6;
  parameter int unsigned NUM_SRC   = 2;
  parameter int unsigned DEPTH     = 16;
  parameter int unsigned NUM_PORTS = 2;

  parameter int unsigned AGE_WIDTH = (DEPTH <= 16)  ? 4
                                   : (DEPTH <= 256) ? 8
                                   : 12;

  localparam logic [AGE_WIDTH-1:0] AGE_SAT_MAX = '1;

  typedef struct packed {
    logic [TAG_WIDTH-1:0]              dst_tag;
    logic [NUM_SRC-1:0][TAG_WIDTH-1:0] src_tag;
    logic [NUM_SRC-1:0]                src_ready;
    logic                              valid;
    logic [AGE_WIDTH-1:0]              age;
    logic [15:0]                       disp_seq;
  } iq_entry_t;

  function automatic logic age_older_than(input logic [AGE_WIDTH-1:0] a,
                                           input logic [AGE_WIDTH-1:0] b);
    return (a > b);
  endfunction

  function automatic logic is_ready(input iq_entry_t e);
    return e.valid & (&e.src_ready);
  endfunction

endpackage : iq_pkg

`endif
