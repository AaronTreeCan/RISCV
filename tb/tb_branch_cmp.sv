// tb_branch_cmp.sv - self-checking testbench for rtl/branch_cmp.sv
//
// The RTL gets "less than" from the top bit of a 33-bit subtraction.
// The model uses SystemVerilog's own signed/unsigned compare operators,
// so the two take different routes to the same answer.
//
// Stimulus: every condition on every pair of edge values, equal operands,
// then 20000 random cases with operands often sharing their upper bits.

module tb_branch_cmp;
    import riscv_pkg::*;

    logic [31:0] a, b;
    branch_t     br;
    logic        taken;

    branch_cmp dut (.a(a), .b(b), .branch(br), .taken(taken));

    int errors = 0;
    int checks = 0;

    function automatic logic model(branch_t t, logic [31:0] x, logic [31:0] y);
        case (t)
            BR_EQ:   return x == y;
            BR_NE:   return x != y;
            BR_LT:   return $signed(x) <  $signed(y);
            BR_GE:   return $signed(x) >= $signed(y);
            BR_LTU:  return x <  y;
            BR_GEU:  return x >= y;
            default: return 1'b0;
        endcase
    endfunction

    task automatic check(branch_t t, logic [31:0] x, logic [31:0] y);
        logic exp;
        a = x; b = y; br = t;
        #1;
        exp = model(t, x, y);
        checks++;
        if (taken !== exp) begin
            errors++;
            if (errors <= 20)
                $display("FAIL %s a=%h b=%h: expected %b, got %b", t.name(), x, y, exp, taken);
        end
    endtask

    function automatic logic [31:0] edge_value(int i);
        case (i)
            0: return 32'h0000_0000;
            1: return 32'h0000_0001;
            2: return 32'h7FFF_FFFF;
            3: return 32'h8000_0000;
            4: return 32'h8000_0001;
            default: return 32'hFFFF_FFFF;
        endcase
    endfunction

    initial begin
        // every condition (including BR_NONE) x every pair of edge values
        for (int t = 0; t <= 6; t++)
            for (int i = 0; i < 6; i++)
                for (int j = 0; j < 6; j++)
                    check(branch_t'(t), edge_value(i), edge_value(j));

        // random: half the time b differs from a only in the low bits,
        // so equal/near-equal operands actually get exercised
        repeat (20000) begin
            logic [31:0] x, y;
            x = $urandom;
            y = ($urandom_range(0, 1) == 0) ? x ^ ($urandom & 32'h0000_000F) : $urandom;
            check(branch_t'($urandom_range(0, 6)), x, y);
        end

        if (errors == 0)
            $display("TEST PASSED (%0d checks)", checks);
        else
            $fatal(1, "TEST FAILED: %0d of %0d checks failed", errors, checks);
        $finish;
    end

endmodule
