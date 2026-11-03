// tb_dma.sv - self-checking testbench for rtl/dma.sv
//
// Two 4 KB memories stand in for RAM (at 0x0000_0000) and a device (at
// 0x4000_0000). The testbench plays the SoC: it grants the DMA a cycle unless
// the "core" is busy, and the core is busy at random with a probability that
// changes from run to run (0%, 50%, 90%). Each run is a random 2D copy, in
// either direction. Each run checks:
//   - every destination byte equals its source byte
//   - every byte outside the destination rows is unchanged (strides, row ends)
//   - STATUS: busy (and done cleared) right after start, done at the end
//   - one word moves per granted cycle: the copy takes exactly
//     ROWS * ROW_BYTES / 4 granted cycles, and from start to done every cycle
//     either moves a word or lost the bus to the core (no idle cycles)
//   - registers read back what was written, and writes while busy (a new
//     SRC, a second start) are ignored

module tb_dma;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    localparam int          MEM   = 4096;
    localparam logic [31:0] DEV   = 32'h4000_0000;

    logic        sel, we, req, go;
    logic [4:0]  addr;
    logic [31:0] wdata, rdata, raddr, waddr;

    dma dut (
        .clk(clk), .rst(rst), .sel(sel), .we(we), .addr(addr), .wdata(wdata), .rdata(rdata),
        .req(req), .go(go), .raddr(raddr), .waddr(waddr)
    );

    int errors = 0, checks = 0;

    task automatic fail(input string msg);
        errors++;
        if (errors <= 20) $display("FAIL %s", msg);
    endtask

    // ---------------- the two memories ----------------
    logic [7:0] ram [MEM];
    logic [7:0] dev [MEM];
    logic [7:0] ram_exp [MEM];      // what each should hold after the copy
    logic [7:0] dev_exp [MEM];

    function automatic logic [31:0] rd32(input logic [31:0] a);
        logic [31:0] v;
        for (int b = 0; b < 4; b++)
            v[8*b +: 8] = (a >= DEV) ? dev[int'(a - DEV) + b] : ram[int'(a) + b];
        return v;
    endfunction

    // ---------------- the "SoC": arbitration and the copy itself ----------------
    int  busy_pct = 0;              // chance the core uses the bus in a cycle
    logic core_busy;
    int  grants = 0;                // words moved since the last start
    int  waits  = 0;                // cycles the DMA wanted the bus but the core had it

    always @(negedge clk) core_busy = ($urandom_range(0, 99) < busy_pct);
    assign go = req && !core_busy && !sel;     // register accesses are core accesses too

    always @(posedge clk) if (go) begin
        logic [31:0] v;
        v = rd32(raddr);
        for (int b = 0; b < 4; b++)
            if (waddr >= DEV) dev[int'(waddr - DEV) + b] <= v[8*b +: 8];
            else              ram[int'(waddr) + b]       <= v[8*b +: 8];
        grants++;
    end
    always @(posedge clk) if (req && !go) waits++;

    // ---------------- register access, like the core's stores and loads ----------------
    task automatic bus_wr(input int r, input logic [31:0] d);
        @(negedge clk);
        sel = 1'b1; we = 1'b1; addr = 5'(4 * r); wdata = d;
        @(negedge clk);
        sel = 1'b0; we = 1'b0;
    endtask

    task automatic bus_rd(input int r, output logic [31:0] d);
        @(negedge clk);
        sel = 1'b1; we = 1'b0; addr = 5'(4 * r);
        #1 d = rdata;
        @(negedge clk);
        sel = 1'b0;
    endtask

    localparam int R_SRC = 0, R_DST = 1, R_ROW_BYTES = 2, R_ROWS = 3,
                   R_SRC_STRIDE = 4, R_DST_STRIDE = 5, R_CTRL = 6, R_STATUS = 7;

    // ---------------- one copy ----------------
    task automatic run(input bit to_dev, input int rows, input int row_bytes,
                       input int src_stride, input int dst_stride, input int pct, input bit poke_in);
        logic [31:0] src, dst, d;
        int          span_s, span_d, start_at, done_at, polls, words;
        bit          poke;

        span_s = (rows - 1) * src_stride + row_bytes;
        span_d = (rows - 1) * dst_stride + row_bytes;
        src = 32'(4 * $urandom_range(0, (MEM - span_s) / 4));
        dst = 32'(4 * $urandom_range(0, (MEM - span_d) / 4));
        if (to_dev) dst += DEV;
        else        src += DEV;
        words = rows * row_bytes / 4;
        poke  = poke_in && words >= 8;  // a short copy is already done by then

        for (int i = 0; i < MEM; i++) begin
            ram[i] = 8'($urandom);
            dev[i] = 8'($urandom);
            ram_exp[i] = ram[i];
            dev_exp[i] = dev[i];
        end
        for (int r = 0; r < rows; r++)
            for (int c = 0; c < row_bytes; c++) begin
                int s, t;
                logic [7:0] v;
                s = r * src_stride + c;
                t = r * dst_stride + c;
                v = to_dev ? ram[int'(src) + s] : dev[int'(src - DEV) + s];
                if (to_dev) dev_exp[int'(dst - DEV) + t] = v;
                else        ram_exp[int'(dst) + t] = v;
            end

        busy_pct = 0;
        bus_wr(R_SRC, src);
        bus_wr(R_DST, dst);
        bus_wr(R_ROW_BYTES, 32'(row_bytes));
        bus_wr(R_ROWS, 32'(rows));
        bus_wr(R_SRC_STRIDE, 32'(src_stride));
        bus_wr(R_DST_STRIDE, 32'(dst_stride));
        bus_rd(R_SRC, d);
        checks++;
        if (d !== src) fail($sformatf("SRC reads back %h, wrote %h", d, src));
        bus_rd(R_DST_STRIDE, d);
        checks++;
        if (d !== 32'(dst_stride)) fail($sformatf("DST_STRIDE reads back %0d, wrote %0d", d, dst_stride));

        busy_pct = pct;
        grants   = 0;
        waits    = 0;
        bus_wr(R_CTRL, 32'd1);
        start_at = $time / 10;

        if (rows * row_bytes > 8) begin          // still busy: check, then poke
            bus_rd(R_STATUS, d);
            checks++;
            if (d[1:0] !== 2'b01) fail($sformatf("STATUS=%b right after start, expected busy=1 done=0", d[1:0]));
        end
        if (poke) begin
            bus_wr(R_CTRL, 32'd1);               // both must be ignored while busy
            bus_wr(R_SRC, 32'h0000_0F00);
        end

        // wait for done without touching the bus (so the copy time is exact)
        polls = 0;
        while (dut.busy && polls < 100000) begin
            @(posedge clk);
            polls++;
        end
        done_at = $time / 10;
        busy_pct = 0;

        checks++;
        if (grants != words)
            fail($sformatf("%0d x %0d bytes: moved %0d words, expected %0d", rows, row_bytes, grants, words));
        // every cycle from start to done either moved a word or lost the bus
        checks++;
        if (done_at - start_at != words + waits)
            fail($sformatf("%0d x %0d bytes: took %0d cycles, expected %0d words + %0d cycles waiting",
                           rows, row_bytes, done_at - start_at, words, waits));

        bus_rd(R_STATUS, d);
        checks++;
        if (d[1:0] !== 2'b10) fail($sformatf("STATUS=%b after the copy, expected done=1 busy=0", d[1:0]));
        if (poke) begin
            bus_rd(R_SRC, d);
            checks++;
            if (d !== src) fail($sformatf("SRC changed to %h by a write while busy", d));
        end

        for (int i = 0; i < MEM; i++) begin
            checks += 2;
            if (ram[i] !== ram_exp[i])
                fail($sformatf("%0d x %0d bytes, strides %0d/%0d: RAM byte %h = %h, expected %h",
                               rows, row_bytes, src_stride, dst_stride, i, ram[i], ram_exp[i]));
            if (dev[i] !== dev_exp[i])
                fail($sformatf("%0d x %0d bytes, strides %0d/%0d: device byte %h = %h, expected %h",
                               rows, row_bytes, src_stride, dst_stride, i, dev[i], dev_exp[i]));
        end
    endtask

    initial begin
        sel = 1'b0; we = 1'b0; addr = '0; wdata = '0;
        repeat (2) @(posedge clk);
        @(negedge clk) rst = 1'b0;

        // corners: one word; one row; packed rows; the accelerator's shapes
        run(1, 1, 4, 4, 4, 0, 0);
        run(0, 1, 64, 64, 64, 0, 0);
        run(1, 16, 16, 16, 16, 0, 0);
        run(1, 16, 64, 64, 64, 50, 1);        // x  -> A buffer (stride 64)
        run(1, 16, 16, 16, 16, 90, 0);        // W2 -> W buffer
        run(0, 16, 16, 16, 16, 50, 1);        // CQ -> RAM
        run(1, 8, 12, 12, 64, 0, 1);          // packed source, wider destination stride
        run(0, 8, 12, 64, 12, 0, 0);          // and the reverse

        repeat (200) begin
            int rows, rb, ss, ds, pct;
            case ($urandom_range(0, 2))
                0:       pct = 0;
                1:       pct = 50;
                default: pct = 90;
            endcase
            rows = $urandom_range(1, 16);
            rb   = 4 * $urandom_range(1, 16);
            ss   = rb + 4 * $urandom_range(0, 8);
            ds   = rb + 4 * $urandom_range(0, 8);
            run($urandom_range(0, 1), rows, rb, ss, ds, pct, $urandom_range(0, 1));
        end

        if (errors == 0) begin
            $display("tb_dma: %0d checks, all passed", checks);
            $display("TEST PASSED");
        end else begin
            $display("tb_dma: %0d of %0d checks failed", errors, checks);
            $fatal(1, "TEST FAILED");
        end
        $finish;
    end

endmodule
