// tb_alu.sv - self-checking testbench for rtl/alu.sv
//
// Strategy:
//   1. directed edge cases (hand-picked, expected values written by hand)
//   2. every op on every pair of edge values (exhaustive over the corners)
//   3. every shift amount 0..31, with junk in b[31:5]
//   4. 10000 random cases, ~25% of operands biased toward edge values
//   every case is compared against model(), written from the RISC-V spec
//   (NOT copied from alu.sv - otherwise a bug in one is a bug in both)
//
// Run:   make test-alu                 (Icarus)
//        make test-alu SIM=verilator   (Verilator 5)
//        make waves-alu                (Icarus + build/sim/alu/tb_alu.vcd)
// Pass/fail: prints "TEST PASSED" or calls $fatal, so make exits non-zero.

module tb_alu;
    import riscv_pkg::*;

    logic [31:0] a, b, result;
    alu_op_t op;

    alu dut (
        .a      (a),
        .b      (b),
        .op     (op),
        .result (result)
    );

    int errors = 0;
    int checks = 0;

    function automatic logic [31:0] model(alu_op_t o, logic [31:0] x, logic [31:0] y);
        logic [4:0] amt;
        amt = y[4:0];                       // RV32I shifts only use the low 5 bits
        case (o)
            ALU_ADD:  return x + y;
            ALU_SUB:  return x - y;
            ALU_AND:  return x & y;
            ALU_OR:   return x | y;
            ALU_XOR:  return x ^ y;
            ALU_SLL:  return x << amt;
            ALU_SRL:  return x >> amt;
            // logical shift, then fill the top `amt` bits with x[31]
            // (~(all-ones >> amt) is a mask of exactly those top bits; 0 when amt=0)
            ALU_SRA:  return (x >> amt) | (x[31] ? ~(32'hFFFF_FFFF >> amt) : 32'h0);
            // sign-bit method:
            //   signs differ -> the negative one (sign bit 1) is smaller
            //   signs same   -> unsigned compare gives the right answer
            ALU_SLT:  return (x[31] != y[31]) ? {31'b0, x[31]} : {31'b0, x < y};
            ALU_SLTU: return {31'b0, x < y};
            default:  return '0;
        endcase
    endfunction

    // ---------------- drive -> wait -> compare ----------------
    task automatic check(alu_op_t o, logic [31:0] x, logic [31:0] y);
        logic [31:0] exp;
        a  = x;
        b  = y;
        op = o;
        #1;                                 // let the combinational logic settle
        exp = model(o, x, y);
        checks++;
        if (result !== exp) begin           // !== also catches x/z outputs
            errors++;
            if (errors <= 20)               // don't flood the log
                $display("FAIL %s a=%h b=%h: expected %h, got %h",
                         o.name(), x, y, exp, result);
        end
    endtask

    // ---------------- edge values ----------------
    // A function instead of an array literal: Icarus 12 can't assign a whole
    // unpacked array ('{...}), and a case statement works in every simulator.
    localparam int NUM_EDGES = 8;

    function automatic logic [31:0] edge_value(int i);
        case (i)
            0: return 32'h0000_0000;        // zero
            1: return 32'h0000_0001;        // one
            2: return 32'h7FFF_FFFF;        // most positive
            3: return 32'h8000_0000;        // most negative
            4: return 32'hFFFF_FFFF;        // -1 / all ones
            5: return 32'h0000_001F;        // max shift amount (31)
            6: return 32'hAAAA_AAAA;        // alternating bits
            default: return 32'h5555_5555;
        endcase
    endfunction

    function automatic logic [31:0] pick_value();
        // ~25% of the time use an edge value, otherwise fully random
        if ($urandom_range(0, 3) == 0)
            return edge_value($urandom_range(0, NUM_EDGES - 1));
        return $urandom;
    endfunction

    // ---------------- the test ----------------
    initial begin
        if ($test$plusargs("waves")) begin
            $dumpfile("build/sim/alu/tb_alu.vcd");
            $dumpvars(0, tb_alu);
        end

        // ---- 1. directed cases: write the expected value in a comment FIRST ----
        check(ALU_ADD,  32'hFFFF_FFFF, 32'd1);          // expect 0000_0000 (wraps)
        check(ALU_ADD,  32'h7FFF_FFFF, 32'd1);          // expect 8000_0000 (signed overflow, no trap)
        check(ALU_SUB,  32'd0,         32'd1);          // expect FFFF_FFFF
        check(ALU_SRA,  32'h8000_0000, 32'd4);          // expect F800_0000
        check(ALU_SRA,  32'h7FFF_FFFF, 32'd4);          // expect 07FF_FFFF (positive: fill with 0)
        check(ALU_SRA,  32'h8000_0000, 32'd0);          // expect 8000_0000 (shift by 0)
        check(ALU_SRA,  32'h8000_0000, 32'd31);         // expect FFFF_FFFF
        check(ALU_SRL,  32'h8000_0000, 32'd4);          // expect 0800_0000
        check(ALU_SLT,  32'hFFFF_FFFF, 32'd1);          // expect 1 (-1 < 1)
        check(ALU_SLTU, 32'hFFFF_FFFF, 32'd1);          // expect 0 (4294967295 > 1)
        check(ALU_SLT,  32'h8000_0000, 32'h7FFF_FFFF);  // expect 1 (most negative < most positive)
        check(ALU_SLT,  32'h8000_0000, 32'h8000_0000);  // expect 0 (equal)
        check(ALU_SLL,  32'd1,         32'd31);         // expect 8000_0000
        check(ALU_SLL,  32'd1,         32'd33);         // expect 0000_0002 (only b[4:0] counts)

        // ---- 2. every op x every pair of edge values (10 x 8 x 8 = 640) ----
        for (int o = 0; o <= 9; o++)
            for (int i = 0; i < NUM_EDGES; i++)
                for (int j = 0; j < NUM_EDGES; j++)
                    check(alu_op_t'(o), edge_value(i), edge_value(j));

        // ---- 3. every shift amount, with and without junk in b[31:5] ----
        for (int s = 0; s < 32; s++) begin
            check(ALU_SLL, 32'h8000_0001, s);
            check(ALU_SRL, 32'h8000_0001, s);
            check(ALU_SRA, 32'h8000_0001, s);
            check(ALU_SRA, 32'h7000_0001, s);
            check(ALU_SRA, 32'h8000_0001, s | 32'hFFFF_FFE0);
        end

        // ---- 4. random cases ----
        repeat (10000) begin
            check(alu_op_t'($urandom_range(0, 9)), pick_value(), pick_value());
        end

        // ---- verdict ----
        if (errors == 0)
            $display("TEST PASSED (%0d checks)", checks);
        else
            $fatal(1, "TEST FAILED: %0d of %0d checks failed", errors, checks);
        $finish;
    end

endmodule
