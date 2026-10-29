// tb_decoder.sv - self-checking testbench for rtl/decoder.sv and rtl/imm_gen.sv
//
// Reference model, written differently from the RTL on purpose:
//   - the RTL decodes with nested case statements on opcode/funct3/funct7
//   - the model matches each instruction against its (mask, match) pair, the
//     same way the official riscv-opcodes tables describe RV32I, then looks up
//     the expected control word for that mnemonic. No match = illegal.
//   - imm_gen's model builds immediates with arithmetic shifts instead of
//     bit concatenation.
//
// Stimulus:
//   1. every RV32I instruction (plus FENCE/ECALL/EBREAK), 300 random encodings
//      each: random bits everywhere the mask allows
//   2. 20000 fully random 32-bit words (almost all illegal)
//   3. 20000 random words with a VALID opcode, to hit the funct3/funct7 checks
//   4. every immediate format, 2000 random instructions each

module tb_decoder;
    import riscv_pkg::*;

    logic [31:0] instr;
    ctrl_t       ctrl;
    imm_type_t   imm_type;
    logic [31:0] imm;

    decoder dut     (.instr(instr), .ctrl(ctrl));
    imm_gen dut_imm (.instr(instr), .imm_type(imm_type), .imm(imm));

    int errors = 0;
    int checks = 0;

    // ---------------- the RV32I table: mnemonic, mask, match ----------------
    localparam int N_INSTR = 40;

    // Mnemonics in table order. An enum (not strings) because Icarus 12 can't
    // run a case statement on a string returned from a function.
    typedef enum int {
        LUI, AUIPC, JAL, JALR, BEQ, BNE, BLT, BGE, BLTU, BGEU,
        LB, LH, LW, LBU, LHU, SB, SH, SW,
        ADDI, SLTI, SLTIU, XORI, ORI, ANDI, SLLI, SRLI, SRAI,
        ADD, SUB, SLL, SLT, SLTU, XOR, SRL, SRA, OR, AND,
        FENCE, ECALL, EBREAK,
        ILLEGAL
    } mnem_t;

    function automatic logic [31:0] mask_of(int i);
        if (i <= 2)               return 32'h0000_007F;   // LUI AUIPC JAL: opcode only
        if (i <= 23 || i == 37)   return 32'h0000_707F;   // + funct3
        if (i <= 36)              return 32'hFE00_707F;   // + funct7
        return 32'hFFFF_FFFF;                             // ECALL / EBREAK: exact
    endfunction

    function automatic logic [31:0] match_of(int i);
        case (i)
            0: return 32'h0000_0037;  1: return 32'h0000_0017;  2: return 32'h0000_006F;
            3: return 32'h0000_0067;  4: return 32'h0000_0063;  5: return 32'h0000_1063;
            6: return 32'h0000_4063;  7: return 32'h0000_5063;  8: return 32'h0000_6063;
            9: return 32'h0000_7063; 10: return 32'h0000_0003; 11: return 32'h0000_1003;
           12: return 32'h0000_2003; 13: return 32'h0000_4003; 14: return 32'h0000_5003;
           15: return 32'h0000_0023; 16: return 32'h0000_1023; 17: return 32'h0000_2023;
           18: return 32'h0000_0013; 19: return 32'h0000_2013; 20: return 32'h0000_3013;
           21: return 32'h0000_4013; 22: return 32'h0000_6013; 23: return 32'h0000_7013;
           24: return 32'h0000_1013; 25: return 32'h0000_5013; 26: return 32'h4000_5013;
           27: return 32'h0000_0033; 28: return 32'h4000_0033; 29: return 32'h0000_1033;
           30: return 32'h0000_2033; 31: return 32'h0000_3033; 32: return 32'h0000_4033;
           33: return 32'h0000_5033; 34: return 32'h4000_5033; 35: return 32'h0000_6033;
           36: return 32'h0000_7033; 37: return 32'h0000_000F; 38: return 32'h0000_0073;
           39: return 32'h0010_0073;
           default: return 32'hFFFF_FFFF;
        endcase
    endfunction

    function automatic mnem_t lookup(logic [31:0] x);
        for (int i = 0; i < N_INSTR; i++)
            if ((x & mask_of(i)) == match_of(i)) return mnem_t'(i);
        return ILLEGAL;
    endfunction

    // ---------------- expected control word per mnemonic ----------------
    function automatic ctrl_t expected(mnem_t m);
        ctrl_t c;
        // the RTL's documented defaults for unused fields
        c = '0;
        c.alu_op = ALU_ADD;  c.src_a = SRC_A_RS1;  c.src_b = SRC_B_RS2;
        c.imm_type = IMM_I;  c.wb_sel = WB_ALU;    c.mem_size = MEM_W;
        c.branch = BR_NONE;

        case (m)
            LUI:   begin c.src_a = SRC_A_ZERO; c.src_b = SRC_B_IMM; c.imm_type = IMM_U; c.reg_write = 1; end
            AUIPC: begin c.src_a = SRC_A_PC;   c.src_b = SRC_B_IMM; c.imm_type = IMM_U; c.reg_write = 1; end
            JAL:   begin c.src_a = SRC_A_PC;   c.src_b = SRC_B_IMM; c.imm_type = IMM_J; c.reg_write = 1;
                           c.wb_sel = WB_PC4; c.jal = 1; end
            JALR:  begin c.src_b = SRC_B_IMM; c.reg_write = 1; c.wb_sel = WB_PC4; c.jalr = 1; end
            BEQ, BNE, BLT, BGE, BLTU, BGEU: begin
                c.src_a = SRC_A_PC; c.src_b = SRC_B_IMM; c.imm_type = IMM_B;
                case (m)
                    BEQ:  c.branch = BR_EQ;   BNE:  c.branch = BR_NE;
                    BLT:  c.branch = BR_LT;   BGE:  c.branch = BR_GE;
                    BLTU: c.branch = BR_LTU;  default: c.branch = BR_GEU;
                endcase
            end
            LB, LH, LW, LBU, LHU: begin
                c.src_b = SRC_B_IMM; c.reg_write = 1; c.wb_sel = WB_MEM; c.mem_read = 1;
                case (m)
                    LB:  c.mem_size = MEM_B;
                    LH:  c.mem_size = MEM_H;
                    LW:  c.mem_size = MEM_W;
                    LBU: begin c.mem_size = MEM_B; c.mem_unsigned = 1; end
                    default: begin c.mem_size = MEM_H; c.mem_unsigned = 1; end
                endcase
            end
            SB, SH, SW: begin
                c.src_b = SRC_B_IMM; c.imm_type = IMM_S; c.mem_write = 1;
                case (m)
                    SB: c.mem_size = MEM_B;  SH: c.mem_size = MEM_H;  default: c.mem_size = MEM_W;
                endcase
            end
            ADDI:  begin c.src_b = SRC_B_IMM; c.reg_write = 1; c.alu_op = ALU_ADD;  end
            SLTI:  begin c.src_b = SRC_B_IMM; c.reg_write = 1; c.alu_op = ALU_SLT;  end
            SLTIU: begin c.src_b = SRC_B_IMM; c.reg_write = 1; c.alu_op = ALU_SLTU; end
            XORI:  begin c.src_b = SRC_B_IMM; c.reg_write = 1; c.alu_op = ALU_XOR;  end
            ORI:   begin c.src_b = SRC_B_IMM; c.reg_write = 1; c.alu_op = ALU_OR;   end
            ANDI:  begin c.src_b = SRC_B_IMM; c.reg_write = 1; c.alu_op = ALU_AND;  end
            SLLI:  begin c.src_b = SRC_B_IMM; c.reg_write = 1; c.alu_op = ALU_SLL;  end
            SRLI:  begin c.src_b = SRC_B_IMM; c.reg_write = 1; c.alu_op = ALU_SRL;  end
            SRAI:  begin c.src_b = SRC_B_IMM; c.reg_write = 1; c.alu_op = ALU_SRA;  end
            ADD:   begin c.reg_write = 1; c.alu_op = ALU_ADD;  end
            SUB:   begin c.reg_write = 1; c.alu_op = ALU_SUB;  end
            SLL:   begin c.reg_write = 1; c.alu_op = ALU_SLL;  end
            SLT:   begin c.reg_write = 1; c.alu_op = ALU_SLT;  end
            SLTU:  begin c.reg_write = 1; c.alu_op = ALU_SLTU; end
            XOR:   begin c.reg_write = 1; c.alu_op = ALU_XOR;  end
            SRL:   begin c.reg_write = 1; c.alu_op = ALU_SRL;  end
            SRA:   begin c.reg_write = 1; c.alu_op = ALU_SRA;  end
            OR:    begin c.reg_write = 1; c.alu_op = ALU_OR;   end
            AND:   begin c.reg_write = 1; c.alu_op = ALU_AND;  end
            FENCE: ;                                  // a NOP: all defaults
            ECALL, EBREAK: c.halt = 1;
            default: c.illegal = 1;                     // no side effects at all
        endcase
        return c;
    endfunction

    // ---------------- decoder check ----------------
    task automatic check_decode(logic [31:0] x);
        mnem_t id;
        ctrl_t exp;
        instr = x;
        #1;
        id  = lookup(x);
        exp = expected(id);
        checks++;
        if (ctrl !== exp) begin
            errors++;
            if (errors <= 20) begin
                $display("FAIL decode %h (%s)", x, id.name());
                // (raw field values: Icarus can't call .name() on struct members)
                $display("     expected {alu,a,b,imm,rw,wb,mr,mw,sz,u,br,jal,jalr,ill,halt} = %h", exp);
                $display("     got                                                    = %h", ctrl);
            end
        end
    endtask

    // ---------------- immediate model (shifts, not concatenation) ----------------
    function automatic logic [31:0] imm_model(imm_type_t t, logic [31:0] x);
        logic signed [31:0] s;
        logic [31:0] top;
        s = x;
        // Sign-extend into its own variable FIRST. Inside a larger expression that
        // mixes in unsigned terms, the whole expression becomes unsigned and >>>
        // quietly turns into a logical shift (SV signedness is per-expression).
        case (t)
            IMM_I: top = s >>> 20;
            IMM_S: top = s >>> 25;
            IMM_B, IMM_J: top = s >>> 31;      // all ones or all zeros
            default: top = '0;
        endcase
        case (t)
            IMM_I: return top;
            IMM_S: return (top << 5) | ((x >> 7) & 32'h1F);
            IMM_B: return (top << 12) | (((x >> 7) & 32'h1) << 11)
                        | (((x >> 25) & 32'h3F) << 5) | (((x >> 8) & 32'hF) << 1);
            IMM_U: return x & 32'hFFFF_F000;
            IMM_J: return (top << 20) | (((x >> 12) & 32'hFF) << 12)
                        | (((x >> 20) & 32'h1) << 11) | (((x >> 21) & 32'h3FF) << 1);
            default: return 32'h0;
        endcase
    endfunction

    task automatic check_imm(imm_type_t t, logic [31:0] x);
        logic [31:0] exp;
        instr    = x;
        imm_type = t;
        #1;
        exp = imm_model(t, x);
        checks++;
        if (imm !== exp) begin
            errors++;
            if (errors <= 20)
                $display("FAIL imm %s instr=%h: expected %h, got %h", t.name(), x, exp, imm);
        end
    endtask

    // ---------------- the test ----------------
    logic [6:0] valid_opcodes [11];

    initial begin
        imm_type = IMM_I;

        // ---- 1. every instruction, random encodings within its mask ----
        for (int i = 0; i < N_INSTR; i++)
            repeat (300)
                check_decode(($urandom & ~mask_of(i)) | match_of(i));

        // ---- 2. fully random words ----
        repeat (20000) check_decode($urandom);

        // ---- 3. random words with a valid opcode ----
        valid_opcodes[0] = OP_LUI;    valid_opcodes[1] = OP_AUIPC;  valid_opcodes[2]  = OP_JAL;
        valid_opcodes[3] = OP_JALR;   valid_opcodes[4] = OP_BRANCH; valid_opcodes[5]  = OP_LOAD;
        valid_opcodes[6] = OP_STORE;  valid_opcodes[7] = OP_IMM;    valid_opcodes[8]  = OP_REG;
        valid_opcodes[9] = OP_MISC_MEM; valid_opcodes[10] = OP_SYSTEM;
        repeat (20000)
            check_decode({$urandom} & 32'hFFFF_FF80 | 32'(valid_opcodes[$urandom_range(0, 10)]));

        // ---- 4. immediates ----
        for (int t = 0; t <= 4; t++) begin
            check_imm(imm_type_t'(t), 32'h8000_0000);   // sign bit only
            check_imm(imm_type_t'(t), 32'h7FFF_FFFF);   // everything but the sign bit
            check_imm(imm_type_t'(t), 32'hFFFF_FFFF);
            check_imm(imm_type_t'(t), 32'h0000_0000);
            repeat (2000) check_imm(imm_type_t'(t), $urandom);
        end

        if (errors == 0)
            $display("TEST PASSED (%0d checks)", checks);
        else
            $fatal(1, "TEST FAILED: %0d of %0d checks failed", errors, checks);
        $finish;
    end

endmodule
