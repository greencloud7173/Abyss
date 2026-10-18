`default_nettype none
`timescale 1ns/1ns

// COMPUTE CORE
// > Handles processing 1 block at a time
// > The core also has it's own scheduler to manage control flow
// > Each core contains 1 fetcher & decoder, and register files, ALUs, LSUs, PC for each thread
module core #(
    parameter DATA_MEM_ADDR_BITS = 32,
    parameter DATA_MEM_DATA_BITS = 32,
    parameter PROGRAM_MEM_ADDR_BITS = 32,
    parameter PROGRAM_MEM_DATA_BITS = 32,
    parameter THREADS_PER_BLOCK = 4
) (
    input wire clk,
    input wire reset,

    // Kernel Execution
    input wire start,
    output wire done,

    // Block Metadata
    input wire [7:0] block_id,
    input wire [$clog2(THREADS_PER_BLOCK):0] thread_count,

    // Program Memory
    output reg program_mem_read_valid,
    output reg [PROGRAM_MEM_ADDR_BITS-1:0] program_mem_read_address,
    input reg program_mem_read_ready,
    input reg [PROGRAM_MEM_DATA_BITS-1:0] program_mem_read_data,

    // Data Memory
    output reg [THREADS_PER_BLOCK-1:0] data_mem_read_valid,
    output reg [DATA_MEM_ADDR_BITS-1:0] data_mem_read_address [THREADS_PER_BLOCK-1:0],
    input reg [THREADS_PER_BLOCK-1:0] data_mem_read_ready,
    input reg [DATA_MEM_DATA_BITS-1:0] data_mem_read_data [THREADS_PER_BLOCK-1:0],
    output reg [THREADS_PER_BLOCK-1:0] data_mem_write_valid,
    output reg [DATA_MEM_ADDR_BITS-1:0] data_mem_write_address [THREADS_PER_BLOCK-1:0],
    output reg [DATA_MEM_DATA_BITS-1:0] data_mem_write_data [THREADS_PER_BLOCK-1:0],
    output reg [(DATA_MEM_DATA_BITS/8)-1:0] data_mem_write_mask [THREADS_PER_BLOCK-1:0],
    input reg [THREADS_PER_BLOCK-1:0] data_mem_write_ready
);
    // State
    reg [2:0] core_state;
    reg [2:0] fetcher_state;
    reg [PROGRAM_MEM_DATA_BITS-1:0] instruction;

    // Intermediate Signals
    reg [PROGRAM_MEM_ADDR_BITS-1:0] current_pc;
    wire [PROGRAM_MEM_ADDR_BITS-1:0] next_pc[THREADS_PER_BLOCK-1:0];
    reg [DATA_MEM_DATA_BITS-1:0] rs[THREADS_PER_BLOCK-1:0];
    reg [DATA_MEM_DATA_BITS-1:0] rt[THREADS_PER_BLOCK-1:0];
    reg [1:0] lsu_state[THREADS_PER_BLOCK-1:0];
    reg [DATA_MEM_DATA_BITS-1:0] lsu_out[THREADS_PER_BLOCK-1:0];
    wire [DATA_MEM_DATA_BITS-1:0] alu_out[THREADS_PER_BLOCK-1:0];
    wire [PROGRAM_MEM_ADDR_BITS-1:0] pc_result[THREADS_PER_BLOCK-1:0];
    
    // Decoded Instruction Signals
    reg [4:0] decoded_rd_address;
    reg [4:0] decoded_rs_address;
    reg [4:0] decoded_rt_address;
    reg [31:0] decoded_immediate;

    // Decoded Control Signals
    reg decoded_reg_write_enable;           // Enable writing to a register
    reg decoded_mem_read_enable;            // Enable reading from memory
    reg decoded_mem_write_enable;           // Enable writing to memory
    reg [1:0] decoded_mem_size;             // Access width: 00 byte, 01 half, 10 word
    reg decoded_mem_unsigned;               // Zero-extend narrow loads (LBU / LHU)
    reg [1:0] decoded_reg_input_mux;        // Select input to register
    reg [2:0] decoded_alu_arithmetic_mux;   // Select arithmetic operation
    reg decoded_alu_imm_enable;             // Use imm12 as the ALU B operand (ADDI)
    reg decoded_branch_enable;              // Branch (B-type) instruction
    reg [2:0] decoded_branch_cond;          // Branch condition (= funct3)
    reg decoded_jump_enable;                // Jump with link (J-type JAL)
    reg decoded_jalr_enable;                // Jump with link, register target (I-type JALR)
    reg decoded_ret;

    // Fetcher
    fetcher #(
        .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
        .PROGRAM_MEM_DATA_BITS(PROGRAM_MEM_DATA_BITS)
    ) fetcher_instance (
        .clk(clk),
        .reset(reset),
        .core_state(core_state),
        .current_pc(current_pc),
        .mem_read_valid(program_mem_read_valid),
        .mem_read_address(program_mem_read_address),
        .mem_read_ready(program_mem_read_ready),
        .mem_read_data(program_mem_read_data),
        .fetcher_state(fetcher_state),
        .instruction(instruction) 
    );

    // Decoder
    decoder decoder_instance (
        .clk(clk),
        .reset(reset),
        .core_state(core_state),
        .instruction(instruction),
        .decoded_rd_address(decoded_rd_address),
        .decoded_rs_address(decoded_rs_address),
        .decoded_rt_address(decoded_rt_address),
        .decoded_immediate(decoded_immediate),
        .decoded_reg_write_enable(decoded_reg_write_enable),
        .decoded_mem_read_enable(decoded_mem_read_enable),
        .decoded_mem_write_enable(decoded_mem_write_enable),
        .decoded_mem_size(decoded_mem_size),
        .decoded_mem_unsigned(decoded_mem_unsigned),
        .decoded_reg_input_mux(decoded_reg_input_mux),
        .decoded_alu_arithmetic_mux(decoded_alu_arithmetic_mux),
        .decoded_alu_imm_enable(decoded_alu_imm_enable),
        .decoded_branch_enable(decoded_branch_enable),
        .decoded_branch_cond(decoded_branch_cond),
        .decoded_jump_enable(decoded_jump_enable),
        .decoded_jalr_enable(decoded_jalr_enable),
        .decoded_ret(decoded_ret)
    );

    // Scheduler
    scheduler #(
        .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
        .THREADS_PER_BLOCK(THREADS_PER_BLOCK)
    ) scheduler_instance (
        .clk(clk),
        .reset(reset),
        .start(start),
        .fetcher_state(fetcher_state),
        .core_state(core_state),
        .decoded_mem_read_enable(decoded_mem_read_enable),
        .decoded_mem_write_enable(decoded_mem_write_enable),
        .decoded_ret(decoded_ret),
        .lsu_state(lsu_state),
        .current_pc(current_pc),
        .next_pc(next_pc),
        .done(done)
    );

    // Dedicated ALU, LSU, registers, & PC unit for each thread this core has capacity for
    genvar i;
    generate
        for (i = 0; i < THREADS_PER_BLOCK; i = i + 1) begin : threads
            // ALU
            alu #(
                .DATA_BITS(DATA_MEM_DATA_BITS)
            ) alu_instance (
                .clk(clk),
                .reset(reset),
                .enable(i < thread_count),
                .core_state(core_state),
                .decoded_alu_arithmetic_mux(decoded_alu_arithmetic_mux),
                .decoded_alu_imm_enable(decoded_alu_imm_enable),
                .decoded_immediate(decoded_immediate),
                .rs(rs[i]),
                .rt(rt[i]),
                .alu_out(alu_out[i])
            );

            // LSU
            lsu #(
                .ADDR_BITS(DATA_MEM_ADDR_BITS),
                .DATA_BITS(DATA_MEM_DATA_BITS)
            ) lsu_instance (
                .clk(clk),
                .reset(reset),
                .enable(i < thread_count),
                .core_state(core_state),
                .decoded_mem_read_enable(decoded_mem_read_enable),
                .decoded_mem_write_enable(decoded_mem_write_enable),
                .decoded_mem_size(decoded_mem_size),
                .decoded_mem_unsigned(decoded_mem_unsigned),
                .decoded_immediate(decoded_immediate),
                .mem_read_valid(data_mem_read_valid[i]),
                .mem_read_address(data_mem_read_address[i]),
                .mem_read_ready(data_mem_read_ready[i]),
                .mem_read_data(data_mem_read_data[i]),
                .mem_write_valid(data_mem_write_valid[i]),
                .mem_write_address(data_mem_write_address[i]),
                .mem_write_data(data_mem_write_data[i]),
                .mem_write_mask(data_mem_write_mask[i]),
                .mem_write_ready(data_mem_write_ready[i]),
                .rs(rs[i]),
                .rt(rt[i]),
                .lsu_state(lsu_state[i]),
                .lsu_out(lsu_out[i])
            );

            // Register File
            registers #(
                .THREADS_PER_BLOCK(THREADS_PER_BLOCK),
                .THREAD_ID(i),
                .DATA_BITS(DATA_MEM_DATA_BITS)
            ) register_instance (
                .clk(clk),
                .reset(reset),
                .enable(i < thread_count),
                .block_id(block_id),
                .core_state(core_state),
                .decoded_reg_write_enable(decoded_reg_write_enable),
                .decoded_reg_input_mux(decoded_reg_input_mux),
                .decoded_rd_address(decoded_rd_address),
                .decoded_rs_address(decoded_rs_address),
                .decoded_rt_address(decoded_rt_address),
                .alu_out(alu_out[i]),
                .lsu_out(lsu_out[i]),
                .pc_result(pc_result[i]),
                .rs(rs[i]),
                .rt(rt[i])
            );

            // Program Counter
            pc #(
                .DATA_MEM_DATA_BITS(DATA_MEM_DATA_BITS),
                .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS)
            ) pc_instance (
                .clk(clk),
                .reset(reset),
                .enable(i < thread_count),
                .core_state(core_state),
                .decoded_branch_enable(decoded_branch_enable),
                .decoded_branch_cond(decoded_branch_cond),
                .decoded_jump_enable(decoded_jump_enable),
                .decoded_jalr_enable(decoded_jalr_enable),
                .decoded_immediate(decoded_immediate),
                .rs(rs[i]),
                .rt(rt[i]),
                .current_pc(current_pc),
                .next_pc(next_pc[i]),
                .pc_result(pc_result[i])
            );
        end
    endgenerate
endmodule
