`default_nettype none
`timescale 1ns/1ns

// GPU
// > Built to use an external async memory with multi-channel read/write
// > Assumes that the program is loaded into program memory, data into data memory, and threads into
//   the device control register before the start signal is triggered
// > Has memory controllers to interface between external memory and its multiple cores
// > Configurable number of cores and thread capacity per core
module gpu #(
    parameter DATA_MEM_ADDR_BITS = 32, // Number of bits in data memory address
    parameter DATA_MEM_DATA_BITS = 32, // Number of bits in data memory value (32 bit data)
    parameter DATA_MEM_NUM_CHANNELS = 4, // Number of concurrent channels for sending requests to data memory
    parameter PROGRAM_MEM_ADDR_BITS = 32, // Number of bits in program memory address (256 rows)
    parameter PROGRAM_MEM_DATA_BITS = 32, // Number of bits in program memory value (16 bit instruction)
    parameter PROGRAM_MEM_NUM_CHANNELS = 1, // Number of concurrent channels for sending requests to program memory
    // 4 cores x 8 threads was the fastest Icarus configuration measured.
    // 8 cores x 8 threads raises the per-cycle simulation cost and runs slower.
    parameter NUM_CORES = 4, // Number of cores to include in this GPU
    parameter THREADS_PER_BLOCK = 8 // Number of threads to handle per block (determines the compute resources of each core)
) (
    input wire clk,
    input wire reset,
    // Kernel Execution
    input wire start,
    output wire done,
    // Device Control Register
    input wire device_control_write_enable,
    input wire [7:0] device_control_data,
    // Program Memory
    output wire [PROGRAM_MEM_NUM_CHANNELS - 1:0] program_mem_read_valid,
    output wire [(PROGRAM_MEM_NUM_CHANNELS * PROGRAM_MEM_ADDR_BITS) - 1:0] program_mem_read_address,
    input wire [PROGRAM_MEM_NUM_CHANNELS - 1:0] program_mem_read_ready,
    input wire [(PROGRAM_MEM_NUM_CHANNELS * PROGRAM_MEM_DATA_BITS) - 1:0] program_mem_read_data,
    // Data Memory
    output wire [DATA_MEM_NUM_CHANNELS - 1:0] data_mem_read_valid,
    output wire [(DATA_MEM_NUM_CHANNELS * DATA_MEM_ADDR_BITS) - 1:0] data_mem_read_address,
    input wire [DATA_MEM_NUM_CHANNELS - 1:0] data_mem_read_ready,
    input wire [(DATA_MEM_NUM_CHANNELS * DATA_MEM_DATA_BITS) - 1:0] data_mem_read_data,
    output wire [DATA_MEM_NUM_CHANNELS - 1:0] data_mem_write_valid,
    output wire [(DATA_MEM_NUM_CHANNELS * DATA_MEM_ADDR_BITS) - 1:0] data_mem_write_address,
    output wire [(DATA_MEM_NUM_CHANNELS * DATA_MEM_DATA_BITS) - 1:0] data_mem_write_data,
    output wire [(DATA_MEM_NUM_CHANNELS * (DATA_MEM_DATA_BITS / 8)) - 1:0] data_mem_write_mask,
    input wire [DATA_MEM_NUM_CHANNELS - 1:0] data_mem_write_ready
);
    // Control
    wire [7:0] thread_count;
    // Compute Core State
    reg [NUM_CORES - 1:0] core_start;
    reg [NUM_CORES - 1:0] core_reset;
    reg [NUM_CORES - 1:0] core_done;
    reg [(NUM_CORES * 8) - 1:0] core_block_id;
    reg [($clog2(THREADS_PER_BLOCK) >= 0 ? (NUM_CORES * ($clog2(THREADS_PER_BLOCK) + 1)) - 1 : (NUM_CORES * (1 - $clog2(THREADS_PER_BLOCK))) + ($clog2(THREADS_PER_BLOCK) - 1)):($clog2(THREADS_PER_BLOCK) >= 0 ? 0 : $clog2(THREADS_PER_BLOCK) + 0)] core_thread_count;
    // LSU <> Data Memory Controller Channels
    localparam NUM_LSUS = NUM_CORES * THREADS_PER_BLOCK;
    reg [NUM_LSUS - 1:0] lsu_read_valid;
    reg [(NUM_LSUS * DATA_MEM_ADDR_BITS) - 1:0] lsu_read_address;
    reg [NUM_LSUS - 1:0] lsu_read_ready;
    reg [(NUM_LSUS * DATA_MEM_DATA_BITS) - 1:0] lsu_read_data;
    reg [NUM_LSUS - 1:0] lsu_write_valid;
    reg [(NUM_LSUS * DATA_MEM_ADDR_BITS) - 1:0] lsu_write_address;
    reg [(NUM_LSUS * DATA_MEM_DATA_BITS) - 1:0] lsu_write_data;
    reg [(NUM_LSUS * (DATA_MEM_DATA_BITS / 8)) - 1:0] lsu_write_mask;
    reg [NUM_LSUS - 1:0] lsu_write_ready;
    // Fetcher <> Program Memory Controller Channels
    localparam NUM_FETCHERS = NUM_CORES;
    reg [NUM_FETCHERS - 1:0] fetcher_read_valid;
    reg [(NUM_FETCHERS * PROGRAM_MEM_ADDR_BITS) - 1:0] fetcher_read_address;
    reg [NUM_FETCHERS - 1:0] fetcher_read_ready;
    reg [(NUM_FETCHERS * PROGRAM_MEM_DATA_BITS) - 1:0] fetcher_read_data;
    // Device Control Register
    dcr dcr_instance(
        .clk(clk),
        .reset(reset),
        .device_control_write_enable(device_control_write_enable),
        .device_control_data(device_control_data),
        .thread_count(thread_count)
    );
    wire [NUM_LSUS:1] sv2v_tmp_data_memory_controller_consumer_read_ready;
    always @(*) lsu_read_ready = sv2v_tmp_data_memory_controller_consumer_read_ready;
    wire [NUM_LSUS * DATA_MEM_DATA_BITS:1] sv2v_tmp_data_memory_controller_consumer_read_data;
    always @(*) lsu_read_data = sv2v_tmp_data_memory_controller_consumer_read_data;
    wire [NUM_LSUS:1] sv2v_tmp_data_memory_controller_consumer_write_ready;
    always @(*) lsu_write_ready = sv2v_tmp_data_memory_controller_consumer_write_ready;
    // Data Memory Controller
    controller #(
        .ADDR_BITS(DATA_MEM_ADDR_BITS),
        .DATA_BITS(DATA_MEM_DATA_BITS),
        .NUM_CONSUMERS(NUM_LSUS),
        .NUM_CHANNELS(DATA_MEM_NUM_CHANNELS)
    ) data_memory_controller(
        .clk(clk),
        .reset(reset),
        .consumer_read_valid(lsu_read_valid),
        .consumer_read_address(lsu_read_address),
        .consumer_read_ready(sv2v_tmp_data_memory_controller_consumer_read_ready),
        .consumer_read_data(sv2v_tmp_data_memory_controller_consumer_read_data),
        .consumer_write_valid(lsu_write_valid),
        .consumer_write_address(lsu_write_address),
        .consumer_write_data(lsu_write_data),
        .consumer_write_mask(lsu_write_mask),
        .consumer_write_ready(sv2v_tmp_data_memory_controller_consumer_write_ready),
        .mem_read_valid(data_mem_read_valid),
        .mem_read_address(data_mem_read_address),
        .mem_read_ready(data_mem_read_ready),
        .mem_read_data(data_mem_read_data),
        .mem_write_valid(data_mem_write_valid),
        .mem_write_address(data_mem_write_address),
        .mem_write_data(data_mem_write_data),
        .mem_write_mask(data_mem_write_mask),
        .mem_write_ready(data_mem_write_ready)
    );
    wire [NUM_FETCHERS:1] sv2v_tmp_program_memory_controller_consumer_read_ready;
    always @(*) fetcher_read_ready = sv2v_tmp_program_memory_controller_consumer_read_ready;
    wire [NUM_FETCHERS * PROGRAM_MEM_DATA_BITS:1] sv2v_tmp_program_memory_controller_consumer_read_data;
    always @(*) fetcher_read_data = sv2v_tmp_program_memory_controller_consumer_read_data;
    // Program Memory Controller
    controller #(
        .ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
        .DATA_BITS(PROGRAM_MEM_DATA_BITS),
        .NUM_CONSUMERS(NUM_FETCHERS),
        .NUM_CHANNELS(PROGRAM_MEM_NUM_CHANNELS),
        .WRITE_ENABLE(0)
    ) program_memory_controller(
        .clk(clk),
        .reset(reset),
        .consumer_read_valid(fetcher_read_valid),
        .consumer_read_address(fetcher_read_address),
        .consumer_read_ready(sv2v_tmp_program_memory_controller_consumer_read_ready),
        .consumer_read_data(sv2v_tmp_program_memory_controller_consumer_read_data),
        .mem_read_valid(program_mem_read_valid),
        .mem_read_address(program_mem_read_address),
        .mem_read_ready(program_mem_read_ready),
        .mem_read_data(program_mem_read_data)
    );
    wire [NUM_CORES:1] sv2v_tmp_dispatch_instance_core_start;
    always @(*) core_start = sv2v_tmp_dispatch_instance_core_start;
    wire [NUM_CORES:1] sv2v_tmp_dispatch_instance_core_reset;
    always @(*) core_reset = sv2v_tmp_dispatch_instance_core_reset;
    wire [NUM_CORES * 8:1] sv2v_tmp_dispatch_instance_core_block_id;
    always @(*) core_block_id = sv2v_tmp_dispatch_instance_core_block_id;
    wire [(($clog2(THREADS_PER_BLOCK) >= 0 ? (NUM_CORES * ($clog2(THREADS_PER_BLOCK) + 1)) - 1 : (NUM_CORES * (1 - $clog2(THREADS_PER_BLOCK))) + ($clog2(THREADS_PER_BLOCK) - 1)) >= ($clog2(THREADS_PER_BLOCK) >= 0 ? 0 : $clog2(THREADS_PER_BLOCK) + 0) ? (($clog2(THREADS_PER_BLOCK) >= 0 ? (NUM_CORES * ($clog2(THREADS_PER_BLOCK) + 1)) - 1 : (NUM_CORES * (1 - $clog2(THREADS_PER_BLOCK))) + ($clog2(THREADS_PER_BLOCK) - 1)) - ($clog2(THREADS_PER_BLOCK) >= 0 ? 0 : $clog2(THREADS_PER_BLOCK) + 0)) + 1 : (($clog2(THREADS_PER_BLOCK) >= 0 ? 0 : $clog2(THREADS_PER_BLOCK) + 0) - ($clog2(THREADS_PER_BLOCK) >= 0 ? (NUM_CORES * ($clog2(THREADS_PER_BLOCK) + 1)) - 1 : (NUM_CORES * (1 - $clog2(THREADS_PER_BLOCK))) + ($clog2(THREADS_PER_BLOCK) - 1))) + 1):1] sv2v_tmp_dispatch_instance_core_thread_count;
    always @(*) core_thread_count = sv2v_tmp_dispatch_instance_core_thread_count;
    // Dispatcher
    dispatch #(
        .NUM_CORES(NUM_CORES),
        .THREADS_PER_BLOCK(THREADS_PER_BLOCK)
    ) dispatch_instance(
        .clk(clk),
        .reset(reset),
        .start(start),
        .thread_count(thread_count),
        .core_done(core_done),
        .core_start(sv2v_tmp_dispatch_instance_core_start),
        .core_reset(sv2v_tmp_dispatch_instance_core_reset),
        .core_block_id(sv2v_tmp_dispatch_instance_core_block_id),
        .core_thread_count(sv2v_tmp_dispatch_instance_core_thread_count),
        .done(done)
    );
    // Compute Cores
    genvar _gv_i_2;
    generate
        for (_gv_i_2 = 0; _gv_i_2 < NUM_CORES; _gv_i_2 = _gv_i_2 + 1) begin : cores
            localparam i = _gv_i_2;
            // EDA: We create separate signals here to pass to cores because of a requirement
            // by the OpenLane EDA flow (uses Verilog 2005) that prevents slicing the top-level signals
            reg [THREADS_PER_BLOCK - 1:0] core_lsu_read_valid;
            reg [(THREADS_PER_BLOCK * DATA_MEM_ADDR_BITS) - 1:0] core_lsu_read_address;
            reg [THREADS_PER_BLOCK - 1:0] core_lsu_read_ready;
            reg [(THREADS_PER_BLOCK * DATA_MEM_DATA_BITS) - 1:0] core_lsu_read_data;
            reg [THREADS_PER_BLOCK - 1:0] core_lsu_write_valid;
            reg [(THREADS_PER_BLOCK * DATA_MEM_ADDR_BITS) - 1:0] core_lsu_write_address;
            reg [(THREADS_PER_BLOCK * DATA_MEM_DATA_BITS) - 1:0] core_lsu_write_data;
            reg [(THREADS_PER_BLOCK * (DATA_MEM_DATA_BITS / 8)) - 1:0] core_lsu_write_mask;
            reg [THREADS_PER_BLOCK - 1:0] core_lsu_write_ready;
            // Pass through signals between LSUs and data memory controller
            genvar _gv_j_1;
            for (_gv_j_1 = 0; _gv_j_1 < THREADS_PER_BLOCK; _gv_j_1 = _gv_j_1 + 1) begin : genblk1
                localparam j = _gv_j_1;
                localparam lsu_index = (i * THREADS_PER_BLOCK) + j;
                always @(posedge clk) begin
                    lsu_read_valid[lsu_index] <= core_lsu_read_valid[j];
                    lsu_read_address[lsu_index * DATA_MEM_ADDR_BITS+:DATA_MEM_ADDR_BITS] <= core_lsu_read_address[j * DATA_MEM_ADDR_BITS+:DATA_MEM_ADDR_BITS];
                    lsu_write_valid[lsu_index] <= core_lsu_write_valid[j];
                    lsu_write_address[lsu_index * DATA_MEM_ADDR_BITS+:DATA_MEM_ADDR_BITS] <= core_lsu_write_address[j * DATA_MEM_ADDR_BITS+:DATA_MEM_ADDR_BITS];
                    lsu_write_data[lsu_index * DATA_MEM_DATA_BITS+:DATA_MEM_DATA_BITS] <= core_lsu_write_data[j * DATA_MEM_DATA_BITS+:DATA_MEM_DATA_BITS];
                    lsu_write_mask[lsu_index * (DATA_MEM_DATA_BITS / 8)+:DATA_MEM_DATA_BITS / 8] <= core_lsu_write_mask[j * (DATA_MEM_DATA_BITS / 8)+:DATA_MEM_DATA_BITS / 8];
                    core_lsu_read_ready[j] <= lsu_read_ready[lsu_index];
                    core_lsu_read_data[j * DATA_MEM_DATA_BITS+:DATA_MEM_DATA_BITS] <= lsu_read_data[lsu_index * DATA_MEM_DATA_BITS+:DATA_MEM_DATA_BITS];
                    core_lsu_write_ready[j] <= lsu_write_ready[lsu_index];
                end
            end
            wire [1:1] sv2v_tmp_core_instance_done;
            always @(*) core_done[i] = sv2v_tmp_core_instance_done;
            wire [1:1] sv2v_tmp_core_instance_program_mem_read_valid;
            always @(*) fetcher_read_valid[i] = sv2v_tmp_core_instance_program_mem_read_valid;
            wire [PROGRAM_MEM_ADDR_BITS * 1:1] sv2v_tmp_core_instance_program_mem_read_address;
            always @(*) fetcher_read_address[i * PROGRAM_MEM_ADDR_BITS+:PROGRAM_MEM_ADDR_BITS] = sv2v_tmp_core_instance_program_mem_read_address;
            wire [THREADS_PER_BLOCK:1] sv2v_tmp_core_instance_data_mem_read_valid;
            always @(*) core_lsu_read_valid = sv2v_tmp_core_instance_data_mem_read_valid;
            wire [THREADS_PER_BLOCK * DATA_MEM_ADDR_BITS:1] sv2v_tmp_core_instance_data_mem_read_address;
            always @(*) core_lsu_read_address = sv2v_tmp_core_instance_data_mem_read_address;
            wire [THREADS_PER_BLOCK:1] sv2v_tmp_core_instance_data_mem_write_valid;
            always @(*) core_lsu_write_valid = sv2v_tmp_core_instance_data_mem_write_valid;
            wire [THREADS_PER_BLOCK * DATA_MEM_ADDR_BITS:1] sv2v_tmp_core_instance_data_mem_write_address;
            always @(*) core_lsu_write_address = sv2v_tmp_core_instance_data_mem_write_address;
            wire [THREADS_PER_BLOCK * DATA_MEM_DATA_BITS:1] sv2v_tmp_core_instance_data_mem_write_data;
            always @(*) core_lsu_write_data = sv2v_tmp_core_instance_data_mem_write_data;
            wire [THREADS_PER_BLOCK * (DATA_MEM_DATA_BITS / 8):1] sv2v_tmp_core_instance_data_mem_write_mask;
            always @(*) core_lsu_write_mask = sv2v_tmp_core_instance_data_mem_write_mask;
            // Compute Core
            core #(
                .DATA_MEM_ADDR_BITS(DATA_MEM_ADDR_BITS),
                .DATA_MEM_DATA_BITS(DATA_MEM_DATA_BITS),
                .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
                .PROGRAM_MEM_DATA_BITS(PROGRAM_MEM_DATA_BITS),
                .THREADS_PER_BLOCK(THREADS_PER_BLOCK)
            ) core_instance(
                .clk(clk),
                .reset(core_reset[i]),
                .start(core_start[i]),
                .done(sv2v_tmp_core_instance_done),
                .block_id(core_block_id[i * 8+:8]),
                .thread_count(core_thread_count[($clog2(THREADS_PER_BLOCK) >= 0 ? 0 : $clog2(THREADS_PER_BLOCK)) + (i * ($clog2(THREADS_PER_BLOCK) >= 0 ? $clog2(THREADS_PER_BLOCK) + 1 : 1 - $clog2(THREADS_PER_BLOCK)))+:($clog2(THREADS_PER_BLOCK) >= 0 ? $clog2(THREADS_PER_BLOCK) + 1 : 1 - $clog2(THREADS_PER_BLOCK))]),
                .program_mem_read_valid(sv2v_tmp_core_instance_program_mem_read_valid),
                .program_mem_read_address(sv2v_tmp_core_instance_program_mem_read_address),
                .program_mem_read_ready(fetcher_read_ready[i]),
                .program_mem_read_data(fetcher_read_data[i * PROGRAM_MEM_DATA_BITS+:PROGRAM_MEM_DATA_BITS]),
                .data_mem_read_valid(sv2v_tmp_core_instance_data_mem_read_valid),
                .data_mem_read_address(sv2v_tmp_core_instance_data_mem_read_address),
                .data_mem_read_ready(core_lsu_read_ready),
                .data_mem_read_data(core_lsu_read_data),
                .data_mem_write_valid(sv2v_tmp_core_instance_data_mem_write_valid),
                .data_mem_write_address(sv2v_tmp_core_instance_data_mem_write_address),
                .data_mem_write_data(sv2v_tmp_core_instance_data_mem_write_data),
                .data_mem_write_mask(sv2v_tmp_core_instance_data_mem_write_mask),
                .data_mem_write_ready(core_lsu_write_ready)
            );
        end
    endgenerate
endmodule
