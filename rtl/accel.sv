// accel.sv - INT8 matrix-multiply accelerator, memory-mapped on the SoC bus
//
// Computes  C = A x W  with A: M x K and W: K x N (INT8), C: M x N (INT32),
// then returns C either raw or requantized back to INT8 (for the next layer).
//
// The core drives it with ordinary loads and stores (offsets from the base
// address in soc.sv):
//
//   0x0000  CTRL    W   bit 0: start (ignored while busy)
//   0x0004  STATUS  R   bit 0: busy, bit 1: done (cleared by the next start)
//   0x0008  DIMS    RW  [7:0] M (1..M_MAX), [15:8] K, [23:16] N
//                       (K and N: multiples of the array size AN, up to K_MAX / N_MAX)
//   0x000C  QUANT   RW  [4:0] shift, bit 8: ReLU
//   0x0010  CYCLES  R   cycles the last run took (start to done)
//   0x1000  A       W   A[m][k] at byte 0x1000 + m*K_MAX + k
//   0x2000  W       W   W[k][n] at byte 0x2000 + k*N_MAX + n
//   0x3000  C       R   C[m][n] (INT32) at 0x3000 + 4*(m*N_MAX + n)
//   0x4000  CQ      R   requantized C[m][n] (INT8) at byte 0x4000 + m*N_MAX + n:
//                       q = clamp(round(relu(c) >> shift), -128, 127)
//
// Fixed row strides (K_MAX, N_MAX) keep the address math to shifts: no
// multiplier in the address path.
//
// How a run works: the output is split into tiles of AN columns and the
// K dimension into chunks of AN. For each (column tile, K chunk):
//   LOAD    write the AN x AN weight chunk into the array, one row per cycle
//   STREAM  push rows A[0..M-1][chunk] through the array, one per cycle, and
//           add each output row into the C buffer (the first chunk overwrites,
//           so C needs no clearing pass)
// Cycles per tile = AN + M + (2*AN - 1). The array sits idle while weights
// load and while it drains; double-buffered weights would hide both.
//
// The core must not write A/W/DIMS/QUANT or read C while busy: polling
// STATUS is the handshake. The buffers are flip-flop arrays here; a real
// chip would use SRAM macros.

module accel #(
    parameter int AN    = 4,        // systolic array is AN x AN (power of 2, >= 4)
    parameter int M_MAX = 16,
    parameter int K_MAX = 64,
    parameter int N_MAX = 16
) (
    input  logic        clk,
    input  logic        rst,

    // bus (from soc.sv): combinational read, write on the clock edge
    input  logic        sel,        // address is inside the accelerator
    input  logic        we,
    input  logic [3:0]  be,
    input  logic [15:0] addr,       // offset from the base
    input  logic [31:0] wdata,
    output logic [31:0] rdata
);

    localparam int A_ENT = M_MAX * K_MAX / AN;  // buffer entries are AN bytes wide
    localparam int W_ENT = K_MAX * N_MAX / AN;
    localparam int C_ENT = M_MAX * N_MAX / AN;  // ... or AN INT32s for C
    localparam int KT    = K_MAX / AN;          // entries per A row
    localparam int NT    = N_MAX / AN;          // entries per W or C row
    localparam int SB    = $clog2(AN);

    // ---------------- buffers ----------------
    logic [AN-1:0][7:0]  a_mem [A_ENT];
    logic [AN-1:0][7:0]  w_mem [W_ENT];
    logic [AN-1:0][31:0] c_mem [C_ENT];

    // ---------------- registers ----------------
    logic [7:0]  dim_m, dim_k, dim_n;
    logic [4:0]  q_shift;
    logic        q_relu;
    logic        busy, done;
    logic [31:0] cycles;

    // ---------------- bus decode ----------------
    logic [3:0]  region;
    logic [11:0] off;               // byte offset inside the region

    assign region = addr[15:12];
    assign off    = addr[11:0];

    logic start;
    assign start = sel && we && region == 4'h0 && off[4:2] == 3'd0 && be[0] && wdata[0] && !busy;

    // Byte offset -> (entry, lane): entry = off / AN, first lane = off % AN.
    // A 4-byte bus word always falls inside one entry (AN >= 4).
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic int entry_of(input logic [11:0] o);
        return int'(o) >> SB;
    endfunction
    function automatic int lane_of(input logic [11:0] o);
        return int'(o) % AN;
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // A store changes only the bytes it enables: merge it into the old entry.
    // (one whole-entry write per buffer per cycle, like an SRAM with byte enables)
    function automatic logic [AN-1:0][7:0] merge(input logic [AN-1:0][7:0] old,
                                                 input logic [11:0] o, input logic [3:0] b,
                                                 input logic [31:0] d);
        logic [AN-1:0][7:0] v;
        v = old;
        for (int j = 0; j < 4; j++)
            if (b[j]) v[lane_of(o) + j] = d[8*j +: 8];
        return v;
    endfunction

    always_ff @(posedge clk) begin
        if (sel && we && region == 4'h1 && entry_of(off) < A_ENT)
            a_mem[entry_of(off)] <= merge(a_mem[entry_of(off)], off, be, wdata);
        if (sel && we && region == 4'h2 && entry_of(off) < W_ENT)
            w_mem[entry_of(off)] <= merge(w_mem[entry_of(off)], off, be, wdata);
    end

    // ---------------- requantize ----------------
    function automatic logic [7:0] requant(input logic [31:0] c, input logic [4:0] s,
                                           input logic relu);
        logic signed [32:0] v;
        v = {c[31], c};
        if (relu && c[31]) v = '0;
        if (s != 0) v = (v + (33'sd1 <<< (s - 5'd1))) >>> s;   // round to nearest
        if (v > 33'sd127)       return 8'h7F;
        else if (v < -33'sd128) return 8'h80;
        else                    return v[7:0];
    endfunction

    // ---------------- bus read ----------------
    int c_idx, c_ent, q_ent;
    assign c_idx = int'(off) >> 2;              // C element index
    assign c_ent = c_idx >> SB;
    assign q_ent = int'(off) >> SB;             // CQ: one byte per element

    logic [AN-1:0][31:0] c_rd, q_rd;
    assign c_rd = (c_ent < C_ENT) ? c_mem[c_ent] : '0;
    assign q_rd = (q_ent < C_ENT) ? c_mem[q_ent] : '0;

    logic [31:0] q_word;            // 4 requantized results, one word of CQ
    always_comb
        for (int j = 0; j < 4; j++)
            q_word[8*j +: 8] = requant(q_rd[int'(off) % AN + j], q_shift, q_relu);

    always_comb begin
        rdata = '0;
        case (region)
            4'h0: case (off[4:2])
                3'd1: rdata = {30'd0, done, busy};
                3'd2: rdata = {8'd0, dim_n, dim_k, dim_m};
                3'd3: rdata = {23'd0, q_relu, 3'd0, q_shift};
                3'd4: rdata = cycles;
                default: rdata = '0;
            endcase
            4'h3: if (c_ent < C_ENT) rdata = c_rd[c_idx % AN];
            4'h4: rdata = q_word;
            default: rdata = '0;
        endcase
    end

    // ---------------- control ----------------
    typedef enum logic [1:0] {S_IDLE, S_LOAD, S_STREAM} state_t;
    state_t state;

    logic [7:0]    kt, nt;          // current K chunk and column tile
    logic [SB-1:0] wrow;            // weight row being loaded
    logic [7:0]    m_in, m_out;     // rows fed in / come out so far

    logic                 arr_we, arr_in_valid, arr_out_valid;
    logic [AN-1:0][7:0]   arr_w, arr_a;
    logic [AN-1:0][31:0]  arr_c;

    /* verilator lint_off UNUSEDSIGNAL */
    int w_idx, a_idx, c_wr;         // (only the low bits address the buffers)
    /* verilator lint_on UNUSEDSIGNAL */
    assign w_idx = (int'(kt) * AN + int'(wrow)) * NT + int'(nt);
    assign a_idx = int'(m_in) * KT + int'(kt);
    assign c_wr  = int'(m_out) * NT + int'(nt);

    assign arr_we       = (state == S_LOAD);
    assign arr_w        = w_mem[w_idx];
    assign arr_in_valid = (state == S_STREAM) && (m_in < dim_m);
    assign arr_a        = arr_in_valid ? a_mem[a_idx] : '0;

    systolic #(.N(AN)) u_array (
        .clk       (clk),
        .rst       (rst),
        .w_we      (arr_we),
        .w_row     (wrow),
        .w_data    (arr_w),
        .in_valid  (arr_in_valid),
        .in_a      (arr_a),
        .out_valid (arr_out_valid),
        .out_c     (arr_c)
    );

    // first K chunk overwrites, the rest accumulate
    logic [AN-1:0][31:0] c_old, c_new;
    assign c_old = c_mem[c_wr];
    always_comb
        for (int n = 0; n < AN; n++)
            c_new[n] = arr_c[n] + ((kt == 8'd0) ? 32'd0 : c_old[n]);

    logic last_row, last_k, last_n;
    assign last_row = arr_out_valid && (m_out == dim_m - 8'd1);
    assign last_k   = (kt == (dim_k >> SB) - 8'd1);
    assign last_n   = (nt == (dim_n >> SB) - 8'd1);

    always_ff @(posedge clk) begin
        if (rst) begin
            state   <= S_IDLE;
            busy    <= 1'b0;
            done    <= 1'b0;
            cycles  <= '0;
            dim_m   <= '0;
            dim_k   <= '0;
            dim_n   <= '0;
            q_shift <= '0;
            q_relu  <= 1'b0;
            kt      <= '0;
            nt      <= '0;
            wrow    <= '0;
            m_in    <= '0;
            m_out   <= '0;
        end else begin
            if (sel && we && region == 4'h0 && !busy) begin
                if (off[4:2] == 3'd2) {dim_n, dim_k, dim_m} <= wdata[23:0];
                if (off[4:2] == 3'd3) {q_relu, q_shift} <= {wdata[8], wdata[4:0]};
            end

            if (busy) cycles <= cycles + 32'd1;

            case (state)
                S_IDLE: if (start) begin
                    busy   <= 1'b1;
                    done   <= 1'b0;
                    cycles <= 32'd0;
                    kt     <= '0;
                    nt     <= '0;
                    wrow   <= '0;
                    state  <= S_LOAD;
                end
                S_LOAD: begin
                    wrow <= wrow + 1'b1;
                    if (wrow == SB'(AN - 1)) begin
                        m_in  <= '0;
                        m_out <= '0;
                        state <= S_STREAM;
                    end
                end
                S_STREAM: begin
                    if (arr_in_valid) m_in <= m_in + 8'd1;
                    if (arr_out_valid) begin
                        c_mem[c_wr] <= c_new;
                        m_out <= m_out + 8'd1;
                    end
                    if (last_row) begin
                        wrow <= '0;
                        if (!last_k) begin
                            kt    <= kt + 8'd1;
                            state <= S_LOAD;
                        end else if (!last_n) begin
                            kt    <= '0;
                            nt    <= nt + 8'd1;
                            state <= S_LOAD;
                        end else begin
                            busy  <= 1'b0;
                            done  <= 1'b1;
                            state <= S_IDLE;
                        end
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (AN < 4 || (AN & (AN - 1)) != 0) $fatal(1, "accel: AN must be a power of 2, >= 4");
        if (M_MAX * K_MAX > 4096 || K_MAX * N_MAX > 4096 || M_MAX * N_MAX * 4 > 4096)
            $fatal(1, "accel: a buffer does not fit in its 4 KB window");
    end
    // A start with bad dimensions would loop over garbage; flag it.
    always @(posedge clk)
        if (start && (dim_m == 0 || int'(dim_m) > M_MAX || dim_k == 0 || int'(dim_k) > K_MAX ||
                      dim_n == 0 || int'(dim_n) > N_MAX ||
                      int'(dim_k) % AN != 0 || int'(dim_n) % AN != 0))
            $error("accel: start with bad DIMS m=%0d k=%0d n=%0d", dim_m, dim_k, dim_n);
`endif

endmodule
