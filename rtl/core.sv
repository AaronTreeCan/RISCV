// core.sv - 5-stage pipelined RV32I core
//
//   IF   fetch at pc_f
//   ID   decode, immediate, register read (+ bypass from WB)
//   EX   ALU, branch compare, jump/branch target -> redirect (+ forwarding)
//   MEM  data memory access, load alignment; ECALL/illegal take effect here
//   WB   register write, instruction retires
//
// Hazards:
//   data      forward EX/MEM and MEM/WB results into EX; bypass WB into ID
//             (the register file has no write-before-read)
//   load-use  a load's data exists only after MEM, so an instruction that
//             needs it right behind the load stalls in ID for 1 cycle
//   control   predict not-taken: keep fetching pc+4; a taken branch or jump
//             is known in EX and flushes the 2 younger instructions in IF/ID
//   stop      ECALL/EBREAK/illegal stop the core precisely: when one reaches
//             MEM everything older has finished (or is finishing in WB), so
//             we flush everything younger and stop fetching. It then retires
//             from WB and sets halted/illegal.
//
// Same buses and status outputs as the single-cycle core (core_sc.sv), plus a
// retire port used by the testbench to check the two cores against each other.

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
    output logic        illegal,        // stopped by an illegal instruction
    output retire_t     retire          // the instruction leaving WB this cycle
);

    // ================= pipeline registers =================
    // Each stage register carries a valid bit. A bubble (valid = 0) does
    // nothing: no register write, no memory access, no redirect, no retire.

    typedef struct packed {
        logic        valid;
        logic [31:0] pc;
        logic [31:0] instr;
    } if_id_t;

    typedef struct packed {
        logic        valid;
        logic [31:0] pc;
        logic [31:0] instr;
        ctrl_t       ctrl;
        logic [31:0] imm;
        logic [4:0]  rs1, rs2, rd;
        logic [31:0] rs1_val, rs2_val;
    } id_ex_t;

    typedef struct packed {
        logic        valid;
        logic [31:0] pc;
        logic [31:0] instr;
        ctrl_t       ctrl;
        logic [4:0]  rd;
        logic [31:0] alu_result;        // memory address for loads/stores
        logic [31:0] ex_value;          // value to write back if not a load
        logic [31:0] store_data;        // rs2 after forwarding
    } ex_mem_t;

    typedef struct packed {
        logic        valid;
        logic [31:0] pc;
        logic [31:0] instr;
        logic        reg_write;
        logic [4:0]  rd;
        logic [31:0] wb_data;
        logic        halt;
        logic        illegal;
        logic        mem_we;            // store info, kept only for retire
        logic [31:0] mem_addr;
        logic [3:0]  mem_be;
        logic [31:0] mem_wdata;
    } mem_wb_t;

    if_id_t  if_id;
    id_ex_t  id_ex;
    ex_mem_t ex_mem;
    mem_wb_t mem_wb;

    // hazard / control signals (computed below)
    logic        stall_id;          // load-use: hold PC and IF/ID, bubble into EX
    logic        redirect;          // taken branch or jump in EX
    logic [31:0] redirect_pc;
    logic        stop_mem;          // ECALL / illegal in MEM: flush younger
    logic        stopping;          // sticky: a stop is in progress, fetch no more

    // ================= IF =================
    logic [31:0] pc_f;

    assign imem_addr = pc_f;

    always_ff @(posedge clk) begin
        if (rst)                         pc_f <= 32'd0;
        else if (stop_mem || stopping)   pc_f <= pc_f;          // frozen for good
        else if (redirect)               pc_f <= redirect_pc;
        else if (!stall_id)              pc_f <= pc_f + 32'd4;
    end

    always_ff @(posedge clk) begin
        if (rst || stop_mem || stopping || redirect) begin
            if_id.valid <= 1'b0;
            if_id.pc    <= 32'd0;
            if_id.instr <= 32'd0;
        end else if (!stall_id) begin
            if_id.valid <= 1'b1;
            if_id.pc    <= pc_f;
            if_id.instr <= imem_rdata;
        end
    end

    // ================= ID =================
    ctrl_t       ctrl_d;
    logic [31:0] imm_d;
    logic [4:0]  rs1_d, rs2_d, rd_d;
    logic [1:0][31:0] rf_rdata;
    logic [31:0] rs1_val_d, rs2_val_d;
    logic        uses_rs1, uses_rs2;

    assign rs1_d = if_id.instr[19:15];
    assign rs2_d = if_id.instr[24:20];
    assign rd_d  = if_id.instr[11:7];

    decoder u_decoder (.instr(if_id.instr), .ctrl(ctrl_d));
    imm_gen u_imm_gen (.instr(if_id.instr), .imm_type(ctrl_d.imm_type), .imm(imm_d));

    // WB writes the register file (port is driven from the MEM/WB register)
    logic rf_we_w;
    assign rf_we_w = mem_wb.valid && mem_wb.reg_write;

    regfile #(.NUM_READ(2), .NUM_WRITE(1)) u_regfile (
        .clk   (clk),
        .raddr ({rs2_d, rs1_d}),
        .rdata (rf_rdata),
        .we    (rf_we_w),
        .waddr (mem_wb.rd),
        .wdata (mem_wb.wb_data)
    );

    // WB -> ID bypass: the register file returns the old value during the
    // cycle it is being written, so take the value from WB directly.
    always_comb begin
        rs1_val_d = rf_rdata[0];
        rs2_val_d = rf_rdata[1];
        if (rf_we_w && mem_wb.rd != 5'd0 && mem_wb.rd == rs1_d) rs1_val_d = mem_wb.wb_data;
        if (rf_we_w && mem_wb.rd != 5'd0 && mem_wb.rd == rs2_d) rs2_val_d = mem_wb.wb_data;
    end

    // Which source registers this instruction actually reads. Over-stalling
    // on an unused field would only cost a cycle; this avoids it.
    assign uses_rs1 = (ctrl_d.src_a == SRC_A_RS1) || (ctrl_d.branch != BR_NONE);
    assign uses_rs2 = (ctrl_d.src_b == SRC_B_RS2) || (ctrl_d.branch != BR_NONE) || ctrl_d.mem_write;

    // Load-use hazard: the instruction in EX is a load whose result we need.
    assign stall_id = if_id.valid && id_ex.valid && id_ex.ctrl.mem_read && (id_ex.rd != 5'd0) &&
                      ((uses_rs1 && id_ex.rd == rs1_d) || (uses_rs2 && id_ex.rd == rs2_d));

    always_ff @(posedge clk) begin
        // a stall leaves a bubble in EX while ID holds its instruction
        if (rst || stop_mem || stopping || redirect || stall_id) begin
            id_ex <= '0;
        end else begin
            id_ex.valid   <= if_id.valid;
            id_ex.pc      <= if_id.pc;
            id_ex.instr   <= if_id.instr;
            id_ex.ctrl    <= ctrl_d;
            id_ex.imm     <= imm_d;
            id_ex.rs1     <= rs1_d;
            id_ex.rs2     <= rs2_d;
            id_ex.rd      <= rd_d;
            id_ex.rs1_val <= rs1_val_d;
            id_ex.rs2_val <= rs2_val_d;
        end
    end

    // ================= EX =================
    logic [31:0] rs1_val_e, rs2_val_e;
    logic [31:0] alu_a, alu_b, alu_result_e, pc_plus4_e, ex_value_e;
    logic        branch_taken_e;
    logic        fwd_mem_ok;

    // Forwarding. The newest value wins: MEM (one instruction older) beats
    // WB (two older). A load in MEM has no data yet; the load-use stall
    // guarantees nobody in EX needs it, so it is never forwarded from MEM.
    assign fwd_mem_ok = ex_mem.valid && ex_mem.ctrl.reg_write && !ex_mem.ctrl.mem_read &&
                        (ex_mem.rd != 5'd0);

    always_comb begin
        rs1_val_e = id_ex.rs1_val;
        if (fwd_mem_ok && ex_mem.rd == id_ex.rs1)                     rs1_val_e = ex_mem.ex_value;
        else if (rf_we_w && mem_wb.rd != 5'd0 && mem_wb.rd == id_ex.rs1) rs1_val_e = mem_wb.wb_data;

        rs2_val_e = id_ex.rs2_val;
        if (fwd_mem_ok && ex_mem.rd == id_ex.rs2)                     rs2_val_e = ex_mem.ex_value;
        else if (rf_we_w && mem_wb.rd != 5'd0 && mem_wb.rd == id_ex.rs2) rs2_val_e = mem_wb.wb_data;
    end

    always_comb begin
        case (id_ex.ctrl.src_a)
            SRC_A_PC:   alu_a = id_ex.pc;
            SRC_A_ZERO: alu_a = 32'd0;
            default:    alu_a = rs1_val_e;
        endcase
        alu_b = (id_ex.ctrl.src_b == SRC_B_IMM) ? id_ex.imm : rs2_val_e;
    end

    alu        u_alu (.a(alu_a), .b(alu_b), .op(id_ex.ctrl.alu_op), .result(alu_result_e));
    branch_cmp u_br  (.a(rs1_val_e), .b(rs2_val_e), .branch(id_ex.ctrl.branch), .taken(branch_taken_e));

    assign pc_plus4_e = id_ex.pc + 32'd4;
    assign ex_value_e = (id_ex.ctrl.wb_sel == WB_PC4) ? pc_plus4_e : alu_result_e;

    // Branch / jump resolution. Fetch assumed not-taken, so any taken
    // branch or jump redirects and squashes the 2 instructions behind it.
    assign redirect    = id_ex.valid && (id_ex.ctrl.jal || id_ex.ctrl.jalr || branch_taken_e);
    assign redirect_pc = id_ex.ctrl.jalr ? {alu_result_e[31:1], 1'b0} : alu_result_e;

    always_ff @(posedge clk) begin
        if (rst || stop_mem || stopping) begin
            ex_mem <= '0;
        end else begin
            ex_mem.valid      <= id_ex.valid;
            ex_mem.pc         <= id_ex.pc;
            ex_mem.instr      <= id_ex.instr;
            ex_mem.ctrl       <= id_ex.ctrl;
            ex_mem.rd         <= id_ex.rd;
            ex_mem.alu_result <= alu_result_e;
            ex_mem.ex_value   <= ex_value_e;
            ex_mem.store_data <= rs2_val_e;
        end
    end

    // ================= MEM =================
    logic [1:0]  byte_off;
    logic [7:0]  ld_byte;
    logic [15:0] ld_half;
    logic [31:0] load_data;

    // The stop point: an ECALL / illegal instruction here is the oldest
    // instruction not yet finished, so everything younger can be thrown away.
    assign stop_mem = ex_mem.valid && (ex_mem.ctrl.halt || ex_mem.ctrl.illegal);

    always_ff @(posedge clk) begin
        if (rst)           stopping <= 1'b0;
        else if (stop_mem) stopping <= 1'b1;
    end

    assign dmem_addr = ex_mem.alu_result;
    assign byte_off  = ex_mem.alu_result[1:0];
    assign dmem_re   = ex_mem.valid && ex_mem.ctrl.mem_read;
    assign dmem_we   = ex_mem.valid && ex_mem.ctrl.mem_write;

    // Stores: replicate into every lane; byte enables pick the lane(s).
    always_comb begin
        case (ex_mem.ctrl.mem_size)
            MEM_B: begin
                dmem_wdata = {4{ex_mem.store_data[7:0]}};
                dmem_be    = 4'b0001 << byte_off;
            end
            MEM_H: begin
                dmem_wdata = {2{ex_mem.store_data[15:0]}};
                dmem_be    = byte_off[1] ? 4'b1100 : 4'b0011;
            end
            default: begin
                dmem_wdata = ex_mem.store_data;
                dmem_be    = 4'b1111;
            end
        endcase
    end

    // Loads: select the addressed byte / halfword, then sign or zero extend.
    always_comb begin
        case (byte_off)
            2'd0:    ld_byte = dmem_rdata[7:0];
            2'd1:    ld_byte = dmem_rdata[15:8];
            2'd2:    ld_byte = dmem_rdata[23:16];
            default: ld_byte = dmem_rdata[31:24];
        endcase
        ld_half = byte_off[1] ? dmem_rdata[31:16] : dmem_rdata[15:0];

        case (ex_mem.ctrl.mem_size)
            MEM_B:   load_data = ex_mem.ctrl.mem_unsigned ? {24'd0, ld_byte} : {{24{ld_byte[7]}}, ld_byte};
            MEM_H:   load_data = ex_mem.ctrl.mem_unsigned ? {16'd0, ld_half} : {{16{ld_half[15]}}, ld_half};
            default: load_data = dmem_rdata;
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            mem_wb <= '0;
        end else begin
            mem_wb.valid     <= ex_mem.valid;
            mem_wb.pc        <= ex_mem.pc;
            mem_wb.instr     <= ex_mem.instr;
            mem_wb.reg_write <= ex_mem.valid && ex_mem.ctrl.reg_write;
            mem_wb.rd        <= ex_mem.rd;
            mem_wb.wb_data   <= (ex_mem.ctrl.wb_sel == WB_MEM) ? load_data : ex_mem.ex_value;
            mem_wb.halt      <= ex_mem.valid && ex_mem.ctrl.halt;
            mem_wb.illegal   <= ex_mem.valid && ex_mem.ctrl.illegal;
            mem_wb.mem_we    <= dmem_we;
            mem_wb.mem_addr  <= dmem_addr;
            mem_wb.mem_be    <= dmem_be;
            mem_wb.mem_wdata <= dmem_wdata;
        end
    end

    // ================= WB =================
    always_ff @(posedge clk) begin
        if (rst) begin
            halted  <= 1'b0;
            illegal <= 1'b0;
        end else begin
            if (mem_wb.valid && mem_wb.halt)    halted  <= 1'b1;
            if (mem_wb.valid && mem_wb.illegal) illegal <= 1'b1;
        end
    end

    always_comb begin
        retire           = '0;
        retire.valid     = mem_wb.valid;
        retire.pc        = mem_wb.pc;
        retire.instr     = mem_wb.instr;
        retire.rd_we     = rf_we_w && (mem_wb.rd != 5'd0);
        retire.rd        = mem_wb.rd;
        retire.rd_wdata  = mem_wb.wb_data;
        retire.mem_we    = mem_wb.mem_we;
        retire.mem_addr  = mem_wb.mem_addr;
        retire.mem_be    = mem_wb.mem_be;
        retire.mem_wdata = mem_wb.mem_wdata;
    end

`ifndef SYNTHESIS
    // No trap support yet, so anything that would trap is a simulation error.
    // Checked only where the instruction is certain to complete.
    always @(posedge clk) begin
        if (!rst) begin
            if ((dmem_re || dmem_we) &&
                ((ex_mem.ctrl.mem_size == MEM_H && byte_off[0]) ||
                 (ex_mem.ctrl.mem_size == MEM_W && byte_off != 2'd0)))
                $error("core: misaligned %s at pc=%h addr=%h",
                       dmem_we ? "store" : "load", ex_mem.pc, dmem_addr);
            if (redirect && !stop_mem && redirect_pc[1:0] != 2'd0)
                $error("core: misaligned jump/branch target %h at pc=%h", redirect_pc, id_ex.pc);
        end
    end
`endif

endmodule
