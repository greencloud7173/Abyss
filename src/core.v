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
    output reg [PROGRAM_MEM_ADDR_BITS - 1:0] program_mem_read_address,
    input wire program_mem_read_ready,
    input wire [PROGRAM_MEM_DATA_BITS - 1:0] program_mem_read_data,
    // Data Memory
    output reg [THREADS_PER_BLOCK - 1:0] data_mem_read_valid,
    output reg [(THREADS_PER_BLOCK * DATA_MEM_ADDR_BITS) - 1:0] data_mem_read_address,
    input wire [THREADS_PER_BLOCK - 1:0] data_mem_read_ready,
    input wire [(THREADS_PER_BLOCK * DATA_MEM_DATA_BITS) - 1:0] data_mem_read_data,
    output reg [THREADS_PER_BLOCK - 1:0] data_mem_write_valid,
    output reg [(THREADS_PER_BLOCK * DATA_MEM_ADDR_BITS) - 1:0] data_mem_write_address,
    output reg [(THREADS_PER_BLOCK * DATA_MEM_DATA_BITS) - 1:0] data_mem_write_data,
    output reg [(THREADS_PER_BLOCK * (DATA_MEM_DATA_BITS / 8)) - 1:0] data_mem_write_mask,
    input wire [THREADS_PER_BLOCK - 1:0] data_mem_write_ready
);
    // State
    reg [2:0] core_state;
    reg [2:0] fetcher_state;
    reg [PROGRAM_MEM_DATA_BITS - 1:0] instruction;
    // Instruction cache: a hit is served immediately, and the cache is flushed
    // whenever the core is idle (i.e. at the start of a new kernel launch)
    wire fetch_hit;
    wire icache_flush = core_state == 3'b000;
    // Intermediate Signals
    reg [PROGRAM_MEM_ADDR_BITS - 1:0] current_pc;
    wire [(THREADS_PER_BLOCK * PROGRAM_MEM_ADDR_BITS) - 1:0] next_pc;
    reg [DATA_MEM_DATA_BITS - 1:0] rs [THREADS_PER_BLOCK - 1:0];
    reg [DATA_MEM_DATA_BITS - 1:0] rt [THREADS_PER_BLOCK - 1:0];
    reg [(THREADS_PER_BLOCK * 2) - 1:0] lsu_state;
    reg [DATA_MEM_DATA_BITS - 1:0] lsu_out [THREADS_PER_BLOCK - 1:0];
    wire [DATA_MEM_DATA_BITS - 1:0] alu_out [THREADS_PER_BLOCK - 1:0];
    wire [PROGRAM_MEM_ADDR_BITS - 1:0] pc_result [THREADS_PER_BLOCK - 1:0];
    // Is any lane still running a multi-cycle division?  OR-reduced so it costs
    // a single wide gate instead of a priority chain.
    wire [THREADS_PER_BLOCK - 1:0] alu_busy;
    wire any_alu_busy = |alu_busy;
    // Decoded Instruction Signals
    reg [4:0] decoded_rd_address;
    reg [4:0] decoded_rs_address;
    reg [4:0] decoded_rt_address;
    reg [31:0] decoded_immediate;
    // Decoded Control Signals
    reg decoded_reg_write_enable; // Enable writing to a register
    reg decoded_mem_read_enable; // Enable reading from memory
    reg decoded_mem_write_enable; // Enable writing to memory
    reg [1:0] decoded_mem_size; // Access width: 00 byte, 01 half, 10 word
    reg decoded_mem_unsigned; // Zero-extend narrow loads (LBU / LHU)
    reg [1:0] decoded_reg_input_mux; // Select input to register
    reg [3:0] decoded_alu_arithmetic_mux; // Select arithmetic operation
    reg decoded_alu_imm_enable; // Use imm12 as the ALU B operand (ADDI)
    reg decoded_branch_enable; // Branch (B-type) instruction
    reg [2:0] decoded_branch_cond; // Branch condition (= funct3)
    reg decoded_jump_enable; // Jump with link (J-type JAL)
    reg decoded_jalr_enable; // Jump with link, register target (I-type JALR)
    reg decoded_ret;
    wire [1:1] sv2v_tmp_fetcher_instance_mem_read_valid;
    always @(*) program_mem_read_valid = sv2v_tmp_fetcher_instance_mem_read_valid;
    wire [PROGRAM_MEM_ADDR_BITS:1] sv2v_tmp_fetcher_instance_mem_read_address;
    always @(*) program_mem_read_address = sv2v_tmp_fetcher_instance_mem_read_address;
    wire [3:1] sv2v_tmp_fetcher_instance_fetcher_state;
    always @(*) fetcher_state = sv2v_tmp_fetcher_instance_fetcher_state;
    wire [PROGRAM_MEM_DATA_BITS:1] sv2v_tmp_fetcher_instance_instruction;
    always @(*) instruction = sv2v_tmp_fetcher_instance_instruction;
    // Fetcher
    fetcher #(
        .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
        .PROGRAM_MEM_DATA_BITS(PROGRAM_MEM_DATA_BITS)
    ) fetcher_instance(
        .clk(clk),
        .reset(reset),
        .flush(icache_flush),
        .core_state(core_state),
        .current_pc(current_pc),
        .mem_read_valid(sv2v_tmp_fetcher_instance_mem_read_valid),
        .mem_read_address(sv2v_tmp_fetcher_instance_mem_read_address),
        .mem_read_ready(program_mem_read_ready),
        .mem_read_data(program_mem_read_data),
        .fetcher_state(sv2v_tmp_fetcher_instance_fetcher_state),
        .instruction(sv2v_tmp_fetcher_instance_instruction),
        .fetch_hit(fetch_hit)
    );
    wire [5:1] sv2v_tmp_decoder_instance_decoded_rd_address;
    always @(*) decoded_rd_address = sv2v_tmp_decoder_instance_decoded_rd_address;
    wire [5:1] sv2v_tmp_decoder_instance_decoded_rs_address;
    always @(*) decoded_rs_address = sv2v_tmp_decoder_instance_decoded_rs_address;
    wire [5:1] sv2v_tmp_decoder_instance_decoded_rt_address;
    always @(*) decoded_rt_address = sv2v_tmp_decoder_instance_decoded_rt_address;
    wire [32:1] sv2v_tmp_decoder_instance_decoded_immediate;
    always @(*) decoded_immediate = sv2v_tmp_decoder_instance_decoded_immediate;
    wire [1:1] sv2v_tmp_decoder_instance_decoded_reg_write_enable;
    always @(*) decoded_reg_write_enable = sv2v_tmp_decoder_instance_decoded_reg_write_enable;
    wire [1:1] sv2v_tmp_decoder_instance_decoded_mem_read_enable;
    always @(*) decoded_mem_read_enable = sv2v_tmp_decoder_instance_decoded_mem_read_enable;
    wire [1:1] sv2v_tmp_decoder_instance_decoded_mem_write_enable;
    always @(*) decoded_mem_write_enable = sv2v_tmp_decoder_instance_decoded_mem_write_enable;
    wire [2:1] sv2v_tmp_decoder_instance_decoded_mem_size;
    always @(*) decoded_mem_size = sv2v_tmp_decoder_instance_decoded_mem_size;
    wire [1:1] sv2v_tmp_decoder_instance_decoded_mem_unsigned;
    always @(*) decoded_mem_unsigned = sv2v_tmp_decoder_instance_decoded_mem_unsigned;
    wire [2:1] sv2v_tmp_decoder_instance_decoded_reg_input_mux;
    always @(*) decoded_reg_input_mux = sv2v_tmp_decoder_instance_decoded_reg_input_mux;
    wire [4:1] sv2v_tmp_decoder_instance_decoded_alu_arithmetic_mux;
    always @(*) decoded_alu_arithmetic_mux = sv2v_tmp_decoder_instance_decoded_alu_arithmetic_mux;
    wire [1:1] sv2v_tmp_decoder_instance_decoded_alu_imm_enable;
    always @(*) decoded_alu_imm_enable = sv2v_tmp_decoder_instance_decoded_alu_imm_enable;
    wire [1:1] sv2v_tmp_decoder_instance_decoded_branch_enable;
    always @(*) decoded_branch_enable = sv2v_tmp_decoder_instance_decoded_branch_enable;
    wire [3:1] sv2v_tmp_decoder_instance_decoded_branch_cond;
    always @(*) decoded_branch_cond = sv2v_tmp_decoder_instance_decoded_branch_cond;
    wire [1:1] sv2v_tmp_decoder_instance_decoded_jump_enable;
    always @(*) decoded_jump_enable = sv2v_tmp_decoder_instance_decoded_jump_enable;
    wire [1:1] sv2v_tmp_decoder_instance_decoded_jalr_enable;
    always @(*) decoded_jalr_enable = sv2v_tmp_decoder_instance_decoded_jalr_enable;
    wire [1:1] sv2v_tmp_decoder_instance_decoded_ret;
    always @(*) decoded_ret = sv2v_tmp_decoder_instance_decoded_ret;
    // Decoder
    decoder decoder_instance(
        .clk(clk),
        .reset(reset),
        .core_state(core_state),
        .instruction(instruction),
        .decoded_rd_address(sv2v_tmp_decoder_instance_decoded_rd_address),
        .decoded_rs_address(sv2v_tmp_decoder_instance_decoded_rs_address),
        .decoded_rt_address(sv2v_tmp_decoder_instance_decoded_rt_address),
        .decoded_immediate(sv2v_tmp_decoder_instance_decoded_immediate),
        .decoded_reg_write_enable(sv2v_tmp_decoder_instance_decoded_reg_write_enable),
        .decoded_mem_read_enable(sv2v_tmp_decoder_instance_decoded_mem_read_enable),
        .decoded_mem_write_enable(sv2v_tmp_decoder_instance_decoded_mem_write_enable),
        .decoded_mem_size(sv2v_tmp_decoder_instance_decoded_mem_size),
        .decoded_mem_unsigned(sv2v_tmp_decoder_instance_decoded_mem_unsigned),
        .decoded_reg_input_mux(sv2v_tmp_decoder_instance_decoded_reg_input_mux),
        .decoded_alu_arithmetic_mux(sv2v_tmp_decoder_instance_decoded_alu_arithmetic_mux),
        .decoded_alu_imm_enable(sv2v_tmp_decoder_instance_decoded_alu_imm_enable),
        .decoded_branch_enable(sv2v_tmp_decoder_instance_decoded_branch_enable),
        .decoded_branch_cond(sv2v_tmp_decoder_instance_decoded_branch_cond),
        .decoded_jump_enable(sv2v_tmp_decoder_instance_decoded_jump_enable),
        .decoded_jalr_enable(sv2v_tmp_decoder_instance_decoded_jalr_enable),
        .decoded_ret(sv2v_tmp_decoder_instance_decoded_ret)
    );
    wire [3:1] sv2v_tmp_scheduler_instance_core_state;
    always @(*) core_state = sv2v_tmp_scheduler_instance_core_state;
    wire [PROGRAM_MEM_ADDR_BITS:1] sv2v_tmp_scheduler_instance_current_pc;
    always @(*) current_pc = sv2v_tmp_scheduler_instance_current_pc;
    // Scheduler
    scheduler #(
        .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
        .THREADS_PER_BLOCK(THREADS_PER_BLOCK)
    ) scheduler_instance(
        .clk(clk),
        .reset(reset),
        .start(start),
        .thread_count(thread_count),
        .fetcher_state(fetcher_state),
        .fetch_hit(fetch_hit),
        .core_state(sv2v_tmp_scheduler_instance_core_state),
        .decoded_mem_read_enable(decoded_mem_read_enable),
        .decoded_mem_write_enable(decoded_mem_write_enable),
        .decoded_ret(decoded_ret),
        .lsu_state(lsu_state),
        .alu_busy(any_alu_busy),
        .current_pc(sv2v_tmp_scheduler_instance_current_pc),
        .next_pc(next_pc),
        .done(done)
    );
    // Dedicated ALU, LSU, registers, & PC unit for each thread this core has capacity for
    genvar _gv_i_1;
    generate
        for (_gv_i_1 = 0; _gv_i_1 < THREADS_PER_BLOCK; _gv_i_1 = _gv_i_1 + 1) begin : threads
            localparam i = _gv_i_1;
            // ALU
            alu #(.DATA_BITS(DATA_MEM_DATA_BITS)) alu_instance(
                .clk(clk),
                .reset(reset),
                .enable(i < thread_count),
                .core_state(core_state),
                .decoded_alu_arithmetic_mux(decoded_alu_arithmetic_mux),
                .decoded_alu_imm_enable(decoded_alu_imm_enable),
                .decoded_immediate(decoded_immediate),
                .rs(rs[i]),
                .rt(rt[i]),
                .alu_out(alu_out[i]),
                .div_busy(alu_busy[i])
            );
            wire [1:1] sv2v_tmp_lsu_instance_mem_read_valid;
            always @(*) data_mem_read_valid[i] = sv2v_tmp_lsu_instance_mem_read_valid;
            wire [DATA_MEM_ADDR_BITS * 1:1] sv2v_tmp_lsu_instance_mem_read_address;
            always @(*) data_mem_read_address[i * DATA_MEM_ADDR_BITS+:DATA_MEM_ADDR_BITS] = sv2v_tmp_lsu_instance_mem_read_address;
            wire [1:1] sv2v_tmp_lsu_instance_mem_write_valid;
            always @(*) data_mem_write_valid[i] = sv2v_tmp_lsu_instance_mem_write_valid;
            wire [DATA_MEM_ADDR_BITS * 1:1] sv2v_tmp_lsu_instance_mem_write_address;
            always @(*) data_mem_write_address[i * DATA_MEM_ADDR_BITS+:DATA_MEM_ADDR_BITS] = sv2v_tmp_lsu_instance_mem_write_address;
            wire [DATA_MEM_DATA_BITS * 1:1] sv2v_tmp_lsu_instance_mem_write_data;
            always @(*) data_mem_write_data[i * DATA_MEM_DATA_BITS+:DATA_MEM_DATA_BITS] = sv2v_tmp_lsu_instance_mem_write_data;
            wire [(DATA_MEM_DATA_BITS / 8) * 1:1] sv2v_tmp_lsu_instance_mem_write_mask;
            always @(*) data_mem_write_mask[i * (DATA_MEM_DATA_BITS / 8)+:DATA_MEM_DATA_BITS / 8] = sv2v_tmp_lsu_instance_mem_write_mask;
            wire [2:1] sv2v_tmp_lsu_instance_lsu_state;
            always @(*) lsu_state[i * 2+:2] = sv2v_tmp_lsu_instance_lsu_state;
            wire [DATA_MEM_DATA_BITS:1] sv2v_tmp_lsu_instance_lsu_out;
            always @(*) lsu_out[i] = sv2v_tmp_lsu_instance_lsu_out;
            // LSU
            lsu #(
                .ADDR_BITS(DATA_MEM_ADDR_BITS),
                .DATA_BITS(DATA_MEM_DATA_BITS)
            ) lsu_instance(
                .clk(clk),
                .reset(reset),
                .enable(i < thread_count),
                .core_state(core_state),
                .decoded_mem_read_enable(decoded_mem_read_enable),
                .decoded_mem_write_enable(decoded_mem_write_enable),
                .decoded_mem_size(decoded_mem_size),
                .decoded_mem_unsigned(decoded_mem_unsigned),
                .decoded_immediate(decoded_immediate),
                .mem_read_valid(sv2v_tmp_lsu_instance_mem_read_valid),
                .mem_read_address(sv2v_tmp_lsu_instance_mem_read_address),
                .mem_read_ready(data_mem_read_ready[i]),
                .mem_read_data(data_mem_read_data[i * DATA_MEM_DATA_BITS+:DATA_MEM_DATA_BITS]),
                .mem_write_valid(sv2v_tmp_lsu_instance_mem_write_valid),
                .mem_write_address(sv2v_tmp_lsu_instance_mem_write_address),
                .mem_write_data(sv2v_tmp_lsu_instance_mem_write_data),
                .mem_write_mask(sv2v_tmp_lsu_instance_mem_write_mask),
                .mem_write_ready(data_mem_write_ready[i]),
                .rs(rs[i]),
                .rt(rt[i]),
                .lsu_state(sv2v_tmp_lsu_instance_lsu_state),
                .lsu_out(sv2v_tmp_lsu_instance_lsu_out)
            );
            wire [DATA_MEM_DATA_BITS:1] sv2v_tmp_register_instance_rs;
            always @(*) rs[i] = sv2v_tmp_register_instance_rs;
            wire [DATA_MEM_DATA_BITS:1] sv2v_tmp_register_instance_rt;
            always @(*) rt[i] = sv2v_tmp_register_instance_rt;
            // Register File
            registers #(
                .THREADS_PER_BLOCK(THREADS_PER_BLOCK),
                .THREAD_ID(i),
                .DATA_BITS(DATA_MEM_DATA_BITS)
            ) register_instance(
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
                .rs(sv2v_tmp_register_instance_rs),
                .rt(sv2v_tmp_register_instance_rt)
            );
            // Program Counter
            pc #(
                .DATA_MEM_DATA_BITS(DATA_MEM_DATA_BITS),
                .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS)
            ) pc_instance(
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
                .next_pc(next_pc[i * PROGRAM_MEM_ADDR_BITS+:PROGRAM_MEM_ADDR_BITS]),
                .pc_result(pc_result[i])
            );
        end
    endgenerate
endmodule
