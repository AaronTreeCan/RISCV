// regfile.sv - RV32I integer register file (x0..x31)
//
// Decisions (see docs/design-notes.md):
//   - combinational reads: address in, data out in the same cycle (single-cycle core)
//   - writes land on the rising edge; a read in the same cycle sees the OLD value
//     (no internal bypass - forwarding belongs in the pipeline, not here)
//   - x0 has no storage: reads of x0 return 0, writes to x0 are dropped
//   - no reset: real RISC-V doesn't require it, it saves area, and lets FPGA
//     tools map the array to distributed RAM. Unwritten registers read as X in sim.
//   - NUM_READ / NUM_WRITE are parameters so the dual-issue core can use 4R2W.
//     If two write ports hit the same register in one cycle, the higher port
//     number wins (port 1 = the younger instruction in program order).

module regfile #(
    parameter int NUM_READ  = 2,
    parameter int NUM_WRITE = 1
) (
    input  logic                         clk,

    input  logic [NUM_READ-1:0][4:0]     raddr,
    output logic [NUM_READ-1:0][31:0]    rdata,

    input  logic [NUM_WRITE-1:0]         we,
    input  logic [NUM_WRITE-1:0][4:0]    waddr,
    input  logic [NUM_WRITE-1:0][31:0]   wdata
);

    logic [31:0] regs [1:31];   // x1..x31; x0 is not stored

    // Later ports overwrite earlier ones in the loop, so the highest port wins.
    always_ff @(posedge clk) begin
        for (int w = 0; w < NUM_WRITE; w++) begin
            if (we[w] && waddr[w] != 5'd0)
                regs[waddr[w]] <= wdata[w];
        end
    end

    always_comb begin
        for (int r = 0; r < NUM_READ; r++) begin
            rdata[r] = (raddr[r] == 5'd0) ? 32'd0 : regs[raddr[r]];
        end
    end

`ifndef SYNTHESIS
    // x0 must always read as zero, whatever happened to the write ports.
    // (always @* rather than always_comb: Icarus warns about $error in always_comb)
    always @* begin
        for (int r = 0; r < NUM_READ; r++) begin
            if (raddr[r] == 5'd0)
                assert (rdata[r] === 32'd0)
                    else $error("regfile: x0 read as %h on port %0d", rdata[r], r);
        end
    end
`endif

endmodule
