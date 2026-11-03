// dma.sv - 2D copy engine: moves a block of words between RAM and a device
// without running instructions
//
// The core writes a descriptor and starts it (offsets from the base address
// in soc.sv, all word registers):
//
//   0x00  SRC         RW  first source byte address (4-byte aligned)
//   0x04  DST         RW  first destination byte address (4-byte aligned)
//   0x08  ROW_BYTES   RW  bytes per row (multiple of 4, at least 4)
//   0x0C  ROWS        RW  number of rows (at least 1)
//   0x10  SRC_STRIDE  RW  bytes from one source row to the next
//   0x14  DST_STRIDE  RW  bytes from one destination row to the next
//   0x18  CTRL        W   bit 0: start (ignored while busy)
//   0x1C  STATUS      R   bit 0: busy, bit 1: done (cleared by the next start)
//
// A 2D copy matches how matrices sit in memory: a packed 16 x 16 matrix in
// RAM (stride 16) can go into the accelerator's A buffer (stride 64) with one
// descriptor instead of one copy per row.
//
// Moving data: one word per cycle, but only in cycles the SoC grants (go).
// soc.sv grants the cycles in which the core is not loading or storing:
// the core always wins, so it never has to wait (none of the cores can stall
// on a data access). Each granted cycle reads the word at raddr and writes it
// to waddr in the same cycle; soc.sv routes the two to different devices
// (RAM and the accelerator), so they don't compete for one port.
//
// Registers are ignored while busy. Polling STATUS is the handshake, the
// same as for the accelerator.

module dma (
    input  logic        clk,
    input  logic        rst,

    // registers (core side): combinational read, write on the clock edge
    input  logic        sel,
    input  logic        we,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [4:0]  addr,       // byte offset from the base (word registers: [1:0] unused)
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [31:0] wdata,
    output logic [31:0] rdata,

    // copy side
    output logic        req,        // wants to move a word this cycle
    input  logic        go,         // granted: the word moves on this clock edge
    output logic [31:0] raddr,      // read this word ...
    output logic [31:0] waddr       // ... and write it here
);

    logic [31:0] src, dst, row_bytes, rows, src_stride, dst_stride;
    logic        busy, done;

    // progress of the current copy
    logic [31:0] src_row, dst_row;  // start of the current row
    logic [31:0] col;               // byte offset inside the row
    logic [31:0] rows_left;

    logic        start, row_end;
    assign start   = sel && we && addr[4:2] == 3'd6 && wdata[0] && !busy;
    assign row_end = (col + 32'd4 == row_bytes);

    assign req   = busy;
    assign raddr = src_row + col;
    assign waddr = dst_row + col;

    always_comb begin
        case (addr[4:2])
            3'd0:    rdata = src;
            3'd1:    rdata = dst;
            3'd2:    rdata = row_bytes;
            3'd3:    rdata = rows;
            3'd4:    rdata = src_stride;
            3'd5:    rdata = dst_stride;
            3'd7:    rdata = {30'd0, done, busy};
            default: rdata = '0;
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            {src, dst, row_bytes, rows, src_stride, dst_stride} <= '0;
            busy      <= 1'b0;
            done      <= 1'b0;
            src_row   <= '0;
            dst_row   <= '0;
            col       <= '0;
            rows_left <= '0;
        end else begin
            if (sel && we && !busy) begin
                case (addr[4:2])
                    3'd0: src        <= wdata;
                    3'd1: dst        <= wdata;
                    3'd2: row_bytes  <= wdata;
                    3'd3: rows       <= wdata;
                    3'd4: src_stride <= wdata;
                    3'd5: dst_stride <= wdata;
                    default: ;
                endcase
            end

            if (start) begin
                busy      <= 1'b1;
                done      <= 1'b0;
                src_row   <= src;
                dst_row   <= dst;
                col       <= '0;
                rows_left <= rows;
            end else if (go) begin
                if (!row_end) begin
                    col <= col + 32'd4;
                end else begin
                    col       <= '0;
                    src_row   <= src_row + src_stride;
                    dst_row   <= dst_row + dst_stride;
                    rows_left <= rows_left - 32'd1;
                    if (rows_left == 32'd1) begin
                        busy <= 1'b0;
                        done <= 1'b1;
                    end
                end
            end
        end
    end

`ifndef SYNTHESIS
    // A bad descriptor would copy garbage or run (nearly) forever; flag it.
    always @(posedge clk) begin
        if (start && (rows == 0 || row_bytes == 0 || row_bytes[1:0] != 0 ||
                      src[1:0] != 0 || dst[1:0] != 0 || src_stride[1:0] != 0 || dst_stride[1:0] != 0))
            $error("dma: bad descriptor src=%h dst=%h row_bytes=%0d rows=%0d strides=%0d/%0d",
                   src, dst, row_bytes, rows, src_stride, dst_stride);
        if (go && !busy)
            $error("dma: granted a cycle while idle");
    end
`endif

endmodule
