// systolic.sv - N x N weight-stationary systolic array, INT8 in, INT32 out
//
// Computes one row of  out = a x W  per cycle, where a is a 1 x N row of
// activations and W is the N x N weight tile held inside the array.
//
//            a[0] ->  PE(0,0) -> PE(0,1) -> ... -> PE(0,N-1)
//            a[1] ->  PE(1,0) -> PE(1,1) -> ...       |
//              .         |          |                 v   partial sums
//            a[N-1]-> PE(N-1,0) ... PE(N-1,N-1)       flow down
//                        v          v                 v
//                      out[0]     out[1]   ...    out[N-1]
//
// PE(k,n) holds weight W[k][n]. Every cycle it passes its activation to the
// right and adds a * W[k][n] to the partial sum coming from above, so the sum
// leaving the bottom of column n is  sum over k of a[k] * W[k][n].
//
// Each value only travels to a neighbour, one hop per cycle: no long wires,
// and each activation is read from the buffer once but used N times.
//
// The catch: the partial sum reaches row k one cycle later than it reached
// row k-1, so activation a[k] must also arrive k cycles late. The input skew
// delays row k by k cycles; the output deskew delays column n by N-1-n
// cycles, so a whole output row comes out together.
// Latency from in_valid to out_valid: LAT = 2N - 1 cycles. A new row can go
// in every cycle (throughput: N*N multiply-accumulates per cycle).
//
// Weights: w_we writes one row of the tile (W[w_row][0..N-1]) per cycle.
// Changing weights while rows are still inside the array would mix tiles,
// so the controller waits for the array to drain first.

module systolic #(
    parameter int N = 4
) (
    input  logic                    clk,
    input  logic                    rst,

    input  logic                    w_we,
    input  logic [$clog2(N)-1:0]    w_row,
    input  logic [N-1:0][7:0]       w_data,     // W[w_row][n] = w_data[n]

    input  logic                    in_valid,
    input  logic [N-1:0][7:0]       in_a,       // a[k] = in_a[k], signed

    output logic                    out_valid,
    output logic [N-1:0][31:0]      out_c       // out[n] = out_c[n], signed
);

    localparam int LAT = 2 * N - 1;

    // Invalid rows are fed as zeros: they add nothing to any partial sum.
    logic [N-1:0][7:0] a_in;
    assign a_in = in_valid ? in_a : '0;

    // (Everything below is built with generate loops, so every index is a
    // constant: one set of registers per PE, which is what the hardware is.)
    logic [7:0]  a_left [N];        // activation entering column 0 of row k
    logic [7:0]  a_reg  [N][N];     // activation leaving PE(k,n) to the right
    logic [31:0] ps     [N][N];     // partial sum leaving PE(k,n) downward

    for (genvar k = 0; k < N; k++) begin : g_row
        // ---------------- input skew: row k delayed by k cycles ----------------
        if (k == 0) begin : g_noskew
            assign a_left[0] = a_in[0];
        end else begin : g_skew
            logic [8*k-1:0] dly;            // k bytes: a shift register
            always_ff @(posedge clk) begin
                if (rst) dly <= '0;
                else     dly <= (dly << 8) | (8*k)'(a_in[k]);
            end
            assign a_left[k] = dly[8*k-1 -: 8];
        end

        // ---------------- PE(k, n) ----------------
        for (genvar n = 0; n < N; n++) begin : g_pe
            logic [7:0]         w;          // W[k][n], stationary
            logic signed [7:0]  a_here;
            logic signed [15:0] prod;       // 8 x 8 bits fits in 16
            logic        [31:0] ps_above;

            if (n == 0) begin : g_first_col
                assign a_here = a_left[k];
            end else begin : g_next_col
                assign a_here = a_reg[k][n-1];
            end
            if (k == 0) begin : g_top_row
                assign ps_above = 32'd0;
            end else begin : g_lower_row
                assign ps_above = ps[k-1][n];
            end
            assign prod     = a_here * $signed(w);

            always_ff @(posedge clk) begin
                if (rst) begin
                    w         <= '0;
                    a_reg[k][n] <= '0;
                    ps[k][n]    <= '0;
                end else begin
                    if (w_we && w_row == k) w <= w_data[n];
                    a_reg[k][n] <= a_here;
                    ps[k][n]    <= ps_above + {{16{prod[15]}}, prod};
                end
            end
        end
    end

    // ---------------- output deskew: column n delayed by N-1-n ----------------
    for (genvar n = 0; n < N; n++) begin : g_col
        if (n == N - 1) begin : g_nodeskew
            assign out_c[n] = ps[N-1][n];
        end else begin : g_deskew
            localparam int D = N - 1 - n;
            logic [32*D-1:0] dly;
            always_ff @(posedge clk) begin
                if (rst) dly <= '0;
                else     dly <= (dly << 32) | (32*D)'(ps[N-1][n]);
            end
            assign out_c[n] = dly[32*D-1 -: 32];
        end
    end

    // ---------------- valid pipeline ----------------
    logic [LAT-1:0] vpipe;
    always_ff @(posedge clk) begin
        if (rst) vpipe <= '0;
        else     vpipe <= {vpipe[LAT-2:0], in_valid};
    end
    assign out_valid = vpipe[LAT-1];

endmodule
