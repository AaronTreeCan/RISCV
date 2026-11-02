// fmax_top.sv - timing wrapper: measures how fast a core can be clocked on an FPGA
//
// An FPGA has a few hundred pins, but a core has ~200 bus signals, so this
// wrapper feeds the core's inputs from shift registers (one serial pin) and
// folds its outputs into one pin through registers and an XOR. Every input
// and output of the core then starts or ends at a flip-flop, which is what
// a real SoC around it would look like, and the timing report measures the
// core itself. The memories are NOT included: on a real board the core's
// combinational memory reads would need block RAM, which reads on a clock
// edge (see the README for what that changes).
//
// The retire ports exist for the testbench only; left unconnected here, the
// synthesis tool removes their logic, as it would in a real chip.
//
// CORE: 1 = 5-stage pipeline, 2 = dual-issue.

module fmax_top #(
    parameter int CORE = 2
) (
    input  logic clk,
    input  logic rst,
    input  logic din,
    output logic dout
);
    logic [63:0] imem_rdata;
    logic [31:0] dmem_rdata;
    logic [31:0] imem_addr, dmem_addr, dmem_wdata;
    logic        dmem_re, dmem_we, halted, illegal;
    logic [3:0]  dmem_be;

    // inputs: one long shift register
    always_ff @(posedge clk) {imem_rdata, dmem_rdata} <= {imem_rdata[62:0], dmem_rdata, din};

    if (CORE == 2) begin : g_dual
        core_dual u_core (
            .clk(clk), .rst(rst),
            .imem_addr(imem_addr), .imem_rdata(imem_rdata),
            .dmem_addr(dmem_addr), .dmem_re(dmem_re), .dmem_we(dmem_we), .dmem_be(dmem_be),
            .dmem_wdata(dmem_wdata), .dmem_rdata(dmem_rdata),
            .halted(halted), .illegal(illegal),
            /* verilator lint_off PINCONNECTEMPTY */
            .retire0(), .retire1()
            /* verilator lint_on PINCONNECTEMPTY */
        );
    end else begin : g_pipe
        core u_core (
            .clk(clk), .rst(rst),
            .imem_addr(imem_addr), .imem_rdata(imem_rdata[31:0]),
            .dmem_addr(dmem_addr), .dmem_re(dmem_re), .dmem_we(dmem_we), .dmem_be(dmem_be),
            .dmem_wdata(dmem_wdata), .dmem_rdata(dmem_rdata),
            .halted(halted), .illegal(illegal),
            /* verilator lint_off PINCONNECTEMPTY */
            .retire()
            /* verilator lint_on PINCONNECTEMPTY */
        );
    end

    // outputs: registered, then folded into one pin
    logic [103:0] out_q;
    always_ff @(posedge clk) begin
        out_q <= {imem_addr, dmem_addr, dmem_wdata, dmem_be, dmem_re, dmem_we, halted, illegal};
        dout  <= ^out_q;
    end
endmodule
