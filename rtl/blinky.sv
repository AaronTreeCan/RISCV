// blinky.sv - example module for checking that the toolchain works.
//
// Toggles `led` every HALF_PERIOD clock cycles. This is the one RTL file the
// starter kit gives you; delete it once your own blocks have tests
// (and remove "blinky" from UNIT_TESTS in the Makefile).
//
// Patterns worth copying into your own modules:
//   - one clock, synchronous active-high reset
//   - all state in always_ff with non-blocking (<=) assignments
//   - every register gets a value in the reset branch

module blinky #(
    parameter int HALF_PERIOD = 4   // must be >= 2
) (
    input  logic clk,
    input  logic rst,   // synchronous, active high
    output logic led
);

    localparam int W = $clog2(HALF_PERIOD);

    logic [W-1:0] count;

    always_ff @(posedge clk) begin
        if (rst) begin
            count <= '0;
            led   <= 1'b0;
        end else if (count == HALF_PERIOD - 1) begin
            count <= '0;
            led   <= ~led;
        end else begin
            count <= count + 1'b1;
        end
    end

endmodule
