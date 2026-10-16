`default_nettype none
`timescale 1ns/1ns

// PROGRAM COUNTER
// > Calculates the next PC for each thread to update to (but currently we assume all threads
//   update to the same PC and don't support branch divergence)
// > Currently, each thread in each core has it's own calculation for next PC
// > Control flow is RISC-V style and compares operands directly - there is no flag register:
// >   `Bcc rs1, rs2, offset` -> PC + (offset >> 2) when taken, PC + 1 otherwise
// >   `JAL rd, offset`      -> PC + (offset >> 2) unconditionally, PC + 4 goes to rd
// >   `AUIPC rd, imm20`     -> PC + (imm20 << 12) goes to rd
// > `pc_result` is the value written back to rd by JAL / AUIPC (`decoded_reg_input_mux = 10`)
module pc #(
    parameter DATA_MEM_DATA_BITS = 32,
    parameter PROGRAM_MEM_ADDR_BITS = 32
) (
    input wire clk,
    input wire reset,
    input wire enable, // If current block has less threads then block size, some PCs will be inactive

    // State
    input reg [2:0] core_state,

    // Control Signals
    input reg decoded_branch_enable,
    input reg [2:0] decoded_branch_cond, // funct3: 000 BEQ, 001 BNE, 100 BLT, 101 BGE, 110 BLTU, 111 BGEU
    input reg decoded_jump_enable,       // JAL (unconditional jump + link)
    input reg [PROGRAM_MEM_ADDR_BITS-1:0] decoded_immediate,

    // Operands to compare (rs1 / rs2)
    input reg [DATA_MEM_DATA_BITS-1:0] rs,
    input reg [DATA_MEM_DATA_BITS-1:0] rt,

    // Current & Next PCs
    input reg [PROGRAM_MEM_ADDR_BITS-1:0] current_pc,
    output reg [PROGRAM_MEM_ADDR_BITS-1:0] next_pc,

    // Value written back to rd by JAL (PC + 4) / AUIPC (PC + imm)
    output wire [PROGRAM_MEM_ADDR_BITS-1:0] pc_result
);
    localparam BEQ = 3'b000,
        BNE = 3'b001,
        BLT = 3'b100,
        BGE = 3'b101,
        BLTU = 3'b110,
        BGEU = 3'b111;

    // Signed / unsigned views of the two source registers
    wire signed [DATA_MEM_DATA_BITS-1:0] rs_signed, rt_signed;
    assign rs_signed = rs;
    assign rt_signed = rt;

    wire is_equal = (rs == rt);
    wire is_less_signed = (rs_signed < rt_signed);
    wire is_less_unsigned = (rs < rt);

    reg branch_take;
    always @(*) begin
        case (decoded_branch_cond)
            BEQ: branch_take = is_equal;
            BNE: branch_take = ~is_equal;
            BLT: branch_take = is_less_signed;
            BGE: branch_take = ~is_less_signed;
            BLTU: branch_take = is_less_unsigned;
            BGEU: branch_take = ~is_less_unsigned;
            default: branch_take = 1'b0;
        endcase
    end

    // Immediates arrive fully assembled from the decoder (I/S/B/J sign-extended to 32 bits,
    // U already shifted). Branch/jump offsets are byte offsets while the PC counts
    // instructions, so `>>> 2` and the shift below are pure wiring.
    wire signed [PROGRAM_MEM_ADDR_BITS-1:0] imm_signed;
    assign imm_signed = decoded_immediate;

    wire signed [PROGRAM_MEM_ADDR_BITS-1:0] offset_words;
    assign offset_words = imm_signed >>> 2;

    // Branch or jump taken? JAL always jumps
    wire take_transfer = decoded_jump_enable || (decoded_branch_enable && branch_take);

    wire [PROGRAM_MEM_ADDR_BITS-1:0] next_pc_value;
    assign next_pc_value = take_transfer ? (current_pc + offset_words) : (current_pc + 1);

    // Link / PC-relative value written back to rd:
    //   JAL   -> byte address of the next instruction (PC + 4)
    //   AUIPC -> PC + (imm20 << 12)
    wire [PROGRAM_MEM_ADDR_BITS-1:0] pc_byte;
    assign pc_byte = current_pc << 2; // PC counts instructions, addresses count bytes

    wire [PROGRAM_MEM_ADDR_BITS-1:0] pc_addend;
    assign pc_addend = decoded_jump_enable ? 4 : decoded_immediate; // JAL: PC + 4

    assign pc_result = pc_byte + pc_addend;

    always @(posedge clk) begin
        if (reset) begin
            next_pc <= 0;
        end else if (enable) begin
            // Update PC when core_state = EXECUTE
            if (core_state == 3'b101) begin 
                next_pc <= next_pc_value;
            end   
        end
    end

endmodule
