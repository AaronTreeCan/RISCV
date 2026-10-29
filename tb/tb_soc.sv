// tb_soc.sv - runs a program on the core and reports pass/fail
//
//   make prog-hello                     build sw/c/hello.c and run it (Icarus)
//   make prog-hello SIM=verilator       same on Verilator
//
// Plusargs:
//   +hex=<file>          program image (set by the Makefile)
//   +max_cycles=<n>      timeout, default 1,000,000
//   +waves               dump build/sim/prog-<name>/tb_soc.vcd
//
// A program ends in one of three ways:
//   store to EXIT       1 = pass, anything else = fail code (value >> 1)  (crt0 / C tests)
//   ECALL / EBREAK      pass if a7 == 93 and a0 == 0                      (riscv-tests style)
//   illegal instruction always a failure
// Characters stored to PUTCHAR are printed as they arrive.

module tb_soc;

    logic        clk = 1'b0;
    logic        rst = 1'b1;
    logic        exit_valid, putc_valid, halted, illegal;
    logic [31:0] exit_code;
    logic [7:0]  putc_char;

    soc dut (
        .clk        (clk),
        .rst        (rst),
        .exit_valid (exit_valid),
        .exit_code  (exit_code),
        .putc_valid (putc_valid),
        .putc_char  (putc_char),
        .halted     (halted),
        .illegal    (illegal)
    );

    always #5 clk = ~clk;

    // Register values, read straight out of the register file (x0 isn't stored)
    function automatic logic [31:0] xreg(input int n);
        return (n == 0) ? 32'd0 : dut.u_core.u_regfile.regs[n];
    endfunction

    longint unsigned cycles;
    longint unsigned max_cycles;
    string           wave_file;

    // console output
    always @(posedge clk) begin
        if (!rst && putc_valid) $write("%c", putc_char);
    end

    task automatic finish_pass(input string how);
        $display("");
        $display("[tb_soc] %s after %0d cycles (pc=%h)", how, cycles, dut.u_core.pc);
        $display("TEST PASSED");
        $finish;
    endtask

    task automatic finish_fail(input string why);
        $display("");
        $display("[tb_soc] FAIL: %s after %0d cycles (pc=%h)", why, cycles, dut.u_core.pc);
        $fatal(1, "TEST FAILED");
    endtask

    initial begin
        if (!$value$plusargs("max_cycles=%d", max_cycles)) max_cycles = 1_000_000;
        if ($test$plusargs("waves")) begin
            if (!$value$plusargs("wavefile=%s", wave_file)) wave_file = "tb_soc.vcd";
            $dumpfile(wave_file);
            $dumpvars(0, tb_soc);
        end

        // hold reset for two rising edges, release it away from the edge
        repeat (2) @(posedge clk);
        @(negedge clk) rst = 1'b0;

        cycles = 0;
        forever begin
            // Check the instruction that is about to commit, half a cycle
            // after the PC changed (no race with the clock edge).
            @(negedge clk);
            cycles++;

            if (exit_valid) begin
                if (exit_code == 32'd1) finish_pass("exit(pass)");
                else finish_fail($sformatf("exit code %0d (raw %h)", exit_code >> 1, exit_code));
            end
            if (illegal)
                finish_fail($sformatf("illegal instruction %h", dut.u_core.instr));
            if (halted) begin
                if (xreg(17) == 32'd93 && xreg(10) == 32'd0) finish_pass("ecall(pass)");
                else finish_fail($sformatf("ecall with a7=%0d a0=%0d", xreg(17), xreg(10)));
            end
            if (cycles >= max_cycles)
                finish_fail($sformatf("timeout, no exit within %0d cycles", max_cycles));
        end
    end

endmodule
