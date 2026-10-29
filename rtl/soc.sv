// soc.sv - single-cycle core + 64 KB unified RAM + test MMIO
//
// Memory map:
//   0x0000_0000 - 0x0000_FFFF  RAM (code + data + stack), word array
//   0x8000_0000                EXIT    (write: 1 = pass, (n << 1) | 1 = fail code n)
//   0x8000_0004                PUTCHAR (write: low byte goes to the console)
//
// One RAM, two ports: the instruction port and the data port both read
// combinationally (it behaves like a register file, not a real SRAM). That is
// fine for a single-cycle core in simulation; the pipeline will move to
// synchronous-read memories that map onto FPGA block RAM.
//
// The program image comes from $readmemh with +hex=<file> (simulation only).

module soc #(
    parameter int RAM_BYTES = 64 * 1024
) (
    input  logic        clk,
    input  logic        rst,

    // testbench-facing status
    output logic        exit_valid,     // a store to EXIT happened this cycle
    output logic [31:0] exit_code,
    output logic        putc_valid,     // a store to PUTCHAR happened this cycle
    output logic [7:0]  putc_char,
    output logic        halted,         // core hit ECALL / EBREAK
    output logic        illegal         // core hit an illegal instruction
);

    localparam int          WORDS     = RAM_BYTES / 4;
    localparam int          AW        = $clog2(WORDS);  // word address bits
    localparam logic [31:0] EXIT_ADDR = 32'h8000_0000;
    localparam logic [31:0] PUTC_ADDR = 32'h8000_0004;

    logic [31:0] imem_addr, imem_rdata;
    logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    logic        dmem_re, dmem_we;
    logic [3:0]  dmem_be;

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
        .illegal    (illegal)
    );

    // ---------------- RAM ----------------
    logic [31:0] mem [WORDS];
    logic        d_in_ram, i_in_ram;

    assign i_in_ram = (imem_addr < RAM_BYTES);
    assign d_in_ram = (dmem_addr < RAM_BYTES);

    // Out-of-range fetches read as 0, which decodes as illegal and stops the core.
    assign imem_rdata = i_in_ram ? mem[imem_addr[AW+1:2]] : 32'd0;
    assign dmem_rdata = d_in_ram ? mem[dmem_addr[AW+1:2]] : 32'd0;

    always_ff @(posedge clk) begin
        if (dmem_we && d_in_ram) begin
            for (int b = 0; b < 4; b++)
                if (dmem_be[b]) mem[dmem_addr[AW+1:2]][8*b +: 8] <= dmem_wdata[8*b +: 8];
        end
    end

    // ---------------- MMIO ----------------
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
        if (!rst && (dmem_re || dmem_we) && !d_in_ram && !exit_valid && !putc_valid)
            $error("soc: %s to unmapped address %h", dmem_we ? "store" : "load", dmem_addr);
        if (!rst && !i_in_ram)
            $error("soc: fetch from unmapped address %h", imem_addr);
    end
`endif

endmodule
