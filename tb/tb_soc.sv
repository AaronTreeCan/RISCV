// tb_soc.sv - runs a program on the pipelined core and checks every
// instruction it retires against the single-cycle core (lockstep)
//
//   make prog-hello                     build sw/c/hello.c and run it (Icarus)
//   make prog-hello SIM=verilator       same on Verilator
//
// Plusargs:
//   +hex=<file>          program image (set by the Makefile)
//   +max_cycles=<n>      timeout, default 1,000,000
//   +waves               dump build/sim/prog-<name>/tb_soc.vcd
//
// Two SoCs load the same program:
//   dut  = 5-stage pipeline (the design under test)
//   ref  = single-cycle core, the reference model
// The reference core's clock only ticks when the pipeline retires an
// instruction, so both step through the program one instruction at a time.
// Each retired instruction must match exactly: pc, encoding, register write,
// and store. That catches hazard bugs at the first wrong instruction, not
// thousands of cycles later when a test result comes out wrong.
//
// A program ends in one of three ways:
//   store to EXIT       1 = pass, anything else = fail code (value >> 1)  (crt0 / C tests)
//   ECALL / EBREAK      pass if a7 == 93 and a0 == 0                      (riscv-tests style)
//   illegal instruction always a failure
// Characters stored to PUTCHAR are printed as they arrive.

module tb_soc;
    import riscv_pkg::*;

    logic        clk = 1'b0;
    logic        rst = 1'b1;

    // ---------------- design under test: pipelined ----------------
    logic        exit_valid, putc_valid, halted, illegal;
    logic [31:0] exit_code;
    logic [7:0]  putc_char;
    retire_t     dut_ret;

    soc #(.PIPELINED(1'b1)) dut (
        .clk        (clk),
        .rst        (rst),
        .exit_valid (exit_valid),
        .exit_code  (exit_code),
        .putc_valid (putc_valid),
        .putc_char  (putc_char),
        .halted     (halted),
        .illegal    (illegal),
        .retire     (dut_ret)
    );

    // ---------------- reference: single-cycle ----------------
    // ref_en changes only while clk is low, so the gated clock never glitches.
    logic        ref_en = 1'b1;     // free-running during reset
    logic        ref_clk;
    retire_t     ref_ret;
    logic        ref_exit_valid, ref_putc_valid, ref_halted, ref_illegal;
    logic [31:0] ref_exit_code;
    logic [7:0]  ref_putc_char;

    assign ref_clk = clk & ref_en;

    soc #(.PIPELINED(1'b0)) ref_soc (
        .clk        (ref_clk),
        .rst        (rst),
        .exit_valid (ref_exit_valid),
        .exit_code  (ref_exit_code),
        .putc_valid (ref_putc_valid),
        .putc_char  (ref_putc_char),
        .halted     (ref_halted),
        .illegal    (ref_illegal),
        .retire     (ref_ret)
    );

    always #5 clk = ~clk;

    // Architectural registers, rebuilt from the retire stream
    logic [31:0]     xreg [32];
    longint unsigned cycles, retired;
    longint unsigned max_cycles;
    string           wave_file;
    logic [31:0]     last_pc;

    // console output
    always @(posedge clk) begin
        if (!rst && putc_valid) $write("%c", putc_char);
    end

    // Only the fields that matter for this instruction take part in the compare
    function automatic retire_t visible(input retire_t r);
        retire_t v;
        v = r;
        if (!v.rd_we) begin
            v.rd       = '0;
            v.rd_wdata = '0;
        end
        if (!v.mem_we) begin
            v.mem_addr  = '0;
            v.mem_be    = '0;
            v.mem_wdata = '0;
        end
        return v;
    endfunction

    function automatic string fmt(input retire_t r);
        return $sformatf("pc=%h instr=%h rd_we=%b x%0d=%h mem_we=%b [%h] be=%b data=%h",
                         r.pc, r.instr, r.rd_we, r.rd, r.rd_wdata,
                         r.mem_we, r.mem_addr, r.mem_be, r.mem_wdata);
    endfunction

    function automatic string stats();
        return $sformatf("%0d cycles, %0d instructions, CPI %0.3f",
                         cycles, retired, (retired == 0) ? 0.0 : real'(cycles) / real'(retired));
    endfunction

    task automatic finish_pass(input string how);
        $display("");
        $display("[tb_soc] %s: %s (every instruction matched the single-cycle core)", how, stats());
        $display("TEST PASSED");
        $finish;
    endtask

    task automatic finish_fail(input string why);
        $display("");
        $display("[tb_soc] FAIL: %s after %s (last retired pc=%h)", why, stats(), last_pc);
        $fatal(1, "TEST FAILED");
    endtask

    initial begin
        for (int i = 0; i < 32; i++) xreg[i] = 32'd0;
        if (!$value$plusargs("max_cycles=%d", max_cycles)) max_cycles = 1_000_000;
        if ($test$plusargs("waves")) begin
            if (!$value$plusargs("wavefile=%s", wave_file)) wave_file = "tb_soc.vcd";
            $dumpfile(wave_file);
            $dumpvars(0, tb_soc);
        end

        // hold reset for two rising edges, release it away from the edge
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst    = 1'b0;
        ref_en = 1'b0;

        cycles  = 0;
        retired = 0;
        last_pc = '0;
        forever begin
            // Look at both cores half a cycle after the edge (no race with
            // the clock), decide here whether the reference steps next edge.
            @(negedge clk);
            cycles++;

            ref_en = 1'b0;
            if (dut_ret.valid) begin
                if (!ref_ret.valid)
                    finish_fail($sformatf("pipeline retired %s, reference had already stopped",
                                          fmt(dut_ret)));
                if (visible(dut_ret) !== visible(ref_ret)) begin
                    $display("[tb_soc] pipeline : %s", fmt(visible(dut_ret)));
                    $display("[tb_soc] reference: %s", fmt(visible(ref_ret)));
                    finish_fail($sformatf("lockstep mismatch on instruction #%0d", retired + 1));
                end
                if (dut_ret.rd_we) xreg[dut_ret.rd] = dut_ret.rd_wdata;
                last_pc = dut_ret.pc;
                retired++;
                ref_en = 1'b1;
            end

            if (exit_valid) begin
                if (exit_code == 32'd1) finish_pass("exit(pass)");
                else finish_fail($sformatf("exit code %0d (raw %h)", exit_code >> 1, exit_code));
            end
            if (illegal)
                finish_fail("illegal instruction");
            if (halted) begin
                if (xreg[17] == 32'd93 && xreg[10] == 32'd0) finish_pass("ecall(pass)");
                else finish_fail($sformatf("ecall with a7=%0d a0=%0d", xreg[17], xreg[10]));
            end
            if (cycles >= max_cycles)
                finish_fail($sformatf("timeout, no exit within %0d cycles", max_cycles));
        end
    end

endmodule
