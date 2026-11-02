// bp.sv - branch predictor for the dual-issue core's fetch stage
//
// Two tables, both read combinationally from the fetch PC:
//
//   BTB (branch target buffer), one entry per fetch pair (8-byte block):
//     valid, tag, slot (which word of the pair is the branch), is_jump,
//     target. A hit says "this pair holds a branch/jump that went taken
//     before, here is where it went".
//   PHT (pattern history table) of 2-bit saturating counters:
//     00 strong not-taken, 01 weak not-taken, 10 weak taken, 11 strong taken.
//     Indexed by the branch's PC (bimodal), or by PC XOR global history
//     (gshare, GSHARE = 1). Only conditional branches use it; JAL/JALR in
//     the BTB always predict taken.
//
// Predict taken = BTB hit (and the branch slot is at or after the fetch PC)
//                 and (is_jump or the counter's top bit is set).
//
// Updates come from EX lane 0 when a branch/jump resolves (not speculative):
//   - taken: write the BTB entry for its pair (slot, target, is_jump)
//   - conditional branch: move its counter one step toward the outcome
//   - gshare: shift the outcome into the global history register
// The PHT index each word got at fetch rides down the pipeline with it, so
// the update hits the same counter even if the history moved since.

module bp #(
    parameter int BI       = 6,         // BTB index bits: 64 entries
    parameter int TAG_BITS = 8,
    parameter int PI       = 6,         // PHT index bits: 64 counters
    parameter bit GSHARE   = 1'b0
) (
    input  logic        clk,
    input  logic        rst,

    // lookup (IF)
    input  logic [31:0] fetch_pc,
    output logic        pred_taken,
    output logic        pred_slot,      // which word of the pair is predicted taken
    output logic [31:0] pred_target,
    output logic [PI-1:0] idx0,         // PHT index of each word of the pair,
    output logic [PI-1:0] idx1,         // carried down the pipe for the update

    // update (EX lane 0)
    input  logic        upd_valid,      // a branch or jump resolved this cycle
    input  logic        upd_cond,       // conditional branch (uses the PHT)
    input  logic        upd_taken,
    input  logic [31:0] upd_pc,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0] upd_target,     // word aligned, low 2 bits unused
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [PI-1:0] upd_idx
);

    localparam int BTB_ENTRIES = 1 << BI;
    localparam int PHT_ENTRIES = 1 << PI;

    typedef struct packed {
        logic [TAG_BITS-1:0] tag;
        logic                slot;
        logic                is_jump;
        logic [29:0]         target;            // word address
    } btb_t;

    // Only the valid bits and counters are reset; the rest of an entry is
    // ignored until its valid bit is set.
    btb_t                         btb [BTB_ENTRIES];
    logic [BTB_ENTRIES-1:0]       btb_valid;
    logic [2*PHT_ENTRIES-1:0]     pht;          // counter i = pht[2*i +: 2]
    logic [PI-1:0] ghr;                         // global history (gshare only)

    // Each helper uses a slice of the PC, hence the lint_off.
    /* verilator lint_off UNUSEDSIGNAL */
    // pair index and tag: pc[BI+2:3] picks the entry, the bits above are the tag
    function automatic logic [BI-1:0] btb_index(input logic [31:0] pc);
        return pc[BI+2:3];
    endfunction
    function automatic logic [TAG_BITS-1:0] btb_tag(input logic [31:0] pc);
        return pc[BI+3+TAG_BITS-1:BI+3];
    endfunction
    function automatic logic [PI-1:0] pht_index(input logic [31:0] pc, input logic [PI-1:0] h);
        return pc[PI+1:2] ^ (GSHARE ? h : '0);
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // ---------------- lookup ----------------
    btb_t        e;
    logic        hit;

    assign e     = btb[btb_index(fetch_pc)];
    // a fetch at the second word only sees a branch in the second slot
    assign hit   = btb_valid[btb_index(fetch_pc)] && (e.tag == btb_tag(fetch_pc)) &&
                   (e.slot >= fetch_pc[2]);

    // Every word gets its own index (even on a BTB miss), so a branch that
    // isn't in the BTB yet still trains the counter it will later use.
    assign idx0        = pht_index({fetch_pc[31:3], 3'b000}, ghr);
    assign idx1        = pht_index({fetch_pc[31:3], 3'b100}, ghr);
    assign pred_taken  = hit && (e.is_jump || pht[2*(e.slot ? idx1 : idx0) + 1]);
    assign pred_slot   = e.slot;
    assign pred_target = {e.target, 2'b00};

    // ---------------- update ----------------
    btb_t       new_e;
    logic [1:0] upd_ctr;

    assign new_e = {btb_tag(upd_pc), upd_pc[2], !upd_cond, upd_target[31:2]};
    assign upd_ctr = pht[2*upd_idx +: 2];

    always_ff @(posedge clk) begin
        if (rst) begin
            btb_valid <= '0;
            pht       <= {PHT_ENTRIES{2'b01}};     // weak not-taken
            ghr <= '0;
        end else if (upd_valid) begin
            if (upd_taken) begin
                btb_valid[btb_index(upd_pc)] <= 1'b1;
                btb[btb_index(upd_pc)]       <= new_e;
            end
            if (upd_cond) begin
                if (upd_ctr != 2'b11 && upd_taken)  pht[2*upd_idx +: 2] <= upd_ctr + 2'd1;
                if (upd_ctr != 2'b00 && !upd_taken) pht[2*upd_idx +: 2] <= upd_ctr - 2'd1;
                if (GSHARE) ghr <= {ghr[PI-2:0], upd_taken};
            end
        end
    end

endmodule
