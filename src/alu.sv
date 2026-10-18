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
// > Division comes in four flavours, like RISC-V: DIV / DIVU / REM / REMU (signed or not,
// > quotient or remainder), and division by zero follows the RISC-V rules instead of
// > propagating `x` through the datapath
// > Comparisons (SLT / SLTU, and their immediate forms SLTI / SLTIU) also land here:
// > they write 0 or 1 into rd, so no extra write-back path is needed
module alu #(
    parameter DATA_BITS = 8
) (
    input wire clk,
    input wire reset,
    input wire enable, // If current block has less threads then block size, some ALUs will be inactive

    input reg [2:0] core_state,

    input reg [3:0] decoded_alu_arithmetic_mux,
    input reg decoded_alu_imm_enable, // Use the immediate as the B operand (ADDI / LUI)
    input reg [DATA_BITS-1:0] decoded_immediate,

    input reg [DATA_BITS-1:0] rs,
    input reg [DATA_BITS-1:0] rt,
    output wire [DATA_BITS-1:0] alu_out
);
    localparam ADD = 4'b0000,
        SUB = 4'b0001,
        MUL = 4'b0010,
        DIV = 4'b0011,   // signed quotient
        SLL = 4'b0100,
        SRL = 4'b0101,
        SRA = 4'b0110,
        DIVU = 4'b0111,  // unsigned quotient
        REM = 4'b1000,   // signed remainder
        REMU = 4'b1001,  // unsigned remainder
        SLT = 4'b1010,   // set less than (signed)   -> rd = (rs < rs2/imm) ? 1 : 0
        SLTU = 4'b1011;  // set less than (unsigned) -> rd = (rs < rs2/imm) ? 1 : 0

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

    // Same operand seen as unsigned, for DIVU / REMU
    wire [DATA_BITS-1:0] operand_b_unsigned;
    assign operand_b_unsigned = decoded_alu_imm_enable ? decoded_immediate : rt;

    // Division by zero returns what RISC-V says instead of `x`
    wire divisor_is_zero = (operand_b == {DATA_BITS{1'b0}});

    // Compute the four division results as self-determined values first.
    // Classic Verilog pitfall: `cond ? {N{1'b1}} : (rs_signed / operand_b)` makes the
    // whole conditional expression *unsigned* (one branch is an unsigned literal),
    // which silently turns `div` into `divu`. Keeping them in named wires avoids it.
    wire signed [DATA_BITS-1:0] div_signed;
    wire [DATA_BITS-1:0] div_unsigned;
    wire signed [DATA_BITS-1:0] rem_signed;
    wire [DATA_BITS-1:0] rem_unsigned;
    assign div_signed = rs_signed / operand_b;
    assign div_unsigned = rs / operand_b_unsigned;
    assign rem_signed = rs_signed % operand_b;
    assign rem_unsigned = rs % operand_b_unsigned;

    // Comparisons for SLT / SLTU.  `rs_signed < operand_b` is a signed compare
    // (both operands are declared signed), the other one is unsigned.  For SLTIU
    // the immediate is sign-extended by the decoder and then compared as unsigned,
    // which is exactly the RISC-V rule.
    wire rs_less_signed = rs_signed < operand_b;
    wire rs_less_unsigned = rs < operand_b_unsigned;

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
                        // RISC-V `div`: signed division, truncated toward zero; x/0 = -1
                        alu_out_reg <= divisor_is_zero ? {DATA_BITS{1'b1}} : div_signed;
                    end
                    DIVU: begin 
                        // RISC-V `divu`: unsigned division; x/0 = 2^32-1
                        alu_out_reg <= divisor_is_zero ? {DATA_BITS{1'b1}} : div_unsigned;
                    end
                    REM: begin 
                        // RISC-V `rem`: sign follows the dividend; x%0 = x
                        alu_out_reg <= divisor_is_zero ? rs : rem_signed;
                    end
                    REMU: begin 
                        // RISC-V `remu`: unsigned remainder; x%0 = x
                        alu_out_reg <= divisor_is_zero ? rs : rem_unsigned;
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
                    SLT: begin 
                        // rd = 1 when rs < B (signed), else 0; zero-extended 0/1
                        alu_out_reg <= {{DATA_BITS-1{1'b0}}, rs_less_signed};
                    end
                    SLTU: begin 
                        // rd = 1 when rs < B (unsigned), else 0
                        alu_out_reg <= {{DATA_BITS-1{1'b0}}, rs_less_unsigned};
                    end
                endcase
            end
        end
    end
endmodule
