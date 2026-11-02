// mul_unit.sv - RV32M multiply, one cycle (purely combinational)
//
//   MUL     low 32 bits of a * b           (same for signed and unsigned)
//   MULH    high 32 bits, signed   * signed
//   MULHSU  high 32 bits, signed   * unsigned
//   MULHU   high 32 bits, unsigned * unsigned
//
// One trick covers all four: extend each operand to 33 bits (sign-extend if
// that operand is signed, zero-extend if not) and do one signed 33x33
// multiply. Synthesis builds the partial products and an adder tree; that
// tree is about log2(32) adders deep, which is why a multiply can finish in
// one cycle while a divide can't (each divide step needs the previous one).

module mul_unit
    import riscv_pkg::*;
(
    input  logic [31:0] a,
    input  logic [31:0] b,
    input  md_op_t      op,             // MD_MUL .. MD_MULHU
    output logic [31:0] result
);

    logic               a_signed, b_signed;
    logic signed [32:0] a_ext, b_ext;
    logic signed [65:0] prod;

    assign a_signed = (op == MD_MULH) || (op == MD_MULHSU);
    assign b_signed = (op == MD_MULH);
    assign a_ext    = {a_signed & a[31], a};
    assign b_ext    = {b_signed & b[31], b};
    assign prod     = a_ext * b_ext;

    /* verilator lint_off UNUSEDSIGNAL */
    logic [65:0] prod_bits;             // the top 2 bits are only sign
    /* verilator lint_on UNUSEDSIGNAL */
    assign prod_bits = prod;
    assign result    = (op == MD_MUL) ? prod_bits[31:0] : prod_bits[63:32];

endmodule
