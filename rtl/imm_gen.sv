// imm_gen.sv - builds the sign-extended 32-bit immediate for each format
//
// The bits are scattered differently per format so that instr[31] is ALWAYS
// the sign bit and rs1/rs2/rd never move. That keeps register reads off the
// critical path; the price is this small rewiring mux.

module imm_gen
    import riscv_pkg::*;
(
    /* verilator lint_off UNUSEDSIGNAL */   // the opcode bits [6:0] hold no immediate
    input  logic [31:0] instr,
    /* verilator lint_on UNUSEDSIGNAL */
    input  imm_type_t   imm_type,
    output logic [31:0] imm
);

    always_comb begin
        case (imm_type)
            IMM_I:   imm = {{21{instr[31]}}, instr[30:20]};
            IMM_S:   imm = {{21{instr[31]}}, instr[30:25], instr[11:7]};
            IMM_B:   imm = {{20{instr[31]}}, instr[7], instr[30:25], instr[11:8], 1'b0};
            IMM_U:   imm = {instr[31:12], 12'b0};
            IMM_J:   imm = {{12{instr[31]}}, instr[19:12], instr[20], instr[30:21], 1'b0};
            default: imm = '0;
        endcase
    end

endmodule
