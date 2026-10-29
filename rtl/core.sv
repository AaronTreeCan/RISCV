// core.sv - single-cycle RV32I core
//
// Every instruction runs start to finish in one clock cycle:
//   fetch (imem) -> decode -> register read -> ALU / branch compare
//   -> data memory -> writeback, and the PC updates on the rising edge.
//
// The core only sees two buses, so the memory system (soc.sv) can change
// without touching the core:
//   imem: word address out, instruction in (combinational read)
//   dmem: byte address, read/write strobes, 4 byte enables, lane-aligned
//         write data out; whole 32-bit word in (combinational read)
//
// The core does byte/halfword alignment itself (the "load/store unit" below):
//   stores replicate the data into every lane and the byte enables pick the lane
//   loads take the word, select the addressed bytes, then sign/zero extend
//
// Halting: ECALL/EBREAK or an illegal instruction stops the core for good:
// the PC freezes and no more registers or memory are written.

module core
    import riscv_pkg::*;
(
    input  logic        clk,
    input  logic        rst,            // synchronous, active high; PC -> 0

    // instruction bus
    output logic [31:0] imem_addr,
    input  logic [31:0] imem_rdata,

    // data bus
    output logic [31:0] dmem_addr,
    output logic        dmem_re,
    output logic        dmem_we,
    output logic [3:0]  dmem_be,
    output logic [31:0] dmem_wdata,
    input  logic [31:0] dmem_rdata,

    // status
    output logic        halted,         // stopped by ECALL / EBREAK
    output logic        illegal         // stopped by an illegal instruction
);

    // ---------------- fetch ----------------
    logic [31:0] pc, pc_next, pc_plus4;
    logic [31:0] instr;

    assign imem_addr = pc;
    assign instr     = imem_rdata;
    assign pc_plus4  = pc + 32'd4;

    // ---------------- decode ----------------
    ctrl_t       ctrl;
    logic [31:0] imm;
    logic [4:0]  rs1, rs2, rd;

    assign rs1 = instr[19:15];
    assign rs2 = instr[24:20];
    assign rd  = instr[11:7];

    decoder u_decoder (.instr(instr), .ctrl(ctrl));
    imm_gen u_imm_gen (.instr(instr), .imm_type(ctrl.imm_type), .imm(imm));

    // stopped = already halted, or this instruction halts us right now
    logic stop;
    assign stop = halted || illegal || ctrl.halt || ctrl.illegal;

    // ---------------- register file ----------------
    logic [1:0][31:0] rf_rdata;
    logic [31:0]      rs1_val, rs2_val, wb_data;
    logic             rf_we;

    assign rf_we = ctrl.reg_write && !stop;

    regfile #(.NUM_READ(2), .NUM_WRITE(1)) u_regfile (
        .clk   (clk),
        .raddr ({rs2, rs1}),
        .rdata (rf_rdata),
        .we    (rf_we),
        .waddr (rd),
        .wdata (wb_data)
    );

    assign rs1_val = rf_rdata[0];
    assign rs2_val = rf_rdata[1];

    // ---------------- execute ----------------
    logic [31:0] alu_a, alu_b, alu_result;
    logic        branch_taken;

    always_comb begin
        case (ctrl.src_a)
            SRC_A_PC:   alu_a = pc;
            SRC_A_ZERO: alu_a = 32'd0;
            default:    alu_a = rs1_val;
        endcase
        alu_b = (ctrl.src_b == SRC_B_IMM) ? imm : rs2_val;
    end

    alu        u_alu (.a(alu_a), .b(alu_b), .op(ctrl.alu_op), .result(alu_result));
    branch_cmp u_br  (.a(rs1_val), .b(rs2_val), .branch(ctrl.branch), .taken(branch_taken));

    // ---------------- next PC ----------------
    // JAL and taken branches: the ALU already computed PC + imm.
    // JALR: the ALU computed rs1 + imm; the spec clears bit 0.
    always_comb begin
        if (ctrl.jalr)                     pc_next = {alu_result[31:1], 1'b0};
        else if (ctrl.jal || branch_taken) pc_next = alu_result;
        else                               pc_next = pc_plus4;
    end

    always_ff @(posedge clk) begin
        if (rst)        pc <= 32'd0;
        else if (!stop) pc <= pc_next;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            halted  <= 1'b0;
            illegal <= 1'b0;
        end else begin
            if (ctrl.halt)    halted  <= 1'b1;
            if (ctrl.illegal) illegal <= 1'b1;
        end
    end

    // ---------------- load/store unit ----------------
    logic [1:0]  byte_off;
    logic [31:0] load_data;
    logic [7:0]  ld_byte;
    logic [15:0] ld_half;

    assign dmem_addr = alu_result;
    assign byte_off  = alu_result[1:0];
    assign dmem_re   = ctrl.mem_read  && !stop;
    assign dmem_we   = ctrl.mem_write && !stop;

    // Stores: copy the data into every lane it could land in; the byte
    // enables decide which lanes memory actually writes. No shifter needed.
    always_comb begin
        case (ctrl.mem_size)
            MEM_B: begin
                dmem_wdata = {4{rs2_val[7:0]}};
                dmem_be    = 4'b0001 << byte_off;
            end
            MEM_H: begin
                dmem_wdata = {2{rs2_val[15:0]}};
                dmem_be    = byte_off[1] ? 4'b1100 : 4'b0011;
            end
            default: begin
                dmem_wdata = rs2_val;
                dmem_be    = 4'b1111;
            end
        endcase
    end

    // Loads: pick the addressed byte / halfword out of the word, then extend.
    always_comb begin
        case (byte_off)
            2'd0:    ld_byte = dmem_rdata[7:0];
            2'd1:    ld_byte = dmem_rdata[15:8];
            2'd2:    ld_byte = dmem_rdata[23:16];
            default: ld_byte = dmem_rdata[31:24];
        endcase
        ld_half = byte_off[1] ? dmem_rdata[31:16] : dmem_rdata[15:0];

        case (ctrl.mem_size)
            MEM_B:   load_data = ctrl.mem_unsigned ? {24'd0, ld_byte} : {{24{ld_byte[7]}}, ld_byte};
            MEM_H:   load_data = ctrl.mem_unsigned ? {16'd0, ld_half} : {{16{ld_half[15]}}, ld_half};
            default: load_data = dmem_rdata;
        endcase
    end

    // ---------------- writeback ----------------
    always_comb begin
        case (ctrl.wb_sel)
            WB_MEM:  wb_data = load_data;
            WB_PC4:  wb_data = pc_plus4;
            default: wb_data = alu_result;
        endcase
    end

`ifndef SYNTHESIS
    // No trap support yet, so anything that would trap is a simulation error.
    always @(posedge clk) begin
        if (!rst && !stop) begin
            if ((ctrl.mem_read || ctrl.mem_write) &&
                ((ctrl.mem_size == MEM_H && byte_off[0]) ||
                 (ctrl.mem_size == MEM_W && byte_off != 2'd0)))
                $error("core: misaligned %s at pc=%h addr=%h",
                       ctrl.mem_write ? "store" : "load", pc, alu_result);
            if (pc_next[1:0] != 2'd0)
                $error("core: misaligned jump/branch target %h at pc=%h", pc_next, pc);
        end
    end
`endif

endmodule
