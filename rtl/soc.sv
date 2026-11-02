// soc.sv - CPU core + 64 KB unified RAM + test MMIO
//
// Memory map:
//   0x0000_0000 - 0x0000_FFFF  RAM (code + data + stack), word array
//   0x8000_0000                EXIT    (write: 1 = pass, (n << 1) | 1 = fail code n)
//   0x8000_0004                PUTCHAR (write: low byte goes to the console)
//   0x8000_0008                CYCLE   (read: clock cycles since reset, for timing code)
//   0x4000_0000 - 0x4000_FFFF  ML accelerator (accel.sv has the register map)
//
// One RAM, two ports: the instruction port and the data port both read
// combinationally (it behaves like a register file, not a real SRAM). Both
// cores fetch and load in the same cycle the address is ready; moving to
// synchronous-read FPGA block RAM is a later step.
//
// The program image comes from $readmemh with +hex=<file> (simulation only).
//
// CORE picks the CPU:
//   0 = single-cycle (core_sc.sv), the reference model
//   1 = 5-stage pipeline (core.sv)
//   2 = dual-issue 5-stage pipeline (core_dual.sv), which fetches an aligned
//       pair of instructions per cycle through a 64-bit instruction port
// Retire port 1 is only ever valid on the dual-issue core.
//
// REF = 1 builds the copy the testbench uses as its reference model. It has
// no accelerator and no cycle counter: every load from outside RAM returns
// ext_rdata instead, which the testbench sets to what the design under test
// loaded. A device's answer depends on timing (how many cycles the
// accelerator has been running, what the counter says), and the reference
// runs on its own clock, so it can't produce the same answer itself.
// Co-simulation against Spike does the same with device reads.

module soc
    import riscv_pkg::*;
#(
    parameter int CORE      = 2,
    parameter int RAM_BYTES = 64 * 1024,
    parameter bit REF       = 1'b0
) (
    input  logic        clk,
    input  logic        rst,
    input  logic [31:0] ext_rdata,      // REF only: value for loads outside RAM

    // testbench-facing status
    output logic        exit_valid,     // a store to EXIT happened this cycle
    output logic [31:0] exit_code,
    output logic        putc_valid,     // a store to PUTCHAR happened this cycle
    output logic [7:0]  putc_char,
    output logic        halted,         // core hit ECALL / EBREAK
    output logic        illegal,        // core hit an illegal instruction
    output retire_t     retire0,        // instruction retiring this cycle (older)
    output retire_t     retire1         // second one, dual-issue core only
);

    localparam int          WORDS     = RAM_BYTES / 4;
    localparam int          AW        = $clog2(WORDS);  // word address bits
    localparam logic [31:0] EXIT_ADDR = 32'h8000_0000;
    localparam logic [31:0] PUTC_ADDR = 32'h8000_0004;
    localparam logic [31:0] CYCLE_ADDR = 32'h8000_0008;

    logic [31:0] imem_addr;
    // Only one of these is used, depending on CORE
    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0] imem_rdata;        // single word, scalar cores
    logic [63:0] imem_rdata2;       // aligned pair, dual-issue core
    /* verilator lint_on UNUSEDSIGNAL */
    logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    logic        dmem_re, dmem_we;
    logic [3:0]  dmem_be;

    if (CORE == 2) begin : g_dual
        core_dual u_core (
            .clk        (clk),
            .rst        (rst),
            .imem_addr  (imem_addr),
            .imem_rdata (imem_rdata2),
            .dmem_addr  (dmem_addr),
            .dmem_re    (dmem_re),
            .dmem_we    (dmem_we),
            .dmem_be    (dmem_be),
            .dmem_wdata (dmem_wdata),
            .dmem_rdata (dmem_rdata),
            .halted     (halted),
            .illegal    (illegal),
            .retire0    (retire0),
            .retire1    (retire1)
        );
    end else if (CORE == 1) begin : g_pipe
        core u_core (
            .clk        (clk),
            .rst        (rst),
            .imem_addr  (imem_addr),
            .imem_rdata (imem_rdata),
            .dmem_addr  (dmem_addr),
            .dmem_re    (dmem_re),
            .dmem_we    (dmem_we),
            .dmem_be    (dmem_be),
            .dmem_wdata (dmem_wdata),
            .dmem_rdata (dmem_rdata),
            .halted     (halted),
            .illegal    (illegal),
            .retire     (retire0)
        );
        assign retire1 = '0;
    end else begin : g_sc
        core_sc u_core (
            .clk        (clk),
            .rst        (rst),
            .imem_addr  (imem_addr),
            .imem_rdata (imem_rdata),
            .dmem_addr  (dmem_addr),
            .dmem_re    (dmem_re),
            .dmem_we    (dmem_we),
            .dmem_be    (dmem_be),
            .dmem_wdata (dmem_wdata),
            .dmem_rdata (dmem_rdata),
            .halted     (halted),
            .illegal    (illegal),
            .retire     (retire0)
        );
        assign retire1 = '0;
    end

    // ---------------- RAM ----------------
    logic [31:0] mem [WORDS];
    logic        d_in_ram, i_in_ram;

    assign i_in_ram = (imem_addr < RAM_BYTES);
    assign d_in_ram = (dmem_addr < RAM_BYTES);

    // Out-of-range fetches read as 0, which decodes as illegal and stops the core.
    assign imem_rdata  = i_in_ram ? mem[imem_addr[AW+1:2]] : 32'd0;
    assign imem_rdata2 = i_in_ram ? {mem[{imem_addr[AW+1:3], 1'b1}], mem[{imem_addr[AW+1:3], 1'b0}]} : 64'd0;
    logic [31:0] ram_rdata, dev_rdata;
    assign ram_rdata  = d_in_ram ? mem[dmem_addr[AW+1:2]] : 32'd0;
    // The core picks the byte or halfword out of the word by address, so the
    // reference gets the DUT's loaded value back in the same byte position.
    assign dmem_rdata = d_in_ram ? ram_rdata :
                        REF      ? ext_rdata << (8 * dmem_addr[1:0]) : dev_rdata;

    always_ff @(posedge clk) begin
        if (dmem_we && d_in_ram) begin
            for (int b = 0; b < 4; b++)
                if (dmem_be[b]) mem[dmem_addr[AW+1:2]][8*b +: 8] <= dmem_wdata[8*b +: 8];
        end
    end

    // ---------------- devices ----------------
    logic        accel_sel, cycle_sel;
    logic [31:0] accel_rdata, cycle_count;

    assign accel_sel = (dmem_addr[31:16] == 16'h4000);
    assign cycle_sel = (dmem_addr == CYCLE_ADDR);

    if (!REF) begin : g_dev
        accel u_accel (
            .clk   (clk),
            .rst   (rst),
            .sel   (accel_sel),
            .we    (dmem_we),
            .be    (dmem_be),
            .addr  (dmem_addr[15:0]),
            .wdata (dmem_wdata),
            .rdata (accel_rdata)
        );

        always_ff @(posedge clk) begin
            if (rst) cycle_count <= '0;
            else     cycle_count <= cycle_count + 32'd1;
        end
    end else begin : g_no_dev
        assign accel_rdata = '0;
        assign cycle_count = '0;
    end

    assign dev_rdata = accel_sel ? accel_rdata : cycle_sel ? cycle_count : 32'd0;

    // ---------------- test MMIO ----------------
    assign exit_valid = dmem_we && (dmem_addr == EXIT_ADDR);
    assign exit_code  = dmem_wdata;
    assign putc_valid = dmem_we && (dmem_addr == PUTC_ADDR);
    assign putc_char  = dmem_wdata[7:0];

`ifndef SYNTHESIS
    string hex_file;
    initial begin
        if ($value$plusargs("hex=%s", hex_file)) $readmemh(hex_file, mem);
    end

    // Any data access outside RAM and the two MMIO registers is a bug in the
    // program or the core, so stop loudly instead of silently reading 0.
    always @(posedge clk) begin
        if (!rst && (dmem_re || dmem_we) && !d_in_ram && !exit_valid && !putc_valid &&
            !accel_sel && !(cycle_sel && dmem_re))
            $error("soc: %s to unmapped address %h", dmem_we ? "store" : "load", dmem_addr);
        if (!rst && !i_in_ram)
            $error("soc: fetch from unmapped address %h", imem_addr);
    end
`endif

endmodule
