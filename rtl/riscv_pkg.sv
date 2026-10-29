package riscv_pkg;

    // ---------------- ALU ----------------
    typedef enum logic [3:0] {
        ALU_ADD  = 4'd0,
        ALU_SUB  = 4'd1,
        ALU_AND  = 4'd2,
        ALU_OR   = 4'd3,
        ALU_XOR  = 4'd4,
        ALU_SLL  = 4'd5,
        ALU_SRL  = 4'd6,
        ALU_SRA  = 4'd7,
        ALU_SLT  = 4'd8,
        ALU_SLTU = 4'd9
    } alu_op_t;

    // ---------------- opcodes (instr[6:0]) ----------------
    localparam logic [6:0] OP_LUI      = 7'b0110111;
    localparam logic [6:0] OP_AUIPC    = 7'b0010111;
    localparam logic [6:0] OP_JAL      = 7'b1101111;
    localparam logic [6:0] OP_JALR     = 7'b1100111;
    localparam logic [6:0] OP_BRANCH   = 7'b1100011;
    localparam logic [6:0] OP_LOAD     = 7'b0000011;
    localparam logic [6:0] OP_STORE    = 7'b0100011;
    localparam logic [6:0] OP_IMM      = 7'b0010011;
    localparam logic [6:0] OP_REG      = 7'b0110011;
    localparam logic [6:0] OP_MISC_MEM = 7'b0001111;
    localparam logic [6:0] OP_SYSTEM   = 7'b1110011;

    // ---------------- control signal types ----------------
    typedef enum logic [1:0] {
        SRC_A_RS1  = 2'd0,      // register operand
        SRC_A_PC   = 2'd1,      // AUIPC, JAL, branch target
        SRC_A_ZERO = 2'd2       // LUI: 0 + imm
    } src_a_t;

    typedef enum logic {
        SRC_B_RS2 = 1'b0,
        SRC_B_IMM = 1'b1
    } src_b_t;

    typedef enum logic [2:0] {
        IMM_I = 3'd0,
        IMM_S = 3'd1,
        IMM_B = 3'd2,
        IMM_U = 3'd3,
        IMM_J = 3'd4
    } imm_type_t;

    typedef enum logic [1:0] {
        WB_ALU = 2'd0,          // ALU result
        WB_MEM = 2'd1,          // load data
        WB_PC4 = 2'd2           // JAL/JALR link address
    } wb_sel_t;

    typedef enum logic [1:0] {
        MEM_B = 2'd0,
        MEM_H = 2'd1,
        MEM_W = 2'd2
    } mem_size_t;

    // Branch condition, evaluated by branch_cmp on rs1/rs2.
    typedef enum logic [2:0] {
        BR_NONE = 3'd0,
        BR_EQ   = 3'd1,
        BR_NE   = 3'd2,
        BR_LT   = 3'd3,
        BR_GE   = 3'd4,
        BR_LTU  = 3'd5,
        BR_GEU  = 3'd6
    } branch_t;

    // Everything the decoder tells the datapath about one instruction.
    // Unused fields are held at fixed defaults (see decoder.sv) so waveforms
    // and pipeline registers never carry X.
    typedef struct packed {
        alu_op_t   alu_op;
        src_a_t    src_a;
        src_b_t    src_b;
        imm_type_t imm_type;
        logic      reg_write;
        wb_sel_t   wb_sel;
        logic      mem_read;
        logic      mem_write;
        mem_size_t mem_size;
        logic      mem_unsigned;    // LBU / LHU
        branch_t   branch;
        logic      jal;
        logic      jalr;
        logic      illegal;         // not a valid RV32I instruction
        logic      halt;            // ECALL / EBREAK
    } ctrl_t;

endpackage
