// branch_cmp.sv - decides whether a conditional branch is taken
//
// Separate from the ALU so the ALU is free to compute the target (PC + imm),
// and so branch resolution can move into the decode stage once pipelined.
//
// Signed and unsigned "less than" come from one 33-bit subtraction each:
// extend both operands by one bit (sign bit for signed, 0 for unsigned) and
// the top bit of the difference is the answer - no overflow case to handle.

module branch_cmp
    import riscv_pkg::*;
(
    input  logic [31:0] a,          // rs1
    input  logic [31:0] b,          // rs2
    input  branch_t     branch,
    output logic        taken
);

    logic        eq, lt, ltu;
    /* verilator lint_off UNUSEDSIGNAL */   // only bit 32 of each difference is used
    logic [32:0] diff_s, diff_u;
    /* verilator lint_on UNUSEDSIGNAL */

    assign diff_s = {a[31], a} - {b[31], b};
    assign diff_u = {1'b0,  a} - {1'b0,  b};

    assign eq  = (a == b);
    assign lt  = diff_s[32];
    assign ltu = diff_u[32];

    always_comb begin
        case (branch)
            BR_EQ:   taken =  eq;
            BR_NE:   taken = ~eq;
            BR_LT:   taken =  lt;
            BR_GE:   taken = ~lt;
            BR_LTU:  taken =  ltu;
            BR_GEU:  taken = ~ltu;
            default: taken = 1'b0;      // BR_NONE
        endcase
    end

endmodule
