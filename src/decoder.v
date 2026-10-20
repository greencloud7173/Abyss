`default_nettype none
`timescale 1ns/1ns

// INSTRUCTION DECODER
// > Decodes an instruction into the control signals necessary to execute it
// > Each core has it's own decoder
// > 32-bit instruction layout, RISC-V style (see isa/isa.md):
// >   R-type: funct7[31:25] | rs2[24:20] | rs1[19:15] | funct3[14:12] | rd[11:7] | opcode[6:0]
// >   I-type: imm[11:0][31:20]           | rs1[19:15] | funct3[14:12] | rd[11:7] | opcode[6:0]
// >   S-type: imm[11:5][31:25]| rs2[24:20] | rs1[19:15] | funct3[14:12] | imm[4:0][11:7] | opcode[6:0]
// >   B-type: imm[12|10:5][31:25] | rs2[24:20] | rs1[19:15] | funct3[14:12] | imm[4:1|11][11:7] | opcode[6:0]
// >   U-type: imm[31:12]               | rd[11:7] | opcode[6:0]  (LUI / AUIPC)
// >   J-type: imm[20|10:1|11|19:12]   | rd[11:7] | opcode[6:0]  (JAL)
// > `rs`/`rt` in this module are RISC-V's rs1/rs2
// > Immediates are normalized to a full 32-bit value here (I/S/B/J sign-extended, U shifted),
// > so the ALU, LSU and PC unit consume `decoded_immediate` as-is with no sign logic of their own
// > Every field is a fixed slice of the instruction, so decoding stays a flat
// > opcode case (+ funct3/funct7 cases for the R-type group) and no extra muxes are needed
module decoder (
    input wire clk,
    input wire reset,
    input wire [2:0] core_state,
    input wire [31:0] instruction,
    // Instruction Signals
    output reg [4:0] decoded_rd_address,
    output reg [4:0] decoded_rs_address,
    output reg [4:0] decoded_rt_address,
    output reg [31:0] decoded_immediate,
    // Control Signals
    output reg decoded_reg_write_enable, // Enable writing to a register
    output reg decoded_mem_read_enable, // Enable reading from memory
    output reg decoded_mem_write_enable, // Enable writing to memory
    output reg [1:0] decoded_mem_size, // Access width: 00 byte, 01 half, 10 word
    output reg decoded_mem_unsigned, // Zero-extend narrow loads (LBU / LHU)
    output reg [1:0] decoded_reg_input_mux, // Select input to register
    output reg [3:0] decoded_alu_arithmetic_mux, // Select arithmetic operation
    output reg decoded_alu_imm_enable, // Use the immediate as the ALU B operand (ADDI / LUI)
    output reg decoded_branch_enable, // Branch (B-type) instruction
    output reg [2:0] decoded_branch_cond, // Branch condition (= funct3)
    output reg decoded_jump_enable, // Jump with link (J-type JAL)
    output reg decoded_jalr_enable, // Jump with link, register target (I-type JALR)
    // Return (finished executing thread)
    output reg decoded_ret
);
    // Opcodes (instruction[6:0]); like RISC-V's 32-bit instructions, the low two bits are `11`
    localparam OP = 7'b0110011; // RISC-V OP:     ADD / SUB / MUL / DIV / SLT / SLTU
    localparam OP_IMM = 7'b0010011; // RISC-V OP-IMM: ADDI (`li rd, imm` when rs1 = x0)
    localparam LOAD = 7'b0000011; // RISC-V LOAD:   LDR (= `lw rd, imm(rs1)`)
    localparam STORE = 7'b0100011; // RISC-V STORE:  STR (= `sw rs2, imm(rs1)`)
    localparam BRANCH = 7'b1100011; // RISC-V BRANCH: BEQ / BNE / BLT / BGE / BLTU / BGEU
    localparam JAL = 7'b1101111; // RISC-V JAL:    jump and link (PC relative)
    localparam JALR = 7'b1100111; // RISC-V JALR:   jump and link (register + immediate)
    localparam LUI = 7'b0110111; // RISC-V LUI:    load upper immediate (imm[31:12])
    localparam AUIPC = 7'b0010111; // RISC-V AUIPC:  add upper immediate to PC
    localparam CUSTOM2 = 7'b1011011; // custom-2:      RET (thread finished executing)
    // funct3 fields
    localparam F3_ADD_SUB_MUL = 3'b000; // OP: add / sub / mul; OP-IMM: addi
    localparam F3_SLL = 3'b001; // OP: sll;   OP-IMM: slli
    localparam F3_SLT = 3'b010; // OP: slt;   OP-IMM: slti  (also LOAD lw / STORE sw)
    localparam F3_SLTU = 3'b011; // OP: sltu;  OP-IMM: sltiu
    localparam F3_XOR = 3'b100; // OP: xor / div;   OP-IMM: xori   (funct7 区分)
    localparam F3_SRL_SRA = 3'b101; // OP: srl / sra / divu; OP-IMM: srli / srai
    localparam F3_OR = 3'b110; // OP: or / rem;    OP-IMM: ori    (funct7 区分)
    localparam F3_AND = 3'b111; // OP: and / remu;  OP-IMM: andi   (funct7 区分)
    localparam F3_LW = 3'b010; // LOAD: lw (also the width selector for LB/LH/LBU/LHU)
    localparam F3_SW = 3'b010; // STORE: sw (also the width selector for SB/SH)
    // Access widths (memory)
    localparam MEM_BYTE = 2'b00;
    localparam MEM_HALF = 2'b01;
    localparam MEM_WORD = 2'b10;
    // Branch conditions (BRANCH funct3, same values as RISC-V)
    localparam BEQ = 3'b000;
    localparam BNE = 3'b001;
    localparam BLT = 3'b100;
    localparam BGE = 3'b101;
    localparam BLTU = 3'b110;
    localparam BGEU = 3'b111;
    // funct7 fields
    localparam F7_ADD = 7'b0000000;
    localparam F7_SUB = 7'b0100000;
    localparam F7_MULDIV = 7'b0000001;
    // ALU operation encodings (must match src/alu.sv)
    localparam ALU_ADD = 4'b0000;
    localparam ALU_SUB = 4'b0001;
    localparam ALU_MUL = 4'b0010;
    localparam ALU_DIV = 4'b0011;
    localparam ALU_SLL = 4'b0100;
    localparam ALU_SRL = 4'b0101;
    localparam ALU_SRA = 4'b0110;
    localparam ALU_DIVU = 4'b0111;
    localparam ALU_REM = 4'b1000;
    localparam ALU_REMU = 4'b1001;
    localparam ALU_SLT = 4'b1010;
    localparam ALU_SLTU = 4'b1011;
    localparam ALU_AND = 4'b1100;
    localparam ALU_OR = 4'b1101;
    localparam ALU_XOR = 4'b1110;
    always @(posedge clk)
        if (reset) begin
            decoded_rd_address <= 0;
            decoded_rs_address <= 0;
            decoded_rt_address <= 0;
            decoded_immediate <= 0;
            decoded_reg_write_enable <= 0;
            decoded_mem_read_enable <= 0;
            decoded_mem_write_enable <= 0;
            decoded_mem_size <= 0;
            decoded_mem_unsigned <= 0;
            decoded_reg_input_mux <= 0;
            decoded_alu_arithmetic_mux <= 0;
            decoded_alu_imm_enable <= 0;
            decoded_branch_enable <= 0;
            decoded_branch_cond <= 0;
            decoded_jump_enable <= 0;
            decoded_jalr_enable <= 0;
            decoded_ret <= 0;
        end
        // Decode when core_state = DECODE
        else if (core_state == 3'b010) begin
            // Get instruction signals from instruction every time (RISC-V field positions).
            // Default immediate = I-type imm12, sign-extended to a full 32-bit value;
            // S/B/U/J types override the assembly below.
            decoded_rd_address <= instruction[11:7];
            decoded_rs_address <= instruction[19:15];
            decoded_rt_address <= instruction[24:20];
            decoded_immediate <= {{20 {instruction[31]}}, instruction[31:20]};
            // Control signals reset on every decode and set conditionally by instruction
            decoded_reg_write_enable <= 0;
            decoded_mem_read_enable <= 0;
            decoded_mem_write_enable <= 0;
            decoded_mem_size <= 0;
            decoded_mem_unsigned <= 0;
            decoded_reg_input_mux <= 0;
            decoded_alu_arithmetic_mux <= 0;
            decoded_alu_imm_enable <= 0;
            decoded_branch_enable <= 0;
            decoded_branch_cond <= 0;
            decoded_jump_enable <= 0;
            decoded_jalr_enable <= 0;
            decoded_ret <= 0;
            // Set the control signals for each instruction (RISC-V style dispatch)
            case (instruction[6:0])
                OP:
                    // Register-register arithmetic, selected by funct3 (+ funct7)
                    case (instruction[14:12])
                        F3_ADD_SUB_MUL:
                            case (instruction[31:25])
                                F7_ADD: begin
                                    decoded_reg_write_enable <= 1;
                                    decoded_reg_input_mux <= 2'b00;
                                    decoded_alu_arithmetic_mux <= ALU_ADD;
                                end
                                F7_SUB: begin
                                    decoded_reg_write_enable <= 1;
                                    decoded_reg_input_mux <= 2'b00;
                                    decoded_alu_arithmetic_mux <= ALU_SUB;
                                end
                                F7_MULDIV: begin
                                    decoded_reg_write_enable <= 1;
                                    decoded_reg_input_mux <= 2'b00;
                                    decoded_alu_arithmetic_mux <= ALU_MUL;
                                end
                            endcase
                        F3_SLL:
                            // SLL rd, rs1, rs2 (shift amount = rs2[4:0])
                            if (instruction[31:25] == F7_ADD) begin
                                decoded_reg_write_enable <= 1;
                                decoded_reg_input_mux <= 2'b00;
                                decoded_alu_arithmetic_mux <= ALU_SLL;
                            end
                        F3_SLT:
                            // SLT rd, rs1, rs2 (signed compare, rd = 0/1)
                            if (instruction[31:25] == F7_ADD) begin
                                decoded_reg_write_enable <= 1;
                                decoded_reg_input_mux <= 2'b00;
                                decoded_alu_arithmetic_mux <= ALU_SLT;
                            end
                        F3_SLTU:
                            // SLTU rd, rs1, rs2 (unsigned compare, rd = 0/1)
                            if (instruction[31:25] == F7_ADD) begin
                                decoded_reg_write_enable <= 1;
                                decoded_reg_input_mux <= 2'b00;
                                decoded_alu_arithmetic_mux <= ALU_SLTU;
                            end
                        F3_XOR:
                            // XOR (funct7 = 0000000) / DIV (funct7 = 0000001)
                            if (instruction[31:25] == F7_ADD) begin
                                decoded_reg_write_enable <= 1;
                                decoded_reg_input_mux <= 2'b00;
                                decoded_alu_arithmetic_mux <= ALU_XOR;
                            end
                            else if (instruction[31:25] == F7_MULDIV) begin
                                decoded_reg_write_enable <= 1;
                                decoded_reg_input_mux <= 2'b00;
                                decoded_alu_arithmetic_mux <= ALU_DIV;
                            end
                        F3_SRL_SRA:
                            // SRL (funct7 = 0000000) / SRA (funct7 = 0100000) / DIVU (0000001)
                            if (instruction[31:25] == F7_ADD) begin
                                decoded_reg_write_enable <= 1;
                                decoded_reg_input_mux <= 2'b00;
                                decoded_alu_arithmetic_mux <= ALU_SRL;
                            end
                            else if (instruction[31:25] == F7_SUB) begin
                                decoded_reg_write_enable <= 1;
                                decoded_reg_input_mux <= 2'b00;
                                decoded_alu_arithmetic_mux <= ALU_SRA;
                            end
                            else if (instruction[31:25] == F7_MULDIV) begin
                                decoded_reg_write_enable <= 1;
                                decoded_reg_input_mux <= 2'b00;
                                decoded_alu_arithmetic_mux <= ALU_DIVU;
                            end
                        F3_OR:
                            // OR (funct7 = 0000000) / REM (funct7 = 0000001, signed remainder)
                            if (instruction[31:25] == F7_ADD) begin
                                decoded_reg_write_enable <= 1;
                                decoded_reg_input_mux <= 2'b00;
                                decoded_alu_arithmetic_mux <= ALU_OR;
                            end
                            else if (instruction[31:25] == F7_MULDIV) begin
                                decoded_reg_write_enable <= 1;
                                decoded_reg_input_mux <= 2'b00;
                                decoded_alu_arithmetic_mux <= ALU_REM;
                            end
                        F3_AND:
                            // AND (funct7 = 0000000) / REMU (funct7 = 0000001, unsigned remainder)
                            if (instruction[31:25] == F7_ADD) begin
                                decoded_reg_write_enable <= 1;
                                decoded_reg_input_mux <= 2'b00;
                                decoded_alu_arithmetic_mux <= ALU_AND;
                            end
                            else if (instruction[31:25] == F7_MULDIV) begin
                                decoded_reg_write_enable <= 1;
                                decoded_reg_input_mux <= 2'b00;
                                decoded_alu_arithmetic_mux <= ALU_REMU;
                            end
                    endcase
                OP_IMM:
                    // Immediate arithmetic, selected by funct3:
                    //   000 ADDI, 001 SLLI, 010 SLTI, 011 SLTIU,
                    //   100 XORI, 110 ORI, 111 ANDI, 101 SRLI / SRAI (imm[11:5] = funct7-like)
                    // ADDI is `li rd, imm` when rs1 = x0, and `nop` when rd = rs1 = x0, imm = 0
                    case (instruction[14:12])
                        F3_ADD_SUB_MUL: begin
                            decoded_reg_write_enable <= 1;
                            decoded_reg_input_mux <= 2'b00; // write back ALU result
                            decoded_alu_arithmetic_mux <= ALU_ADD;
                            decoded_alu_imm_enable <= 1; // B operand = imm12
                        end
                        F3_SLT: begin
                            // SLTI rd, rs1, #imm12 (signed compare with the immediate)
                            decoded_reg_write_enable <= 1;
                            decoded_reg_input_mux <= 2'b00;
                            decoded_alu_arithmetic_mux <= ALU_SLT;
                            decoded_alu_imm_enable <= 1; // B operand = imm12
                        end
                        F3_SLTU: begin
                            // SLTIU rd, rs1, #imm12 (imm is sign-extended, then compared unsigned)
                            decoded_reg_write_enable <= 1;
                            decoded_reg_input_mux <= 2'b00;
                            decoded_alu_arithmetic_mux <= ALU_SLTU;
                            decoded_alu_imm_enable <= 1;
                        end
                        F3_XOR: begin
                            // XORI rd, rs1, #imm12 (imm sign-extended; XORI with -1 = `not`)
                            decoded_reg_write_enable <= 1;
                            decoded_reg_input_mux <= 2'b00;
                            decoded_alu_arithmetic_mux <= ALU_XOR;
                            decoded_alu_imm_enable <= 1;
                        end
                        F3_OR: begin
                            // ORI rd, rs1, #imm12
                            decoded_reg_write_enable <= 1;
                            decoded_reg_input_mux <= 2'b00;
                            decoded_alu_arithmetic_mux <= ALU_OR;
                            decoded_alu_imm_enable <= 1;
                        end
                        F3_AND: begin
                            // ANDI rd, rs1, #imm12
                            decoded_reg_write_enable <= 1;
                            decoded_reg_input_mux <= 2'b00;
                            decoded_alu_arithmetic_mux <= ALU_AND;
                            decoded_alu_imm_enable <= 1;
                        end
                        F3_SLL:
                            // SLLI rd, rs1, shamt (shamt = imm[4:0], imm[11:5] must be 0)
                            if (instruction[31:25] == F7_ADD) begin
                                decoded_reg_write_enable <= 1;
                                decoded_reg_input_mux <= 2'b00;
                                decoded_alu_arithmetic_mux <= ALU_SLL;
                                decoded_alu_imm_enable <= 1; // B operand = imm12 (low 5 bits = shamt)
                            end
                        F3_SRL_SRA:
                            // SRLI (imm[11:5] = 0000000) / SRAI (imm[11:5] = 0100000)
                            if (instruction[31:25] == F7_ADD) begin
                                decoded_reg_write_enable <= 1;
                                decoded_reg_input_mux <= 2'b00;
                                decoded_alu_arithmetic_mux <= ALU_SRL;
                                decoded_alu_imm_enable <= 1;
                            end
                            else if (instruction[31:25] == F7_SUB) begin
                                decoded_reg_write_enable <= 1;
                                decoded_reg_input_mux <= 2'b00;
                                decoded_alu_arithmetic_mux <= ALU_SRA;
                                decoded_alu_imm_enable <= 1;
                            end
                    endcase
                LOAD: begin
                    // LB / LH / LW / LBU / LHU: funct3 picks the width and the extension
                    // (bit 2 set = unsigned/zero-extend), address is a byte address
                    decoded_reg_write_enable <= 1;
                    decoded_reg_input_mux <= 2'b01;
                    case (instruction[14:12])
                        3'b000: begin
                            decoded_mem_read_enable <= 1;
                            decoded_mem_size <= MEM_BYTE;
                            decoded_mem_unsigned <= 0;
                        end
                        3'b001: begin
                            decoded_mem_read_enable <= 1;
                            decoded_mem_size <= MEM_HALF;
                            decoded_mem_unsigned <= 0;
                        end
                        3'b010: begin
                            decoded_mem_read_enable <= 1;
                            decoded_mem_size <= MEM_WORD;
                            decoded_mem_unsigned <= 0;
                        end
                        3'b100: begin
                            decoded_mem_read_enable <= 1;
                            decoded_mem_size <= MEM_BYTE;
                            decoded_mem_unsigned <= 1;
                        end
                        3'b101: begin
                            decoded_mem_read_enable <= 1;
                            decoded_mem_size <= MEM_HALF;
                            decoded_mem_unsigned <= 1;
                        end
                        default: begin
                            // Unallocated width: nothing happens (NOP)
                            decoded_reg_write_enable <= 0;
                            decoded_reg_input_mux <= 2'b00;
                        end
                    endcase
                end
                STORE: begin
                    // SB / SH / SW: S-type, so the 12-bit offset is split across
                    // instruction[31:25] and instruction[11:7]; the LSU masks the
                    // bytes that are actually written
                    decoded_immediate <= {{20 {instruction[31]}}, instruction[31:25], instruction[11:7]};
                    case (instruction[14:12])
                        3'b000: begin
                            decoded_mem_write_enable <= 1;
                            decoded_mem_size <= MEM_BYTE;
                        end
                        3'b001: begin
                            decoded_mem_write_enable <= 1;
                            decoded_mem_size <= MEM_HALF;
                        end
                        3'b010: begin
                            decoded_mem_write_enable <= 1;
                            decoded_mem_size <= MEM_WORD;
                        end
                        default:
                            ;
                    endcase
                end
                BRANCH: begin
                    // B-type conditional branch: `Bcc rs1, rs2, offset`
                    // imm[12]=inst[31], imm[11]=inst[7], imm[10:5]=inst[30:25],
                    // imm[4:1]=inst[11:8], imm[0]=0 (signed byte offset)
                    decoded_immediate <= {{19 {instruction[31]}}, instruction[31], instruction[7], instruction[30:25], instruction[11:8], 1'b0};
                    if ((((((instruction[14:12] == BEQ) || (instruction[14:12] == BNE)) || (instruction[14:12] == BLT)) || (instruction[14:12] == BGE)) || (instruction[14:12] == BLTU)) || (instruction[14:12] == BGEU)) begin
                        decoded_branch_enable <= 1;
                        decoded_branch_cond <= instruction[14:12];
                    end
                end
                JAL: begin
                    // JAL rd, offset: rd = PC + 4, PC = PC + offset
                    // (J-type: imm[20]=inst[31], imm[10:1]=inst[30:21], imm[11]=inst[20],
                    //  imm[19:12]=inst[19:12], imm[0]=0 - signed byte offset)
                    decoded_immediate <= {{11 {instruction[31]}}, instruction[31], instruction[19:12], instruction[20], instruction[30:21], 1'b0};
                    decoded_reg_write_enable <= 1;
                    decoded_reg_input_mux <= 2'b10; // link value comes from the PC unit
                    decoded_jump_enable <= 1; // unconditional PC-relative jump
                end
                JALR:
                    // JALR rd, imm(rs1): rd = PC + 4, PC = (rs1 + imm)
                    // The target address comes from a register, so it is computed by the
                    // PC unit's adder (not the PC-relative one). funct3 must be 000.
                    if (instruction[14:12] == F3_ADD_SUB_MUL) begin
                        decoded_reg_write_enable <= 1;
                        decoded_reg_input_mux <= 2'b10; // link value comes from the PC unit
                        decoded_jalr_enable <= 1;
                    end
                LUI: begin
                    // LUI rd, imm20: rd = imm20 << 12 (upper 20 bits)
                    // Executed as ADD with the A operand forced to x0 (= 0), so no extra
                    // ALU operation or mux is needed
                    decoded_rs_address <= 5'd0;
                    decoded_immediate <= {instruction[31:12], 12'b000000000000}; // not sign-extended
                    decoded_reg_write_enable <= 1;
                    decoded_reg_input_mux <= 2'b00;
                    decoded_alu_arithmetic_mux <= ALU_ADD; // ADD
                    decoded_alu_imm_enable <= 1;
                end
                AUIPC: begin
                    // AUIPC rd, imm20: rd = PC + (imm20 << 12) (PC-relative address)
                    decoded_immediate <= {instruction[31:12], 12'b000000000000}; // not sign-extended
                    decoded_reg_write_enable <= 1;
                    decoded_reg_input_mux <= 2'b10; // value comes from the PC unit
                end
                CUSTOM2: decoded_ret <= 1;
            // RET
            endcase
        end
endmodule
