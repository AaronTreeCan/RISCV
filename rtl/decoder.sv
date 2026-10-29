// decoder.sv - RV32I instruction decoder (purely combinational)
//
// Two parts, the classic split:
//   main decoder : opcode -> datapath controls + which kind of ALU work is needed
//   ALU decoder  : that kind + funct3/funct7 -> the exact alu_op
//
// Conventions:
//   - output is one ctrl_t struct (riscv_pkg) so a pipeline can register it whole
//     and the dual-issue core can instantiate two decoders
//   - fields an instruction doesn't use stay at fixed defaults (ADD, RS1, RS2,
//     IMM_I, WB_ALU, MEM_W, ...) so nothing downstream ever sees X
//   - an invalid encoding becomes a NOP with `illegal` set
//     (no register write, no memory access, no branch/jump)
//   - ECALL / EBREAK set `halt`; FENCE is a NOP

module decoder
    import riscv_pkg::*;
(
    input  logic [31:0] instr,
    output ctrl_t       ctrl
);

    logic [6:0] opcode;
    logic [2:0] funct3;
    logic [6:0] funct7;

    assign opcode = instr[6:0];
    assign funct3 = instr[14:12];
    assign funct7 = instr[31:25];

    // What kind of ALU work the main decoder asks for
    typedef enum logic [1:0] {
        ALU_KIND_ADD,       // address / target / LUI / AUIPC: always ADD
        ALU_KIND_REG,       // R-type: funct3 + funct7
        ALU_KIND_IMM        // I-type arithmetic: funct3 (+ funct7 for shifts)
    } alu_kind_t;

    alu_kind_t alu_kind;
    ctrl_t     main_ctrl;   // main decoder output, alu_op filled in below
    logic      main_illegal;
    alu_op_t   alu_op;
    logic      alu_illegal;

    // A harmless "do nothing" instruction: the starting point for every decode,
    // and exactly what an illegal instruction turns into (plus the illegal bit).
    function automatic ctrl_t nop_ctrl();
        ctrl_t c;
        c          = '0;
        c.alu_op   = ALU_ADD;
        c.src_a    = SRC_A_RS1;
        c.src_b    = SRC_B_RS2;
        c.imm_type = IMM_I;
        c.wb_sel   = WB_ALU;
        c.mem_size = MEM_W;
        c.branch   = BR_NONE;
        return c;
    endfunction

    // ---------------- main decoder ----------------
    always_comb begin
        main_ctrl              = nop_ctrl();
        alu_kind               = ALU_KIND_ADD;
        main_illegal           = 1'b0;

        case (opcode)
            OP_LUI: begin
                main_ctrl.src_a     = SRC_A_ZERO;
                main_ctrl.src_b     = SRC_B_IMM;
                main_ctrl.imm_type  = IMM_U;
                main_ctrl.reg_write = 1'b1;
            end
            OP_AUIPC: begin
                main_ctrl.src_a     = SRC_A_PC;
                main_ctrl.src_b     = SRC_B_IMM;
                main_ctrl.imm_type  = IMM_U;
                main_ctrl.reg_write = 1'b1;
            end
            OP_JAL: begin                       // ALU computes PC + imm (target)
                main_ctrl.src_a     = SRC_A_PC;
                main_ctrl.src_b     = SRC_B_IMM;
                main_ctrl.imm_type  = IMM_J;
                main_ctrl.reg_write = 1'b1;
                main_ctrl.wb_sel    = WB_PC4;
                main_ctrl.jal       = 1'b1;
            end
            OP_JALR: begin                      // ALU computes rs1 + imm (target)
                main_ctrl.src_b     = SRC_B_IMM;
                main_ctrl.reg_write = 1'b1;
                main_ctrl.wb_sel    = WB_PC4;
                main_ctrl.jalr      = 1'b1;
                main_illegal        = (funct3 != 3'b000);
            end
            OP_BRANCH: begin                    // ALU computes PC + imm (target)
                main_ctrl.src_a     = SRC_A_PC;
                main_ctrl.src_b     = SRC_B_IMM;
                main_ctrl.imm_type  = IMM_B;
                case (funct3)
                    3'b000:  main_ctrl.branch = BR_EQ;
                    3'b001:  main_ctrl.branch = BR_NE;
                    3'b100:  main_ctrl.branch = BR_LT;
                    3'b101:  main_ctrl.branch = BR_GE;
                    3'b110:  main_ctrl.branch = BR_LTU;
                    3'b111:  main_ctrl.branch = BR_GEU;
                    default: main_illegal     = 1'b1;
                endcase
            end
            OP_LOAD: begin                      // ALU computes rs1 + imm (address)
                main_ctrl.src_b     = SRC_B_IMM;
                main_ctrl.reg_write = 1'b1;
                main_ctrl.wb_sel    = WB_MEM;
                main_ctrl.mem_read  = 1'b1;
                case (funct3)
                    3'b000:  main_ctrl.mem_size = MEM_B;                                // LB
                    3'b001:  main_ctrl.mem_size = MEM_H;                                // LH
                    3'b010:  main_ctrl.mem_size = MEM_W;                                // LW
                    3'b100:  begin main_ctrl.mem_size = MEM_B; main_ctrl.mem_unsigned = 1'b1; end  // LBU
                    3'b101:  begin main_ctrl.mem_size = MEM_H; main_ctrl.mem_unsigned = 1'b1; end  // LHU
                    default: main_illegal = 1'b1;
                endcase
            end
            OP_STORE: begin                     // ALU computes rs1 + imm (address)
                main_ctrl.src_b     = SRC_B_IMM;
                main_ctrl.imm_type  = IMM_S;
                main_ctrl.mem_write = 1'b1;
                case (funct3)
                    3'b000:  main_ctrl.mem_size = MEM_B;
                    3'b001:  main_ctrl.mem_size = MEM_H;
                    3'b010:  main_ctrl.mem_size = MEM_W;
                    default: main_illegal = 1'b1;
                endcase
            end
            OP_IMM: begin
                main_ctrl.src_b     = SRC_B_IMM;
                main_ctrl.reg_write = 1'b1;
                alu_kind            = ALU_KIND_IMM;
            end
            OP_REG: begin
                main_ctrl.reg_write = 1'b1;
                alu_kind            = ALU_KIND_REG;
            end
            OP_MISC_MEM: begin                  // FENCE: no-op on an in-order core
                main_illegal = (funct3 != 3'b000);
            end
            OP_SYSTEM: begin                    // only exact ECALL / EBREAK encodings
                if (instr == 32'h0000_0073 || instr == 32'h0010_0073)
                    main_ctrl.halt = 1'b1;
                else
                    main_illegal = 1'b1;        // CSR instructions: not supported yet
            end
            default: main_illegal = 1'b1;
        endcase
    end

    // ---------------- ALU decoder ----------------
    always_comb begin
        alu_op      = ALU_ADD;
        alu_illegal = 1'b0;

        if (alu_kind != ALU_KIND_ADD) begin
            case (funct3)
                3'b000: begin
                    // ADD / SUB (R-type, funct7 picks) or ADDI (no SUBI exists)
                    if (alu_kind == ALU_KIND_REG && funct7 == 7'b0100000) alu_op = ALU_SUB;
                    else                                                  alu_op = ALU_ADD;
                    if (alu_kind == ALU_KIND_REG)
                        alu_illegal = (funct7 != 7'b0000000 && funct7 != 7'b0100000);
                end
                3'b001: begin
                    alu_op      = ALU_SLL;
                    alu_illegal = (funct7 != 7'b0000000);       // SLL / SLLI
                end
                3'b010: begin
                    alu_op      = ALU_SLT;
                    alu_illegal = (alu_kind == ALU_KIND_REG && funct7 != 7'b0000000);
                end
                3'b011: begin
                    alu_op      = ALU_SLTU;
                    alu_illegal = (alu_kind == ALU_KIND_REG && funct7 != 7'b0000000);
                end
                3'b100: begin
                    alu_op      = ALU_XOR;
                    alu_illegal = (alu_kind == ALU_KIND_REG && funct7 != 7'b0000000);
                end
                3'b101: begin
                    // SRL/SRA and SRLI/SRAI: funct7 bit 5 picks arithmetic
                    if (funct7 == 7'b0100000) alu_op = ALU_SRA;
                    else                      alu_op = ALU_SRL;
                    alu_illegal = (funct7 != 7'b0000000 && funct7 != 7'b0100000);
                end
                3'b110: begin
                    alu_op      = ALU_OR;
                    alu_illegal = (alu_kind == ALU_KIND_REG && funct7 != 7'b0000000);
                end
                default: begin  // 3'b111
                    alu_op      = ALU_AND;
                    alu_illegal = (alu_kind == ALU_KIND_REG && funct7 != 7'b0000000);
                end
            endcase
        end
    end

    // ---------------- combine ----------------
    always_comb begin
        if (main_illegal || alu_illegal || instr[1:0] != 2'b11) begin
            // an illegal instruction becomes a NOP with the flag set:
            // no register write, no memory access, no branch or jump
            ctrl         = nop_ctrl();
            ctrl.illegal = 1'b1;
        end else begin
            ctrl         = main_ctrl;
            ctrl.alu_op  = alu_op;
        end
    end

endmodule
