// div_unit.sv - RV32M divide/remainder, iterative: 1 quotient bit per cycle
//
//   start  (1 cycle) capture the operands, take their magnitudes
//   busy   (32 cycles) shift-subtract ("restoring") division on the magnitudes
//   done   (1 cycle) result is valid; the core moves the instruction on
//
// Each step: shift the next dividend bit into the partial remainder; if the
// remainder is now >= the divisor, subtract and the quotient bit is 1.
// That compare-subtract needs the previous step's remainder, so the steps
// can't run in parallel the way a multiply's partial products can.
//
// Signs are fixed at the end: quotient negative if the operand signs differ,
// remainder takes the dividend's sign. Special cases (RISC-V never traps):
//   x / 0          -> quotient all ones (-1), remainder x
//   -2^31 / -1     -> quotient -2^31, remainder 0 (falls out of the math)
// The operands are captured at start, so the core can drop its forwarding
// for them while the divide runs.

module div_unit
    import riscv_pkg::*;
(
    input  logic        clk,
    input  logic        rst,
    input  logic        start,          // begin a divide (ignored while busy)
    input  logic        flush,          // the instruction was flushed: stop
    input  md_op_t      op,             // MD_DIV .. MD_REMU
    input  logic [31:0] a,              // dividend
    input  logic [31:0] b,              // divisor
    output logic        busy,
    output logic        done,           // result valid this cycle only
    output logic [31:0] result
);

    logic [5:0]  count;
    logic [31:0] q;                     // dividend bits shift out, quotient bits shift in
    logic [31:0] r;                     // partial remainder
    logic [31:0] d;                     // divisor magnitude
    logic [31:0] a_orig;
    logic        neg_q, neg_r, b_zero, want_rem;

    logic        is_signed;
    logic [32:0] r_shift, r_sub;

    assign is_signed = (op == MD_DIV) || (op == MD_REM);
    assign r_shift   = {r, q[31]};
    assign r_sub     = r_shift - {1'b0, d};

    always_ff @(posedge clk) begin
        if (rst || flush) begin
            busy <= 1'b0;
            done <= 1'b0;
        end else if (busy) begin
            // one restoring-division step
            if (!r_sub[32]) begin                   // remainder >= divisor
                r <= r_sub[31:0];
                q <= {q[30:0], 1'b1};
            end else begin
                r <= r_shift[31:0];
                q <= {q[30:0], 1'b0};
            end
            count <= count - 6'd1;
            if (count == 6'd1) begin
                busy <= 1'b0;
                done <= 1'b1;
            end
        end else begin
            done <= 1'b0;
            if (start) begin
                busy     <= 1'b1;
                count    <= 6'd32;
                q        <= (is_signed && a[31]) ? -a : a;
                d        <= (is_signed && b[31]) ? -b : b;
                r        <= 32'd0;
                a_orig   <= a;
                neg_q    <= is_signed && (a[31] ^ b[31]);
                neg_r    <= is_signed && a[31];
                b_zero   <= (b == 32'd0);
                want_rem <= (op == MD_REM) || (op == MD_REMU);
            end
        end
    end

    always_comb begin
        if (want_rem)    result = b_zero ? a_orig : (neg_r ? -r : r);
        else             result = b_zero ? 32'hFFFF_FFFF : (neg_q ? -q : q);
    end

endmodule
