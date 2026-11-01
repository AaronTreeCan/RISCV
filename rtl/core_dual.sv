// core_dual.sv - in-order dual-issue RV32I core (5 stages, 2 lanes)
//
//            IF        ID           EX            MEM          WB
//   lane 0   pair  ->  any instr -> ALU, branch -> data memory -> regfile port 0
//   lane 1   fetch ->  ALU only  -> ALU         -> (pass)      -> regfile port 1
//
// Lane 0 always holds the older instruction of a pair. Lane 1 only takes
// ALU instructions (R/I-type, LUI, AUIPC), so there is one data-memory port
// and at most one branch/jump resolving per cycle.
//
// Fetch: the instruction bus returns an aligned pair (8 bytes). After a jump
// to the second word of a pair, only that word is fetched.
//
// Issue (in ID), the pair goes together only if:
//   - the second instruction is ALU-only
//   - it doesn't read the first one's destination (read-after-write)
//   - neither one needs the result of a load that is in EX (load-use)
//   - the first isn't ECALL/EBREAK/illegal (those always issue alone)
// Otherwise the first issues alone and the second moves up to become the
// first next cycle (fetch waits). Two writes to the same register in one
// pair are fine: regfile port 1 (the younger lane) wins.
//
// Forwarding: 4 producers (MEM and WB, both lanes) feed 4 operands; the
// youngest producer wins. WB is also bypassed into ID.
// Branches: predict not-taken, resolve in EX lane 0. A taken branch flushes
// IF/ID and ID/EX and also kills its own lane-1 partner (younger).
// Stops: ECALL/EBREAK/illegal take effect in MEM like the scalar pipeline.

module core_dual
    import riscv_pkg::*;
(
    input  logic        clk,
    input  logic        rst,            // synchronous, active high; PC -> 0

    // instruction bus: 8-byte aligned address, {word at +4, word at +0}
    output logic [31:0] imem_addr,
    input  logic [63:0] imem_rdata,

    // data bus (lane 0 only)
    output logic [31:0] dmem_addr,
    output logic        dmem_re,
    output logic        dmem_we,
    output logic [3:0]  dmem_be,
    output logic [31:0] dmem_wdata,
    input  logic [31:0] dmem_rdata,

    // status
    output logic        halted,
    output logic        illegal,
    output retire_t     retire0,        // older instruction retiring this cycle
    output retire_t     retire1         // younger one (only if retire0 is valid)
);

    // ================= pipeline register types =================
    typedef struct packed {
        logic        valid;
        logic [31:0] pc;
        logic [31:0] instr;
    } slot_t;

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
        logic [31:0] alu_result;
        logic [31:0] ex_value;          // value to write back if not a load
        logic [31:0] store_data;
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

    slot_t   d0, d1;            // IF/ID: the pair waiting in decode
    id_ex_t  e0, e1;            // ID/EX
    ex_mem_t m0;                // EX/MEM
    mem_wb_t w0;                // MEM/WB
    // Lane 1 reuses the same register types for symmetry; its memory fields
    // stay 0 and synthesis removes them, so lint shouldn't flag them.
    /* verilator lint_off UNUSEDSIGNAL */
    ex_mem_t m1;
    mem_wb_t w1;
    /* verilator lint_on UNUSEDSIGNAL */

    // Does this instruction read rs1 / rs2? (same rule as the scalar pipeline)
    // Each helper looks at a few fields of the control word, hence the lint_off.
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic logic uses_rs1(input ctrl_t c);
        return (c.src_a == SRC_A_RS1) || (c.branch != BR_NONE);
    endfunction
    function automatic logic uses_rs2(input ctrl_t c);
        return (c.src_b == SRC_B_RS2) || (c.branch != BR_NONE) || c.mem_write;
    endfunction
    // Can it run in lane 1?
    function automatic logic alu_only(input ctrl_t c);
        return !c.mem_read && !c.mem_write && (c.branch == BR_NONE) &&
               !c.jal && !c.jalr && !c.halt && !c.illegal;
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    logic        redirect;          // taken branch / jump in EX lane 0
    logic [31:0] redirect_pc;
    logic        stop_mem;          // ECALL / illegal in MEM lane 0
    logic        stopping;          // sticky after stop_mem
    logic        flush_front;       // kill IF/ID and ID/EX
    logic        hold_d0;           // load-use on the first instruction: freeze front end
    logic        split;             // first issues alone, second moves up

    assign flush_front = stop_mem || stopping || redirect;

    // ================= IF =================
    logic [31:0] pc_f;
    slot_t       f0, f1;

    assign imem_addr = {pc_f[31:3], 3'b000};

    always_comb begin
        // a fetch at the second word of a pair yields one instruction
        f0.valid = 1'b1;
        f0.pc    = pc_f;
        f0.instr = pc_f[2] ? imem_rdata[63:32] : imem_rdata[31:0];
        f1.valid = !pc_f[2];
        f1.pc    = pc_f + 32'd4;
        f1.instr = imem_rdata[63:32];
    end

    always_ff @(posedge clk) begin
        if (rst)                        pc_f <= 32'd0;
        else if (stop_mem || stopping)  pc_f <= pc_f;
        else if (redirect)              pc_f <= redirect_pc;
        else if (!hold_d0 && !split)    pc_f <= {pc_f[31:3], 3'b000} + 32'd8;
    end

    always_ff @(posedge clk) begin
        if (rst || flush_front) begin
            d0 <= '0;
            d1 <= '0;
        end else if (hold_d0) begin
            // keep both
        end else if (split) begin
            d0 <= d1;
            d1 <= '0;
        end else begin
            d0 <= f0;
            d1 <= f1;
        end
    end

    // ================= ID =================
    ctrl_t       c0, c1;
    logic [31:0] imm0, imm1;
    logic [4:0]  rs1_0, rs2_0, rd_0, rs1_1, rs2_1, rd_1;
    logic [3:0][31:0] rf_rdata;
    logic [31:0] r1_0, r2_0, r1_1, r2_1;        // operands after the WB bypass
    logic        lu0, lu1, raw01, pair_ok, issue0, issue1;

    assign rs1_0 = d0.instr[19:15];
    assign rs2_0 = d0.instr[24:20];
    assign rd_0  = d0.instr[11:7];
    assign rs1_1 = d1.instr[19:15];
    assign rs2_1 = d1.instr[24:20];
    assign rd_1  = d1.instr[11:7];

    decoder u_dec0 (.instr(d0.instr), .ctrl(c0));
    decoder u_dec1 (.instr(d1.instr), .ctrl(c1));
    imm_gen u_imm0 (.instr(d0.instr), .imm_type(c0.imm_type), .imm(imm0));
    imm_gen u_imm1 (.instr(d1.instr), .imm_type(c1.imm_type), .imm(imm1));

    // WB write ports: port 1 (lane 1, younger) wins on the same register
    logic w0_we, w1_we;
    assign w0_we = w0.valid && w0.reg_write;
    assign w1_we = w1.valid && w1.reg_write;

    regfile #(.NUM_READ(4), .NUM_WRITE(2)) u_regfile (
        .clk   (clk),
        .raddr ({rs2_1, rs1_1, rs2_0, rs1_0}),
        .rdata (rf_rdata),
        .we    ({w1_we, w0_we}),
        .waddr ({w1.rd, w0.rd}),
        .wdata ({w1.wb_data, w0.wb_data})
    );

    // WB -> ID bypass (lane 1 is younger, so it is checked first)
    function automatic logic [31:0] bypass(input logic [4:0] r, input logic [31:0] rf_val,
                                           input logic we1, input logic [4:0] rd1, input logic [31:0] v1,
                                           input logic we0, input logic [4:0] rd0, input logic [31:0] v0);
        if (r != 5'd0 && we1 && rd1 == r) return v1;
        if (r != 5'd0 && we0 && rd0 == r) return v0;
        return rf_val;
    endfunction

    always_comb begin
        r1_0 = bypass(rs1_0, rf_rdata[0], w1_we, w1.rd, w1.wb_data, w0_we, w0.rd, w0.wb_data);
        r2_0 = bypass(rs2_0, rf_rdata[1], w1_we, w1.rd, w1.wb_data, w0_we, w0.rd, w0.wb_data);
        r1_1 = bypass(rs1_1, rf_rdata[2], w1_we, w1.rd, w1.wb_data, w0_we, w0.rd, w0.wb_data);
        r2_1 = bypass(rs2_1, rf_rdata[3], w1_we, w1.rd, w1.wb_data, w0_we, w0.rd, w0.wb_data);
    end

    // Load-use: only lane 0 has loads, so only e0 can be the producer.
    logic e0_load;
    assign e0_load = e0.valid && e0.ctrl.mem_read && (e0.rd != 5'd0);
    assign lu0 = d0.valid && e0_load &&
                 ((uses_rs1(c0) && e0.rd == rs1_0) || (uses_rs2(c0) && e0.rd == rs2_0));
    assign lu1 = d1.valid && e0_load &&
                 ((uses_rs1(c1) && e0.rd == rs1_1) || (uses_rs2(c1) && e0.rd == rs2_1));

    // Read-after-write inside the pair: the second needs the first's result,
    // which doesn't exist until the end of EX. No forwarding path can help.
    assign raw01 = c0.reg_write && (rd_0 != 5'd0) &&
                   ((uses_rs1(c1) && rs1_1 == rd_0) || (uses_rs2(c1) && rs2_1 == rd_0));

    assign pair_ok = d1.valid && alu_only(c1) && !raw01 && !lu1 && !c0.halt && !c0.illegal;
    assign issue0  = d0.valid && !lu0;
    assign issue1  = issue0 && pair_ok;
    assign hold_d0 = d0.valid && lu0;
    assign split   = issue0 && d1.valid && !issue1;

    always_ff @(posedge clk) begin
        if (rst || flush_front) begin
            e0 <= '0;
            e1 <= '0;
        end else begin
            if (issue0) begin
                e0.valid   <= 1'b1;
                e0.pc      <= d0.pc;
                e0.instr   <= d0.instr;
                e0.ctrl    <= c0;
                e0.imm     <= imm0;
                e0.rs1     <= rs1_0;
                e0.rs2     <= rs2_0;
                e0.rd      <= rd_0;
                e0.rs1_val <= r1_0;
                e0.rs2_val <= r2_0;
            end else begin
                e0 <= '0;
            end
            if (issue1) begin
                e1.valid   <= 1'b1;
                e1.pc      <= d1.pc;
                e1.instr   <= d1.instr;
                e1.ctrl    <= c1;
                e1.imm     <= imm1;
                e1.rs1     <= rs1_1;
                e1.rs2     <= rs2_1;
                e1.rd      <= rd_1;
                e1.rs1_val <= r1_1;
                e1.rs2_val <= r2_1;
            end else begin
                e1 <= '0;
            end
        end
    end

    // ================= EX =================
    // Producers, youngest first: MEM lane 1, MEM lane 0 (not a load), WB lane 1, WB lane 0
    logic m0_fwd, m1_fwd, w0_fwd, w1_fwd;
    assign m1_fwd = m1.valid && m1.ctrl.reg_write && (m1.rd != 5'd0);
    assign m0_fwd = m0.valid && m0.ctrl.reg_write && !m0.ctrl.mem_read && (m0.rd != 5'd0);
    assign w1_fwd = w1_we && (w1.rd != 5'd0);
    assign w0_fwd = w0_we && (w0.rd != 5'd0);

    function automatic logic [31:0] fwd(input logic [4:0] r, input logic [31:0] base,
                                        input logic m1_ok, input logic [4:0] m1_rd, input logic [31:0] m1_v,
                                        input logic m0_ok, input logic [4:0] m0_rd, input logic [31:0] m0_v,
                                        input logic w1_ok, input logic [4:0] w1_rd, input logic [31:0] w1_v,
                                        input logic w0_ok, input logic [4:0] w0_rd, input logic [31:0] w0_v);
        if (m1_ok && m1_rd == r) return m1_v;
        if (m0_ok && m0_rd == r) return m0_v;
        if (w1_ok && w1_rd == r) return w1_v;
        if (w0_ok && w0_rd == r) return w0_v;
        return base;
    endfunction

    logic [31:0] a1_0, a2_0, a1_1, a2_1;        // forwarded rs1/rs2 values
    always_comb begin
        a1_0 = fwd(e0.rs1, e0.rs1_val, m1_fwd, m1.rd, m1.ex_value, m0_fwd, m0.rd, m0.ex_value,
                   w1_fwd, w1.rd, w1.wb_data, w0_fwd, w0.rd, w0.wb_data);
        a2_0 = fwd(e0.rs2, e0.rs2_val, m1_fwd, m1.rd, m1.ex_value, m0_fwd, m0.rd, m0.ex_value,
                   w1_fwd, w1.rd, w1.wb_data, w0_fwd, w0.rd, w0.wb_data);
        a1_1 = fwd(e1.rs1, e1.rs1_val, m1_fwd, m1.rd, m1.ex_value, m0_fwd, m0.rd, m0.ex_value,
                   w1_fwd, w1.rd, w1.wb_data, w0_fwd, w0.rd, w0.wb_data);
        a2_1 = fwd(e1.rs2, e1.rs2_val, m1_fwd, m1.rd, m1.ex_value, m0_fwd, m0.rd, m0.ex_value,
                   w1_fwd, w1.rd, w1.wb_data, w0_fwd, w0.rd, w0.wb_data);
    end

    // lane 0: full execute
    logic [31:0] alu_a0, alu_b0, alu_y0, ex_value0;
    logic        taken0;
    always_comb begin
        case (e0.ctrl.src_a)
            SRC_A_PC:   alu_a0 = e0.pc;
            SRC_A_ZERO: alu_a0 = 32'd0;
            default:    alu_a0 = a1_0;
        endcase
        alu_b0 = (e0.ctrl.src_b == SRC_B_IMM) ? e0.imm : a2_0;
    end
    alu        u_alu0 (.a(alu_a0), .b(alu_b0), .op(e0.ctrl.alu_op), .result(alu_y0));
    branch_cmp u_br0  (.a(a1_0), .b(a2_0), .branch(e0.ctrl.branch), .taken(taken0));
    assign ex_value0 = (e0.ctrl.wb_sel == WB_PC4) ? (e0.pc + 32'd4) : alu_y0;

    assign redirect    = e0.valid && (e0.ctrl.jal || e0.ctrl.jalr || taken0);
    assign redirect_pc = e0.ctrl.jalr ? {alu_y0[31:1], 1'b0} : alu_y0;

    // lane 1: ALU only
    logic [31:0] alu_a1, alu_b1, alu_y1;
    always_comb begin
        case (e1.ctrl.src_a)
            SRC_A_PC:   alu_a1 = e1.pc;
            SRC_A_ZERO: alu_a1 = 32'd0;
            default:    alu_a1 = a1_1;
        endcase
        alu_b1 = (e1.ctrl.src_b == SRC_B_IMM) ? e1.imm : a2_1;
    end
    alu u_alu1 (.a(alu_a1), .b(alu_b1), .op(e1.ctrl.alu_op), .result(alu_y1));

    always_ff @(posedge clk) begin
        if (rst || stop_mem || stopping) begin
            m0 <= '0;
            m1 <= '0;
        end else begin
            m0.valid      <= e0.valid;
            m0.pc         <= e0.pc;
            m0.instr      <= e0.instr;
            m0.ctrl       <= e0.ctrl;
            m0.rd         <= e0.rd;
            m0.alu_result <= alu_y0;
            m0.ex_value   <= ex_value0;
            m0.store_data <= a2_0;

            // a taken branch in lane 0 kills its younger partner in lane 1
            m1.valid      <= e1.valid && !redirect;
            m1.pc         <= e1.pc;
            m1.instr      <= e1.instr;
            m1.ctrl       <= e1.ctrl;
            m1.rd         <= e1.rd;
            m1.alu_result <= alu_y1;
            m1.ex_value   <= alu_y1;
            m1.store_data <= '0;
        end
    end

    // ================= MEM (lane 0 does the memory access) =================
    logic [1:0]  byte_off;
    logic [7:0]  ld_byte;
    logic [15:0] ld_half;
    logic [31:0] load_data;

    assign stop_mem = m0.valid && (m0.ctrl.halt || m0.ctrl.illegal);

    always_ff @(posedge clk) begin
        if (rst)           stopping <= 1'b0;
        else if (stop_mem) stopping <= 1'b1;
    end

    assign dmem_addr = m0.alu_result;
    assign byte_off  = m0.alu_result[1:0];
    assign dmem_re   = m0.valid && m0.ctrl.mem_read;
    assign dmem_we   = m0.valid && m0.ctrl.mem_write;

    always_comb begin
        case (m0.ctrl.mem_size)
            MEM_B: begin
                dmem_wdata = {4{m0.store_data[7:0]}};
                dmem_be    = 4'b0001 << byte_off;
            end
            MEM_H: begin
                dmem_wdata = {2{m0.store_data[15:0]}};
                dmem_be    = byte_off[1] ? 4'b1100 : 4'b0011;
            end
            default: begin
                dmem_wdata = m0.store_data;
                dmem_be    = 4'b1111;
            end
        endcase
    end

    always_comb begin
        case (byte_off)
            2'd0:    ld_byte = dmem_rdata[7:0];
            2'd1:    ld_byte = dmem_rdata[15:8];
            2'd2:    ld_byte = dmem_rdata[23:16];
            default: ld_byte = dmem_rdata[31:24];
        endcase
        ld_half = byte_off[1] ? dmem_rdata[31:16] : dmem_rdata[15:0];

        case (m0.ctrl.mem_size)
            MEM_B:   load_data = m0.ctrl.mem_unsigned ? {24'd0, ld_byte} : {{24{ld_byte[7]}}, ld_byte};
            MEM_H:   load_data = m0.ctrl.mem_unsigned ? {16'd0, ld_half} : {{16{ld_half[15]}}, ld_half};
            default: load_data = dmem_rdata;
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            w0 <= '0;
            w1 <= '0;
        end else begin
            w0.valid     <= m0.valid;
            w0.pc        <= m0.pc;
            w0.instr     <= m0.instr;
            w0.reg_write <= m0.valid && m0.ctrl.reg_write;
            w0.rd        <= m0.rd;
            w0.wb_data   <= (m0.ctrl.wb_sel == WB_MEM) ? load_data : m0.ex_value;
            w0.halt      <= m0.valid && m0.ctrl.halt;
            w0.illegal   <= m0.valid && m0.ctrl.illegal;
            w0.mem_we    <= dmem_we;
            w0.mem_addr  <= dmem_addr;
            w0.mem_be    <= dmem_be;
            w0.mem_wdata <= dmem_wdata;

            w1           <= '0;
            w1.valid     <= m1.valid;
            w1.pc        <= m1.pc;
            w1.instr     <= m1.instr;
            w1.reg_write <= m1.valid && m1.ctrl.reg_write;
            w1.rd        <= m1.rd;
            w1.wb_data   <= m1.ex_value;
        end
    end

    // ================= WB =================
    always_ff @(posedge clk) begin
        if (rst) begin
            halted  <= 1'b0;
            illegal <= 1'b0;
        end else begin
            if (w0.valid && w0.halt)    halted  <= 1'b1;
            if (w0.valid && w0.illegal) illegal <= 1'b1;
        end
    end

    always_comb begin
        retire0           = '0;
        retire0.valid     = w0.valid;
        retire0.pc        = w0.pc;
        retire0.instr     = w0.instr;
        retire0.rd_we     = w0_we && (w0.rd != 5'd0);
        retire0.rd        = w0.rd;
        retire0.rd_wdata  = w0.wb_data;
        retire0.mem_we    = w0.mem_we;
        retire0.mem_addr  = w0.mem_addr;
        retire0.mem_be    = w0.mem_be;
        retire0.mem_wdata = w0.mem_wdata;

        retire1           = '0;
        retire1.valid     = w1.valid;
        retire1.pc        = w1.pc;
        retire1.instr     = w1.instr;
        retire1.rd_we     = w1_we && (w1.rd != 5'd0);
        retire1.rd        = w1.rd;
        retire1.rd_wdata  = w1.wb_data;
    end

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (!rst) begin
            if ((dmem_re || dmem_we) &&
                ((m0.ctrl.mem_size == MEM_H && byte_off[0]) ||
                 (m0.ctrl.mem_size == MEM_W && byte_off != 2'd0)))
                $error("core_dual: misaligned %s at pc=%h addr=%h",
                       dmem_we ? "store" : "load", m0.pc, dmem_addr);
            if (redirect && !stop_mem && redirect_pc[1:0] != 2'd0)
                $error("core_dual: misaligned jump/branch target %h at pc=%h", redirect_pc, e0.pc);
            // lane 1 never holds anything but plain ALU work, and never
            // retires without an older lane-0 instruction beside it
            if (e1.valid && !alu_only(e1.ctrl))
                $error("core_dual: non-ALU instruction %h in lane 1", e1.instr);
            if (w1.valid && !w0.valid)
                $error("core_dual: lane 1 retiring without lane 0 at pc=%h", w1.pc);
        end
    end
`endif

endmodule
