`default_nettype none
`timescale 1ns/1ns

// LOAD-STORE UNIT
// > Handles asynchronous memory load and store operations and waits for response
// > Each thread in each core has it's own LSU
// > Addresses are RISC-V style and are **byte addresses**: `byte_address = rs1 + imm`
// > The memory port itself is word addressed, so the LSU bridges the two:
// >   `word_address = byte_address >> 2`, `lane = byte_address[1:0]`
// > Sub-word access is done here by shifting / masking (the memory stays 32-bit):
// >   loads  : shift the addressed byte/half down, then sign- or zero-extend
// >   stores : shift the data into its lane and assert `mem_write_mask` (byte enables)
module lsu #(
    parameter ADDR_BITS = 8,
    parameter DATA_BITS = 8
) (
    input wire clk,
    input wire reset,
    input wire enable, // If current block has less threads then block size, some LSUs will be inactive

    // State
    input reg [2:0] core_state,

    // Memory Control Signals
    input reg decoded_mem_read_enable,
    input reg decoded_mem_write_enable,
    input reg [1:0] decoded_mem_size,   // 00 = byte, 01 = half word, 10 = word
    input reg decoded_mem_unsigned,     // 1 = zero-extend loads (LBU / LHU)

    // Instruction Signals
    input reg [DATA_BITS-1:0] decoded_immediate,

    // Registers
    input reg [DATA_BITS-1:0] rs,
    input reg [DATA_BITS-1:0] rt,

    // Data Memory
    output reg mem_read_valid,
    output reg [ADDR_BITS-1:0] mem_read_address,
    input reg mem_read_ready,
    input reg [DATA_BITS-1:0] mem_read_data,
    output reg mem_write_valid,
    output reg [ADDR_BITS-1:0] mem_write_address,
    output reg [DATA_BITS-1:0] mem_write_data,
    output reg [(DATA_BITS/8)-1:0] mem_write_mask, // byte enables for narrow stores
    input reg mem_write_ready,

    // LSU Outputs
    output reg [1:0] lsu_state,
    output reg [DATA_BITS-1:0] lsu_out
);
    localparam IDLE = 2'b00, REQUESTING = 2'b01, WAITING = 2'b10, DONE = 2'b11;
    localparam SIZE_BYTE = 2'b00, SIZE_HALF = 2'b01, SIZE_WORD = 2'b10;

    // Effective address: rs1 + the (already sign-extended) immediate, in BYTES
    wire signed [DATA_BITS-1:0] imm_signed;
    assign imm_signed = decoded_immediate;

    wire [DATA_BITS-1:0] byte_address;
    assign byte_address = rs + imm_signed;

    // Memory port is word addressed: drop the two lane bits
    wire [ADDR_BITS-1:0] word_address;
    assign word_address = {2'b00, byte_address[ADDR_BITS-1:2]};

    wire [1:0] lane;
    assign lane = byte_address[1:0];

    // Bring the addressed byte / half down to bit 0 (byte: lane * 8, half: lane[1] * 16)
    wire [4:0] read_shift;
    assign read_shift = (decoded_mem_size == SIZE_BYTE) ? {lane, 3'b000} :
                        (decoded_mem_size == SIZE_HALF) ? {lane[1], 4'b0000} :
                                                          5'b00000;

    wire [DATA_BITS-1:0] read_shifted;
    assign read_shifted = mem_read_data >> read_shift;

    // Keep only the accessed bytes, then sign- or zero-extend to the full word
    wire [DATA_BITS-1:0] read_value;
    assign read_value = (decoded_mem_size == SIZE_BYTE) ? {{(DATA_BITS-8){1'b0}}, read_shifted[7:0]} :
                        (decoded_mem_size == SIZE_HALF) ? {{(DATA_BITS-16){1'b0}}, read_shifted[15:0]} :
                                                          read_shifted;

    wire [DATA_BITS-1:0] read_extended;
    assign read_extended = decoded_mem_unsigned ? read_value :
                           (decoded_mem_size == SIZE_BYTE) ? {{(DATA_BITS-8){read_value[7]}}, read_value[7:0]} :
                           (decoded_mem_size == SIZE_HALF) ? {{(DATA_BITS-16){read_value[15]}}, read_value[15:0]} :
                                                             read_value;

    // Store: shift the data into its lane, and build the byte-enable mask for that lane
    wire [4:0] write_shift;
    assign write_shift = {lane, 3'b000};

    wire [DATA_BITS-1:0] write_shifted;
    assign write_shifted = rt << write_shift;

    // 32-bit data => 4 byte lanes (the literals below assume DATA_BITS = 32)
    wire [(DATA_BITS/8)-1:0] lane_mask;
    assign lane_mask = (decoded_mem_size == SIZE_BYTE) ? 4'b0001 :
                       (decoded_mem_size == SIZE_HALF) ? 4'b0011 :
                                                         4'b1111;

    always @(posedge clk) begin
        if (reset) begin
            lsu_state <= IDLE;
            lsu_out <= 0;
            mem_read_valid <= 0;
            mem_read_address <= 0;
            mem_write_valid <= 0;
            mem_write_address <= 0;
            mem_write_data <= 0;
            mem_write_mask <= 0;
        end else if (enable) begin
            // If memory read enable is triggered (LDR instruction)
            if (decoded_mem_read_enable) begin 
                case (lsu_state)
                    IDLE: begin
                        // Only read when core_state = REQUEST
                        if (core_state == 3'b011) begin 
                            lsu_state <= REQUESTING;
                        end
                    end
                    REQUESTING: begin 
                        mem_read_valid <= 1;
                        mem_read_address <= word_address;
                        lsu_state <= WAITING;
                    end
                    WAITING: begin
                        if (mem_read_ready == 1) begin
                            mem_read_valid <= 0;
                            lsu_out <= read_extended;   // lane selected, sign/zero extended
                            lsu_state <= DONE;
                        end
                    end
                    DONE: begin 
                        // Reset when core_state = UPDATE
                        if (core_state == 3'b110) begin 
                            lsu_state <= IDLE;
                        end
                    end
                endcase
            end

            // If memory write enable is triggered (STR instruction)
            if (decoded_mem_write_enable) begin 
                case (lsu_state)
                    IDLE: begin
                        // Only read when core_state = REQUEST
                        if (core_state == 3'b011) begin 
                            lsu_state <= REQUESTING;
                        end
                    end
                    REQUESTING: begin 
                        mem_write_valid <= 1;
                        mem_write_address <= word_address;
                        mem_write_data <= write_shifted;   // data moved into its byte lane
                        mem_write_mask <= lane_mask << lane;
                        lsu_state <= WAITING;
                    end
                    WAITING: begin
                        if (mem_write_ready) begin
                            mem_write_valid <= 0;
                            lsu_state <= DONE;
                        end
                    end
                    DONE: begin 
                        // Reset when core_state = UPDATE
                        if (core_state == 3'b110) begin 
                            lsu_state <= IDLE;
                        end
                    end
                endcase
            end
        end
    end
endmodule
