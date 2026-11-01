// tb_soc.sv - runs a program on a core and checks every instruction it
// retires against the single-cycle core (lockstep)
//
//   make prog-hello                     build sw/c/hello.c, run it on the dual-issue core
//   make prog-hello CORE=1              same on the 5-stage scalar pipeline
//   make prog-hello SIM=verilator       same on Verilator
//
// Plusargs:
//   +hex=<file>          program image (set by the Makefile)
//   +max_cycles=<n>      timeout, default 1,000,000
//   +waves               dump build/sim/c<CORE>/prog-<name>/tb_soc.vcd
//
// Two SoCs load the same program:
//   dut  = the core under test, chosen by the CORE parameter (see soc.sv)
//   ref  = single-cycle core, the reference model
// The testbench clocks the reference core itself: one extra clock pulse per
// instruction the DUT retires (up to 2 per cycle on the dual-issue core), so
// both step through the program in the same order.
// Each retired instruction must match exactly: pc, encoding, register write,
// and store. That catches hazard bugs at the first wrong instruction, not
// thousands of cycles later when a test result comes out wrong.
//
// A program ends in one of three ways:
//   store to EXIT       1 = pass, anything else = fail code (value >> 1)  (crt0 / C tests)
//   ECALL / EBREAK      pass if a7 == 93 and a0 == 0                      (riscv-tests style)
//   illegal instruction always a failure
// Characters stored to PUTCHAR are printed as they arrive.

module tb_soc
    import riscv_pkg::*;
#(
    parameter int CORE = 2      // set by the Makefile (CORE=...)
);

    logic        clk = 1'b0;
    logic        rst = 1'b1;

    // ---------------- design under test ----------------
    logic        exit_valid, putc_valid, halted, illegal;
    logic [31:0] exit_code;
    logic [7:0]  putc_char;
    retire_t     dut_ret0, dut_ret1;

    soc #(.CORE(CORE)) dut (
        .clk        (clk),
        .rst        (rst),
        .exit_valid (exit_valid),
        .exit_code  (exit_code),
        .putc_valid (putc_valid),
        .putc_char  (putc_char),
        .halted     (halted),
        .illegal    (illegal),
        .retire0    (dut_ret0),
        .retire1    (dut_ret1)
    );

    // ---------------- reference: single-cycle ----------------
    // Clocked only by ref_step(), which the checker calls while clk is low.
    logic        ref_clk = 1'b0;
    retire_t     ref_ret, ref_ret_unused;
    logic        ref_exit_valid, ref_putc_valid, ref_halted, ref_illegal;
    logic [31:0] ref_exit_code;
    logic [7:0]  ref_putc_char;

    soc #(.CORE(0)) ref_soc (
        .clk        (ref_clk),
        .rst        (rst),
        .exit_valid (ref_exit_valid),
        .exit_code  (ref_exit_code),
        .putc_valid (ref_putc_valid),
        .putc_char  (ref_putc_char),
        .halted     (ref_halted),
        .illegal    (ref_illegal),
        .retire0    (ref_ret),
        .retire1    (ref_ret_unused)
    );

    // One reference instruction: rising edge, then let its outputs settle.
    task automatic ref_step();
        ref_clk = 1'b1;
        #1;
        ref_clk = 1'b0;
        #1;
    endtask

    always #5 clk = ~clk;

    // Architectural registers, rebuilt from the retire stream
    logic [31:0]     xreg [32];
    longint unsigned cycles, retired, pairs;
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
        return $sformatf("%0d cycles, %0d instructions (%0d cycles retired 2), IPC %0.3f, CPI %0.3f",
                         cycles, retired, pairs,
                         (cycles == 0)  ? 0.0 : real'(retired) / real'(cycles),
                         (retired == 0) ? 0.0 : real'(cycles) / real'(retired));
    endfunction

    // Compare one DUT retire against the reference's next instruction,
    // update the register shadow, and step the reference past it.
    task automatic check_retire(input retire_t r);
        if (!ref_ret.valid)
            finish_fail($sformatf("DUT retired %s, reference had already stopped", fmt(r)));
        if (visible(r) !== visible(ref_ret)) begin
            $display("[tb_soc] DUT      : %s", fmt(visible(r)));
            $display("[tb_soc] reference: %s", fmt(visible(ref_ret)));
            finish_fail($sformatf("lockstep mismatch on instruction #%0d", retired + 1));
        end
        if (r.rd_we) xreg[r.rd] = r.rd_wdata;
        last_pc = r.pc;
        retired++;
        ref_step();
    endtask

    task automatic finish_pass(input string how);
        $display("");
        $display("[tb_soc] core %0d %s: %s (every instruction matched the single-cycle core)",
                 CORE, how, stats());
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

        // hold reset for two rising edges (and reset the reference too)
        ref_step();
        ref_step();
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        #1;                     // let the DUT's outputs see reset go away

        cycles  = 0;
        retired = 0;
        pairs   = 0;
        last_pc = '0;
        // Each pass looks at the instructions that commit on the next rising
        // edge, half a cycle before it: the DUT's outputs are stable, and the
        // reference is stepped in the low half of the clock. (The first pass
        // is right at reset release, so the single-cycle core as DUT works too.)
        forever begin
            cycles++;

            if (dut_ret0.valid) check_retire(dut_ret0);
            if (dut_ret1.valid) begin
                if (!dut_ret0.valid) finish_fail("retire port 1 valid without port 0");
                check_retire(dut_ret1);
                pairs++;
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
            @(negedge clk);
        end
    end

endmodule
