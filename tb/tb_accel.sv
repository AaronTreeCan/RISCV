// tb_accel.sv - self-checking testbench for rtl/accel.sv (and rtl/systolic.sv)
//
// Drives the accelerator through its bus exactly like the core does (stores
// to fill the buffers and registers, loads to poll and read results), for
// many random shapes: M 1..16, K and N multiples of 4 up to 64 / 16, random
// requantization shift and ReLU. Each run checks:
//   - every raw INT32 result against a matrix multiply done here in plain SV
//   - every requantized INT8 result (round, ReLU, clamp)
//   - the CYCLES register against the expected count:
//       (K/4) * (N/4) * (4 load + M stream + 7 drain)
//   - STATUS: busy (and done cleared) right after start, done at the end
//   - that a second start or a DIMS write while busy is ignored (the run
//     must take the expected time from the first start)
// Matrices include all -128 / all 127 cases: the largest sums the accumulator
// must hold without overflow.

module tb_accel;

    logic        clk = 1'b0;
    logic        rst = 1'b1;
    always #5 clk = ~clk;

    localparam int M_MAX = 16, K_MAX = 64, N_MAX = 16, AN = 4;

    logic        sel, we;
    logic [3:0]  be;
    logic [15:0] addr;
    logic [31:0] wdata, rdata;

    accel #(.AN(AN), .M_MAX(M_MAX), .K_MAX(K_MAX), .N_MAX(N_MAX)) dut (
        .clk(clk), .rst(rst), .sel(sel), .we(we), .be(be),
        .addr(addr), .wdata(wdata), .rdata(rdata)
    );

    int errors = 0;
    int checks = 0;

    // wall-clock check: cycles from the first start to busy going low, seen
    // from outside (CYCLES alone would miss a run that silently restarted)
    int clk_count = 0, done_at = 0;
    always @(posedge clk) clk_count++;
    always @(negedge dut.busy) done_at = clk_count;

    task automatic fail(input string msg);
        errors++;
        if (errors <= 20) $display("FAIL %s", msg);
    endtask

    // one store: set up in the low half of the clock, captured on the rising edge
    task automatic bus_wr(input logic [15:0] a, input logic [31:0] d, input logic [3:0] b = 4'hF);
        @(negedge clk);
        sel = 1'b1; we = 1'b1; be = b; addr = a; wdata = d;
        @(negedge clk);
        sel = 1'b0; we = 1'b0;
    endtask

    // one load: the read is combinational, like the core's data port
    task automatic bus_rd(input logic [15:0] a, output logic [31:0] d);
        @(negedge clk);
        sel = 1'b1; we = 1'b0; addr = a;
        #1 d = rdata;
        sel = 1'b0;
    endtask

    logic signed [7:0]  A [M_MAX][K_MAX];
    logic signed [7:0]  W [K_MAX][N_MAX];
    logic signed [31:0] C [M_MAX][N_MAX];

    function automatic logic [7:0] ref_quant(input logic signed [31:0] c, input int s, input bit relu);
        longint v;
        v = c;
        if (relu && v < 0) v = 0;
        if (s > 0) v = (v + (longint'(1) << (s - 1))) >>> s;
        if (v > 127)  v = 127;
        if (v < -128) v = -128;
        return v[7:0];
    endfunction

    function automatic logic signed [7:0] rand_val(input int mode);
        case (mode)
            0:       return 8'sh80;                     // -128 everywhere
            1:       return 8'sh7F;                     // 127 everywhere
            2:       return $signed(8'($urandom_range(0, 6))) - 8'sd3;   // small values
            default: return $signed(8'($urandom));
        endcase
    endfunction

    task automatic run(input int m, input int k, input int n, input int s, input bit relu,
                       input int amode, input int wmode, input bit poke_busy);
        logic [31:0] d;
        int          polls, expect_cycles, start_at;

        // reference result
        for (int i = 0; i < m; i++) for (int j = 0; j < k; j++) A[i][j] = rand_val(amode);
        for (int i = 0; i < k; i++) for (int j = 0; j < n; j++) W[i][j] = rand_val(wmode);
        for (int i = 0; i < m; i++)
            for (int j = 0; j < n; j++) begin
                C[i][j] = 0;
                for (int x = 0; x < k; x++) begin
                    int av, wv;             // (via int: Icarus loses the sign in A * W here)
                    av = A[i][x];
                    wv = W[x][j];
                    C[i][j] += av * wv;
                end
            end

        // fill the buffers: word stores, with some single-byte stores mixed in
        for (int i = 0; i < m; i++)
            for (int j = 0; j < k; j += 4)
                if ($urandom_range(0, 7) == 0)
                    for (int b = 0; b < 4; b++)
                        bus_wr(16'h1000 + 16'(i * K_MAX + j), {4{A[i][j+b]}}, 4'b1 << b);
                else
                    bus_wr(16'h1000 + 16'(i * K_MAX + j), {A[i][j+3], A[i][j+2], A[i][j+1], A[i][j]});
        for (int i = 0; i < k; i++)
            for (int j = 0; j < n; j += 4)
                bus_wr(16'h2000 + 16'(i * N_MAX + j), {W[i][j+3], W[i][j+2], W[i][j+1], W[i][j]});

        bus_wr(16'h0008, {8'd0, 8'(n), 8'(k), 8'(m)});
        bus_wr(16'h000C, {23'd0, relu, 3'd0, 5'(s)});
        bus_wr(16'h0000, 32'd1);
        start_at = clk_count;

        if (poke_busy) begin                    // both must be ignored while busy
            bus_wr(16'h0000, 32'd1);
            bus_wr(16'h0008, {8'd0, 8'd4, 8'd4, 8'd1});
        end

        bus_rd(16'h0004, d);                    // the shortest run takes 12 cycles
        checks++;
        if (d[1:0] != 2'b01) fail($sformatf("STATUS=%b right after start, expected busy=1 done=0", d[1:0]));

        polls = 0;
        do begin
            bus_rd(16'h0004, d);
            polls++;
        end while (d[0] && polls < 10000);
        checks++;
        if (d[1:0] != 2'b10) fail($sformatf("STATUS=%b after the run, expected done=1 busy=0", d[1:0]));

        expect_cycles = (k / AN) * (n / AN) * (AN + m + 2 * AN - 1);
        checks++;
        if (done_at - start_at != expect_cycles)
            fail($sformatf("m=%0d k=%0d n=%0d: busy for %0d cycles after start, expected %0d",
                           m, k, n, done_at - start_at, expect_cycles));

        bus_rd(16'h0010, d);
        checks++;
        if (d != expect_cycles)
            fail($sformatf("m=%0d k=%0d n=%0d: CYCLES=%0d, expected %0d", m, k, n, d, expect_cycles));

        for (int i = 0; i < m; i++)
            for (int j = 0; j < n; j++) begin
                bus_rd(16'h3000 + 16'(4 * (i * N_MAX + j)), d);
                checks++;
                if (d !== C[i][j])
                    fail($sformatf("m=%0d k=%0d n=%0d: C[%0d][%0d]=%0d, expected %0d",
                                   m, k, n, i, j, $signed(d), C[i][j]));
            end
        for (int i = 0; i < m; i++)
            for (int j = 0; j < n; j += 4) begin
                bus_rd(16'h4000 + 16'(i * N_MAX + j), d);
                for (int b = 0; b < 4; b++) begin
                    checks++;
                    if (d[8*b +: 8] !== ref_quant(C[i][j+b], s, relu))
                        fail($sformatf("shift=%0d relu=%0d: CQ[%0d][%0d]=%0d (C=%0d), expected %0d",
                                       s, relu, i, j + b, $signed(d[8*b +: 8]), C[i][j+b],
                                       $signed(ref_quant(C[i][j+b], s, relu))));
                end
            end
    endtask

    initial begin
        sel = 1'b0; we = 1'b0; be = 4'h0; addr = '0; wdata = '0;
        repeat (2) @(posedge clk);
        @(negedge clk) rst = 1'b0;

        // corners: smallest and largest shapes, extreme values
        run(1, 4, 4, 0, 0, 3, 3, 0);
        run(M_MAX, K_MAX, N_MAX, 0, 0, 0, 0, 0);     // 64 * (-128 * -128) = 2^20
        run(M_MAX, K_MAX, N_MAX, 0, 0, 0, 1, 0);     // most negative sum
        run(M_MAX, K_MAX, N_MAX, 14, 0, 0, 1, 0);
        run(M_MAX, K_MAX, N_MAX, 8, 1, 3, 3, 1);
        run(3, 8, 12, 0, 1, 2, 2, 1);

        repeat (150)
            run($urandom_range(1, M_MAX), 4 * $urandom_range(1, K_MAX / 4),
                4 * $urandom_range(1, N_MAX / 4), $urandom_range(0, 12), $urandom_range(0, 1),
                $urandom_range(2, 3), $urandom_range(2, 3), $urandom_range(0, 1));

        if (errors == 0) begin
            $display("tb_accel: %0d checks, all passed", checks);
            $display("TEST PASSED");
        end else begin
            $display("tb_accel: %0d of %0d checks failed", errors, checks);
            $fatal(1, "TEST FAILED");
        end
        $finish;
    end

endmodule
