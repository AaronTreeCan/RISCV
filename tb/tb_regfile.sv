// tb_regfile.sv - self-checking testbench for rtl/regfile.sv
//
// Two DUTs share one clock:
//   dut2  - the default 2-read / 1-write file the single-cycle core uses
//   dut4  - a 4-read / 2-write file, the shape the dual-issue core will need
// Each has its own reference model (a plain array, updated after every edge).
//
// Timing: inputs change on the falling edge, reads are checked just before the
// rising edge (combinational reads must already be valid), and the model is
// updated right after the rising edge, the same moment the DUT writes.
//
// Phases:
//   1. fill every register, try to write x0, read everything back
//   2. read-during-write: same-cycle read sees OLD value, next cycle sees NEW
//   3. dut4 only: both write ports hit the same register -> port 1 wins
//   4. random cycles, with addresses biased toward x0 and a few hot registers

module tb_regfile;

    localparam int CYCLES = 5000;

    logic clk = 0;
    always #5 clk = ~clk;

    // ---------------- DUT 1: 2R1W ----------------
    logic [1:0][4:0]  r2_addr;
    logic [1:0][31:0] r2_data;
    logic [0:0]       w2_en;
    logic [0:0][4:0]  w2_addr;
    logic [0:0][31:0] w2_data;

    regfile #(.NUM_READ(2), .NUM_WRITE(1)) dut2 (
        .clk(clk), .raddr(r2_addr), .rdata(r2_data),
        .we(w2_en), .waddr(w2_addr), .wdata(w2_data)
    );

    // ---------------- DUT 2: 4R2W ----------------
    logic [3:0][4:0]  r4_addr;
    logic [3:0][31:0] r4_data;
    logic [1:0]       w4_en;
    logic [1:0][4:0]  w4_addr;
    logic [1:0][31:0] w4_data;

    regfile #(.NUM_READ(4), .NUM_WRITE(2)) dut4 (
        .clk(clk), .raddr(r4_addr), .rdata(r4_data),
        .we(w4_en), .waddr(w4_addr), .wdata(w4_data)
    );

    // ---------------- reference models ----------------
    logic [31:0] m2 [32];
    logic [31:0] m4 [32];

    int errors = 0;
    int checks = 0;

    function automatic logic [4:0] pick_addr();
        // 10% x0, 30% one of x1..x3 (forces collisions), rest anywhere
        int r = $urandom_range(0, 9);
        if (r == 0) return 5'd0;
        if (r <= 3) return 5'($urandom_range(1, 3));
        return 5'($urandom_range(0, 31));
    endfunction

    task automatic expect_eq(string what, logic [31:0] got, logic [31:0] exp);
        checks++;
        if (got !== exp) begin
            errors++;
            if (errors <= 20)
                $display("FAIL %s: expected %h, got %h (t=%0t)", what, exp, got, $time);
        end
    endtask

    // check every read port of both DUTs against the models (call before posedge)
    task automatic check_reads();
        for (int r = 0; r < 2; r++)
            expect_eq($sformatf("dut2 port %0d x%0d", r, r2_addr[r]), r2_data[r], m2[r2_addr[r]]);
        for (int r = 0; r < 4; r++)
            expect_eq($sformatf("dut4 port %0d x%0d", r, r4_addr[r]), r4_data[r], m4[r4_addr[r]]);
    endtask

    // apply this cycle's writes to the models (call after posedge)
    task automatic update_models();
        if (w2_en[0] && w2_addr[0] != 0) m2[w2_addr[0]] = w2_data[0];
        for (int w = 0; w < 2; w++)                 // port 1 last, so it wins
            if (w4_en[w] && w4_addr[w] != 0) m4[w4_addr[w]] = w4_data[w];
    endtask

    // one full cycle: inputs are already set; check, clock, update
    task automatic step();
        #1;                     // settle (we are just after a falling edge)
        check_reads();
        @(posedge clk);
        update_models();
        @(negedge clk);
    endtask

    task automatic idle_writes();
        w2_en = '0; w4_en = '0;
    endtask

    initial begin
        m2[0] = '0;
        m4[0] = '0;
        idle_writes();
        r2_addr = '0; r4_addr = '0;
        w2_addr = '0; w2_data = '0; w4_addr = '0; w4_data = '0;
        @(negedge clk);

        // ---- 1. fill x1..x31 (writes only, reads would be X before this) ----
        for (int i = 1; i < 32; i++) begin
            w2_en[0] = 1; w2_addr[0] = 5'(i); w2_data[0] = 32'h1111_1111 * i;
            w4_en = 2'b01; w4_addr[0] = 5'(i); w4_data[0] = 32'h0101_0101 * i;
            @(posedge clk); update_models(); @(negedge clk);
        end
        // try to write x0 on every port: must be ignored
        w2_en[0] = 1; w2_addr[0] = 0; w2_data[0] = 32'hDEAD_BEEF;
        w4_en = 2'b11; w4_addr = {5'd0, 5'd0}; w4_data = {32'hDEAD_BEEF, 32'hCAFE_F00D};
        @(posedge clk); update_models(); @(negedge clk);
        idle_writes();
        // read everything back, including x0
        for (int i = 0; i < 32; i++) begin
            r2_addr = {5'(i), 5'(31 - i)};
            r4_addr = {5'(i), 5'(31 - i), 5'((i + 7) % 32), 5'(i)};
            step();
        end

        // ---- 2. read-during-write: OLD value this cycle, NEW value next cycle ----
        w2_en[0] = 1; w2_addr[0] = 5'd5; w2_data[0] = 32'hAAAA_0005;
        w4_en = 2'b01; w4_addr[0] = 5'd5; w4_data[0] = 32'hBBBB_0005;
        r2_addr = {5'd5, 5'd5};
        r4_addr = {5'd5, 5'd5, 5'd5, 5'd5};
        #1;
        expect_eq("dut2 same-cycle read sees old x5", r2_data[0], 32'h1111_1111 * 5);
        expect_eq("dut4 same-cycle read sees old x5", r4_data[0], 32'h0101_0101 * 5);
        @(posedge clk); update_models(); @(negedge clk);
        idle_writes();
        #1;
        expect_eq("dut2 next-cycle read sees new x5", r2_data[0], 32'hAAAA_0005);
        expect_eq("dut4 next-cycle read sees new x5", r4_data[0], 32'hBBBB_0005);
        @(negedge clk);

        // ---- 3. dut4: both write ports, same register -> port 1 wins ----
        w4_en = 2'b11; w4_addr = {5'd9, 5'd9};      // {port1, port0}
        w4_data = {32'h0000_0001, 32'h0000_0000};   // port 1 writes 1, port 0 writes 0
        @(posedge clk); update_models(); @(negedge clk);
        idle_writes();
        r4_addr[0] = 5'd9;
        #1;
        expect_eq("dut4 write collision: port 1 wins", r4_data[0], 32'h0000_0001);
        @(negedge clk);

        // ---- 4. random cycles ----
        repeat (CYCLES) begin
            for (int r = 0; r < 2; r++) r2_addr[r] = pick_addr();
            for (int r = 0; r < 4; r++) r4_addr[r] = pick_addr();
            w2_en[0] = ($urandom_range(0, 3) != 0);   // write 75% of cycles
            w2_addr[0] = pick_addr();
            w2_data[0] = $urandom;
            for (int w = 0; w < 2; w++) begin
                w4_en[w] = ($urandom_range(0, 3) != 0);
                w4_addr[w] = pick_addr();
                w4_data[w] = $urandom;
            end
            step();
        end

        if (errors == 0)
            $display("TEST PASSED (%0d checks)", checks);
        else
            $fatal(1, "TEST FAILED: %0d of %0d checks failed", errors, checks);
        $finish;
    end

endmodule
