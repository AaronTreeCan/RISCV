// tb_muldiv.sv - self-checking testbench for rtl/mul_unit.sv and rtl/div_unit.sv
//
// Reference: riscv_pkg::md_ref, written with the language's * / % operators.
// Stimulus, for every one of the 8 operations:
//   1. all pairs of corner values (0, 1, -1, 2^31, 2^31-1, small +/-) including
//      divide by zero and -2^31 / -1
//   2. 3000 random pairs, plus 1000 with small divisors (long quotients)
// The divider is also checked for its timing: done exactly 33 cycles after
// start, and a flush in the middle leaves it idle.

module tb_muldiv;
    import riscv_pkg::*;

    logic        clk = 1'b0;
    logic        rst = 1'b1;
    always #5 clk = ~clk;

    logic [31:0] a, b, mul_y, div_y;
    md_op_t      op;
    logic        start, flush, busy, done;

    mul_unit u_mul (.a(a), .b(b), .op(op), .result(mul_y));
    div_unit u_div (.clk(clk), .rst(rst), .start(start), .flush(flush), .op(op),
                    .a(a), .b(b), .busy(busy), .done(done), .result(div_y));

    int errors = 0;
    int checks = 0;

    task automatic check(input md_op_t o, input logic [31:0] x, input logic [31:0] y);
        logic [31:0] exp, got;
        int          cycles;
        exp = md_ref(o, x, y);
        @(negedge clk);
        op = o; a = x; b = y;
        if (!o[2]) begin                    // MUL..MULHU (funct3 bit 2 = 0)
            #1 got = mul_y;
        end else begin
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            a = $urandom; b = $urandom;     // operands must have been captured
            cycles = 1;
            while (!done && cycles <= 40) begin
                @(negedge clk);
                cycles++;
            end
            got = div_y;
            if (cycles != 33) begin
                errors++;
                if (errors <= 20) $display("FAIL timing: done after %0d cycles, expected 33", cycles);
            end
        end
        checks++;
        if (got !== exp) begin
            errors++;
            if (errors <= 20)
                $display("FAIL op=%0d a=%h b=%h: expected %h, got %h", o, x, y, exp, got);
        end
    endtask

    // (a function, not an array literal: Icarus 12 can't assign whole arrays)
    function automatic logic [31:0] corner(input int i);
        case (i)
            0: return 32'h0;          1: return 32'h1;          2: return 32'hFFFF_FFFF;
            3: return 32'h8000_0000;  4: return 32'h7FFF_FFFF;  5: return 32'h2;
            6: return 32'hFFFF_FFFE;  7: return 32'h7;          8: return 32'hFFFF_FFF9;
            default: return 32'h0001_0000;
        endcase
    endfunction

    initial begin
        start = 1'b0; flush = 1'b0; op = MD_MUL; a = 0; b = 0;
        repeat (2) @(posedge clk);
        @(negedge clk) rst = 1'b0;

        for (int o = 0; o < 8; o++) begin
            for (int i = 0; i < 10; i++) for (int j = 0; j < 10; j++) check(md_op_t'(o), corner(i), corner(j));
            repeat (3000) check(md_op_t'(o), $urandom, $urandom);
            repeat (1000) check(md_op_t'(o), $urandom, $urandom_range(1, 20) * ($urandom_range(0, 1) ? 1 : -1));
        end

        // flush mid-divide: busy drops, no done, next divide still correct
        @(negedge clk);
        op = MD_DIV; a = 100; b = 7; start = 1'b1;
        @(negedge clk) start = 1'b0;
        repeat (10) @(negedge clk);
        flush = 1'b1;
        @(negedge clk) flush = 1'b0;
        checks++;
        if (busy || done) begin
            errors++;
            $display("FAIL flush: busy=%b done=%b after flush", busy, done);
        end
        check(MD_REM, 32'd100, 32'd7);

        if (errors == 0)
            $display("TEST PASSED (%0d checks)", checks);
        else
            $fatal(1, "TEST FAILED: %0d of %0d checks failed", errors, checks);
        $finish;
    end

endmodule
