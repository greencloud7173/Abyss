`default_nettype none
`timescale 1ns/1ns

// SCHEDULER
// > Manages the entire control flow of a single compute core processing 1 block
// 1. FETCH - Retrieve instruction at current program counter (PC) from program memory
// 2. DECODE - Decode the instruction into the relevant control signals
// 3. REQUEST - If we have an instruction that accesses memory, trigger the async memory requests from LSUs
// 4. WAIT - Wait for all async memory requests to resolve (if applicable)
// 5. EXECUTE - Execute computations on retrieved data from registers / memory
// 6. UPDATE - Update register values and program counter
// > Each core has it's own scheduler where multiple threads can be processed with
//   the same control flow at once.
// > Technically, different instructions can branch to different PCs, requiring "branch divergence." In
//   this minimal implementation, we assume no branch divergence (naive approach for simplicity)
module scheduler #(
    parameter PROGRAM_MEM_ADDR_BITS = 8,
    parameter THREADS_PER_BLOCK = 4
) (
    input wire clk,
    input wire reset,
    input wire start,
    input wire [$clog2(THREADS_PER_BLOCK):0] thread_count,
    // Control Signals
    input wire decoded_mem_read_enable,
    input wire decoded_mem_write_enable,
    input wire decoded_ret,
    // Memory Access State
    input wire [2:0] fetcher_state,
    input wire fetch_hit, // instruction cache hit for current_pc
    input wire [(THREADS_PER_BLOCK * 2) - 1:0] lsu_state,
    input wire alu_busy, // any lane's divider still running
    // Current & Next PC
    output reg [PROGRAM_MEM_ADDR_BITS - 1:0] current_pc,
    input wire [(THREADS_PER_BLOCK * PROGRAM_MEM_ADDR_BITS) - 1:0] next_pc,
    // Execution State
    output reg [2:0] core_state,
    output reg done
);
    localparam IDLE = 3'b000; // Waiting to start
    localparam FETCH = 3'b001; // Fetch instructions from program memory
    localparam DECODE = 3'b010; // Decode instructions into control signals
    localparam REQUEST = 3'b011; // Request data from registers or memory
    localparam WAIT = 3'b100; // Wait for response from memory if necessary
    localparam EXECUTE = 3'b101; // Execute ALU and PC calculations
    localparam UPDATE = 3'b110; // Update registers and PC
    localparam DONE = 3'b111; // Done executing this block
    // Is any thread still waiting for its memory request?  (REQUESTING / WAITING)
    // Computed as an OR-reduce so it synthesizes to a single wide gate instead of
    // a priority-chained loop inside the clocked block.
    wire [THREADS_PER_BLOCK - 1:0] lsu_busy;
    genvar _gv_g_1;
    generate
        for (_gv_g_1 = 0; _gv_g_1 < THREADS_PER_BLOCK; _gv_g_1 = _gv_g_1 + 1) begin : lsu_busy_gen
            localparam g = _gv_g_1;
            assign lsu_busy[g] = (lsu_state[g * 2+:2] == 2'b01) || (lsu_state[g * 2+:2] == 2'b10);
        end
    endgenerate
    wire any_lsu_waiting = |lsu_busy;
    // Does this instruction touch data memory at all?  ALU / branch / jump /
    // LUI / AUIPC / RET do not, so they have nothing to wait for.
    wire needs_memory = decoded_mem_read_enable || decoded_mem_write_enable;
    always @(posedge clk)
        if (reset) begin
            current_pc <= 0;
            core_state <= IDLE;
            done <= 0;
        end
        else
            case (core_state)
                IDLE:
                    // Here after reset (before kernel is launched, or after previous block has been processed)
                    if (start)
                        // Start by fetching the next instruction for this block based on PC
                        core_state <= FETCH;
                FETCH:
                    if ((fetcher_state == 3'b010) || fetch_hit)
                        // Move on once fetcher_state = FETCHED. On an instruction-cache hit
                        // the word is already available, so DECODE starts one cycle early
                        // (no program-memory round trip at all).
                        core_state <= DECODE;
                DECODE: core_state <= REQUEST;
                // Decode is synchronous so we move on after one cycle
                REQUEST:
                    // The LSUs latch their request during this cycle (rs/rt are
                    // sampled here too).  Instructions that do not touch data
                    // memory have nothing to wait for, so they skip WAIT entirely:
                    // one cycle saved per ALU / branch / jump / LUI / AUIPC / RET.
                    if (needs_memory)
                        core_state <= WAIT;
                    else
                        core_state <= EXECUTE;
                WAIT:
                    // Wait for all LSUs to finish their request before continuing
                    // If no LSU is waiting for a response, move onto the next stage
                    if (!any_lsu_waiting)
                        core_state <= EXECUTE;
                EXECUTE:
                    // Most instructions are done in one cycle.  DIV / DIVU / REM
                    // / REMU instead run a multi-cycle divider, so the core parks
                    // here (the downstream units only look at core_state, so
                    // holding EXECUTE stalls everything for free) until the last
                    // lane has produced its result.
                    if (!alu_busy)
                        core_state <= UPDATE;
                UPDATE:
                    if (decoded_ret) begin
                        // If we reach a RET instruction, this block is done executing
                        done <= 1;
                        core_state <= DONE;
                    end
                    else begin
                        // TODO: Branch divergence. For now assume all active
                        // threads converge; ignore inactive lanes in a
                        // partially filled final block.
                        current_pc <= next_pc[(thread_count - 1) * PROGRAM_MEM_ADDR_BITS+:PROGRAM_MEM_ADDR_BITS];
                        // Update is synchronous so we move on after one cycle
                        core_state <= FETCH;
                    end
                DONE:
                    ;
            // no-op
            endcase
endmodule
