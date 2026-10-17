`default_nettype none
`timescale 1ns/1ns

// ARITHMETIC-LOGIC UNIT
// > Executes computations on register values
// > In this minimal implementation, the ALU supports the 4 basic arithmetic operations
// > Each thread in each core has it's own ALU
// > ADD, SUB, MUL, DIV instructions are all executed here
// > `decoded_alu_imm_enable` swaps the B operand from rt to the immediate, which is what
// > makes ADDI (and the `li` / `nop` pseudo-instructions), LUI and the shift-immediates work
// > Shifts (`SLL`/`SRL`/`SRA`) use `operand_b[4:0]` as the amount, exactly like RISC-V:
// > the register form takes `rs2[4:0]`, the immediate form takes `imm[4:0]` (so 64 shifts by 1)
module alu #(
    parameter DATA_BITS = 8
) (
    input wire clk,
    input wire reset,
    input wire enable, // If current block has less threads then block size, some ALUs will be inactive

    input reg [2:0] core_state,

    input reg [2:0] decoded_alu_arithmetic_mux,
    input reg decoded_alu_imm_enable, // Use the immediate as the B operand (ADDI / LUI)
    input reg [DATA_BITS-1:0] decoded_immediate,

    input reg [DATA_BITS-1:0] rs,
    input reg [DATA_BITS-1:0] rt,
    output wire [DATA_BITS-1:0] alu_out
);
    localparam ADD = 3'b000,
        SUB = 3'b001,
        MUL = 3'b010,
        DIV = 3'b011,
        SLL = 3'b100,
        SRL = 3'b101,
        SRA = 3'b110;

    reg [DATA_BITS-1:0] alu_out_reg;
    assign alu_out = alu_out_reg;

    // Signed views of the operands, used by DIV (RISC-V `div` is signed).
    // ADD/SUB/MUL keep using the unsigned operands (identical results for +,-,* modulo 2^32).
    wire signed [DATA_BITS-1:0] rs_signed, rt_signed;
    assign rs_signed = rs;
    assign rt_signed = rt;

    // Immediate: already sign-extended / shifted by the decoder
    wire signed [DATA_BITS-1:0] imm_signed;
    assign imm_signed = decoded_immediate;

    // B operand: rs2/rt normally, the immediate for ADDI / LUI
    wire signed [DATA_BITS-1:0] operand_b;
    assign operand_b = decoded_alu_imm_enable ? imm_signed : rt_signed;

    always @(posedge clk) begin 
        if (reset) begin 
            alu_out_reg <= {DATA_BITS{1'b0}};
        end else if (enable) begin
            // Calculate alu_out when core_state = EXECUTE
            if (core_state == 3'b101) begin 
                // Execute the specified arithmetic instruction
                case (decoded_alu_arithmetic_mux)
                    ADD: begin 
                        alu_out_reg <= rs + operand_b;
                    end
                    SUB: begin 
                        alu_out_reg <= rs - operand_b;
                    end
                    MUL: begin 
                        alu_out_reg <= rs * operand_b;
                    end
                    DIV: begin 
                        // RISC-V `div`: signed division, truncated toward zero
                        alu_out_reg <= rs_signed / operand_b;
                    end
                    SLL: begin 
                        // Logical shift left, amount = low 5 bits of the B operand
                        alu_out_reg <= rs << operand_b[4:0];
                    end
                    SRL: begin 
                        // Logical shift right
                        alu_out_reg <= rs >> operand_b[4:0];
                    end
                    SRA: begin 
                        // Arithmetic shift right (sign-extending)
                        alu_out_reg <= rs_signed >>> operand_b[4:0];
                    end
                endcase
            end
        end
    end
endmodule
