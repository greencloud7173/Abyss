`default_nettype none
`timescale 1ns/1ns

// PROGRAM COUNTER
// > Calculates the next PC for each thread to update to (but currently we assume all threads
//   update to the same PC and don't support branch divergence)
// > Currently, each thread in each core has it's own calculation for next PC
// > Control flow is RISC-V style and compares operands directly - there is no flag register:
// >   `Bcc rs1, rs2, offset` -> PC + (offset >> 2) when taken, PC + 1 otherwise
// >   `JAL rd, offset`      -> PC + (offset >> 2) unconditionally, PC + 4 goes to rd
// >   `JALR rd, imm(rs1)`   -> (rs1 + imm) >> 2 unconditionally, PC + 4 goes to rd
// >   `AUIPC rd, imm20`     -> PC + (imm20 << 12) goes to rd
// > `pc_result` is the value written back to rd by JAL / JALR / AUIPC (`decoded_reg_input_mux = 10`)
// > Only two adders per thread: one for the next PC, one shared by AUIPC (PC_byte + imm)
// > and JALR (rs1 + imm). The link value is `(PC + 1) << 2`, i.e. pure wiring.
module pc #(
    parameter DATA_MEM_DATA_BITS = 32,
    parameter PROGRAM_MEM_ADDR_BITS = 32
) (
    input wire clk,
    input wire reset,
    input wire enable, // If current block has less threads then block size, some PCs will be inactive
    // State
    input wire [2:0] core_state,
    // Control Signals
    input wire decoded_branch_enable,
    input wire [2:0] decoded_branch_cond, // funct3: 000 BEQ, 001 BNE, 100 BLT, 101 BGE, 110 BLTU, 111 BGEU
    input wire decoded_jump_enable, // JAL (unconditional PC-relative jump + link)
    input wire decoded_jalr_enable, // JALR (unconditional register-target jump + link)
    input wire [PROGRAM_MEM_ADDR_BITS - 1:0] decoded_immediate,
    // Operands to compare (rs1 / rs2)
    input wire [DATA_MEM_DATA_BITS - 1:0] rs,
    input wire [DATA_MEM_DATA_BITS - 1:0] rt,
    // Current & Next PCs
    input wire [PROGRAM_MEM_ADDR_BITS - 1:0] current_pc,
    output reg [PROGRAM_MEM_ADDR_BITS - 1:0] next_pc,
    // Value written back to rd by JAL (PC + 4) / AUIPC (PC + imm)
    output wire [PROGRAM_MEM_ADDR_BITS - 1:0] pc_result
);
    localparam BEQ = 3'b000;
    localparam BNE = 3'b001;
    localparam BLT = 3'b100;
    localparam BGE = 3'b101;
    localparam BLTU = 3'b110;
    localparam BGEU = 3'b111;
    // Signed / unsigned views of the two source registers
    wire signed [DATA_MEM_DATA_BITS - 1:0] rs_signed;
    wire signed [DATA_MEM_DATA_BITS - 1:0] rt_signed;
    assign rs_signed = rs;
    assign rt_signed = rt;
    wire is_equal = rs == rt;
    wire is_less_signed = rs_signed < rt_signed;
    wire is_less_unsigned = rs < rt;
    reg branch_take;
    always @(*)
        case (decoded_branch_cond)
            BEQ: branch_take = is_equal;
            BNE: branch_take = ~is_equal;
            BLT: branch_take = is_less_signed;
            BGE: branch_take = ~is_less_signed;
            BLTU: branch_take = is_less_unsigned;
            BGEU: branch_take = ~is_less_unsigned;
            default: branch_take = 1'b0;
        endcase
    // Immediates arrive fully assembled from the decoder (I/S/B/J sign-extended to 32 bits,
    // U already shifted). Branch/jump offsets are byte offsets while the PC counts
    // instructions, so `>>> 2` and the shift below are pure wiring.
    wire signed [PROGRAM_MEM_ADDR_BITS - 1:0] imm_signed;
    assign imm_signed = decoded_immediate;
    wire signed [PROGRAM_MEM_ADDR_BITS - 1:0] offset_words;
    assign offset_words = imm_signed >>> 2;
    // Branch or jump taken? JAL / JALR always jump
    wire take_transfer = (decoded_jump_enable || decoded_jalr_enable) || (decoded_branch_enable && branch_take);
    // Shared adder: AUIPC needs `PC_byte + imm`, JALR needs `rs1 + imm`. Both are
    // "something + the immediate", so one 32-bit adder per thread covers both.
    wire [PROGRAM_MEM_ADDR_BITS - 1:0] pc_byte;
    assign pc_byte = current_pc << 2; // PC counts instructions, addresses count bytes
    wire [PROGRAM_MEM_ADDR_BITS - 1:0] base_or_reg;
    assign base_or_reg = (decoded_jalr_enable ? rs : pc_byte);
    wire [PROGRAM_MEM_ADDR_BITS - 1:0] base_plus_imm;
    assign base_plus_imm = base_or_reg + decoded_immediate;
    // JALR target: byte address -> instruction index. The shift also drops imm[1:0],
    // i.e. RISC-V's `& ~1` plus the word alignment this machine needs.
    wire [PROGRAM_MEM_ADDR_BITS - 1:0] jalr_target;
    assign jalr_target = base_plus_imm >>> 2;
    // Byte address of the next instruction - no adder needed
    wire [PROGRAM_MEM_ADDR_BITS - 1:0] link_value;
    assign link_value = (current_pc + 1) << 2;
    // PC-relative target (branch / JAL)
    wire [PROGRAM_MEM_ADDR_BITS - 1:0] pc_relative_target;
    assign pc_relative_target = current_pc + offset_words;
    wire [PROGRAM_MEM_ADDR_BITS - 1:0] transfer_target;
    assign transfer_target = (decoded_jalr_enable ? jalr_target : pc_relative_target);
    wire [PROGRAM_MEM_ADDR_BITS - 1:0] next_pc_value;
    assign next_pc_value = (take_transfer ? transfer_target : current_pc + 1);
    // Value written back to rd:
    //   JAL / JALR -> byte address of the next instruction (PC + 4)
    //   AUIPC       -> PC + (imm20 << 12)
    assign pc_result = (decoded_jump_enable || decoded_jalr_enable ? link_value : base_plus_imm);
    always @(posedge clk)
        if (reset)
            next_pc <= 0;
        else if (enable) begin
            // Update PC when core_state = EXECUTE
            if (core_state == 3'b101)
                next_pc <= next_pc_value;
        end
endmodule
