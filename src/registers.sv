`default_nettype none
`timescale 1ns/1ns

// REGISTER FILE
// > Each thread within each core has it's own register file: x0 (hardwired zero),
// > 28 free registers, and 3 read-only registers
// > Read-only registers hold the familiar %blockIdx, %blockDim, and %threadIdx values critical to SIMD
module registers #(
    parameter THREADS_PER_BLOCK = 4,
    parameter THREAD_ID = 0,
    parameter DATA_BITS = 8
) (
    input wire clk,
    input wire reset,
    input wire enable, // If current block has less threads then block size, some registers will be inactive

    // Kernel Execution
    input reg [7:0] block_id,

    // State
    input reg [2:0] core_state,

    // Instruction Signals
    input reg [4:0] decoded_rd_address,
    input reg [4:0] decoded_rs_address,
    input reg [4:0] decoded_rt_address,

    // Control Signals
    input reg decoded_reg_write_enable,
    input reg [1:0] decoded_reg_input_mux,

    // Thread Unit Outputs
    input reg [DATA_BITS-1:0] alu_out,
    input reg [DATA_BITS-1:0] lsu_out,
    input reg [DATA_BITS-1:0] pc_result,

    // Registers
    output reg [DATA_BITS-1:0] rs,
    output reg [DATA_BITS-1:0] rt
);
    localparam ARITHMETIC = 2'b00,
        MEMORY = 2'b01,
        PC_VALUE = 2'b10;

    // 32 registers per thread: x0 (hardwired zero), R1-R28 free registers, 3 read-only registers
    localparam ZERO = 5'd0,       // x0: reads as 0, writes are ignored
        BLOCK_IDX = 5'd29,        // %blockIdx
        BLOCK_DIM = 5'd30,        // %blockDim
        THREAD_IDX = 5'd31;       // %threadIdx

    reg [DATA_BITS-1:0] registers[31:0];

    always @(posedge clk) begin
        if (reset) begin
            // Empty rs, rt
            rs <= 0;
            rt <= 0;
            // Initialize all free registers
            for (int i = 0; i < 32; i = i + 1) begin
                registers[i] <= {DATA_BITS{1'b0}};
            end
            // Initialize read-only registers
            registers[BLOCK_DIM] <= THREADS_PER_BLOCK; // %blockDim
            registers[THREAD_IDX] <= THREAD_ID;         // %threadIdx
        end else if (enable) begin 
            // [Bad Solution] Shouldn't need to set this every cycle
            registers[BLOCK_IDX] <= block_id; // Update the block_id when a new block is issued from dispatcher
            
            // Fill rs/rt when core_state = REQUEST
            if (core_state == 3'b011) begin 
                rs <= registers[decoded_rs_address];
                rt <= registers[decoded_rt_address];
            end

            // Store rd when core_state = UPDATE
            if (core_state == 3'b110) begin 
                // Only allow writing to the free registers (R1 - R28).
                // x0 is never written, so it keeps its reset value 0 and reads always
                // return 0 without needing any extra read mux.
                if (decoded_reg_write_enable && decoded_rd_address != ZERO && decoded_rd_address < BLOCK_IDX) begin
                    case (decoded_reg_input_mux)
                        ARITHMETIC: begin 
                            // ADD, SUB, MUL, DIV, ADDI
                            registers[decoded_rd_address] <= alu_out;
                        end
                        MEMORY: begin 
                            // LDR
                            registers[decoded_rd_address] <= lsu_out;
                        end
                        PC_VALUE: begin 
                            // JAL / AUIPC (value computed by the PC unit)
                            registers[decoded_rd_address] <= pc_result;
                        end
                    endcase
                end
            end
        end
    end
endmodule
