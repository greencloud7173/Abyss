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
// > Bitwise logic (AND / OR / XOR and ANDI / ORI / XORI) shares the same B operand mux,
// > which is why the immediate forms come for free
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
    output wire [DATA_BITS-1:0] alu_out,

    // High while this lane's iterative divider is still working.  The scheduler
    // ORs this across all lanes and holds EXECUTE until it drops (see
    // scheduler.sv), which is what turns a multi-cycle DIV into a stall on
    // core_state instead of a new core state.
    output wire div_busy
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
        SLTU = 4'b1011,  // set less than (unsigned) -> rd = (rs < rs2/imm) ? 1 : 0
        AND = 4'b1100,   // bitwise and
        OR = 4'b1101,    // bitwise or
        XOR = 4'b1110;   // bitwise xor

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

    // The four division results used to be computed right here with a
    // combinational `rs / operand_b` / `rs % operand_b`.  Synthesis unrolls that
    // into a full restoring divider -- roughly a thousand LUTs per instance, and
    // there is one ALU per lane (32 of them on this configuration), so it does
    // not fit in any small FPGA.  Division is therefore iterative now; see the
    // multi-cycle divider below.

    // INT_MIN / -1 is the one signed division whose true quotient (+2^31) does not
    // fit in 32 bits.  Verilog leaves the result implementation-defined, and the
    // simulators really do disagree (Icarus wraps to 0x80000000, Verilator returns
    // 0), so pin it down to the RISC-V answer: quotient = INT_MIN, remainder = 0.
    wire dividend_is_min = (rs == {1'b1, {DATA_BITS-1{1'b0}}});
    wire divisor_is_minus1 = (operand_b == {DATA_BITS{1'b1}});
    wire div_overflow = dividend_is_min && divisor_is_minus1;

    // ------------------------------------------------------------------
    // Multi-cycle divider
    // ------------------------------------------------------------------
    // Two quotient bits per clock, DATA_BITS/2 clocks per operation, using the
    // classic shift/subtract (restoring) algorithm:
    //
    //   rem = 0
    //   for i = DATA_BITS-1 downto 0:
    //       rem = (rem << 1) | dividend[i]
    //       if rem >= divisor: rem -= divisor; quotient[i] = 1
    //
    // Signed operands are handled the RISC-V way: divide the magnitudes and fix
    // up the signs afterwards.  Truncating toward zero is exactly what
    // `|a| / |b|` followed by a sign fix-up produces, and the remainder takes the
    // sign of the dividend.
    //
    // x/0 and INT_MIN/-1 never reach the iterator -- they are decoded away in a
    // single cycle by the normal case statement below.
    localparam DV_IDLE = 2'b00, DV_ITER = 2'b01, DV_FIN = 2'b10;
    localparam CNT_BITS = $clog2(DATA_BITS + 1);

    wire dv_is_div = (decoded_alu_arithmetic_mux == DIV) ||
                     (decoded_alu_arithmetic_mux == DIVU);
    wire dv_is_rem = (decoded_alu_arithmetic_mux == REM) ||
                     (decoded_alu_arithmetic_mux == REMU);
    wire dv_signed = (decoded_alu_arithmetic_mux == DIV) ||
                     (decoded_alu_arithmetic_mux == REM);
    wire dv_overflow = dv_signed && div_overflow;
    wire dv_needs_hw = (dv_is_div || dv_is_rem) && !divisor_is_zero && !dv_overflow;

    // Magnitudes.  |INT_MIN| = 2^31 still fits in an unsigned word, so the
    // negation below is well defined even for the most negative dividend.
    wire [DATA_BITS-1:0] dv_dividend_mag = (dv_signed && rs[DATA_BITS-1])
                                           ? (~rs + 1'b1) : rs;
    wire [DATA_BITS-1:0] dv_divisor_mag = (dv_signed && operand_b[DATA_BITS-1])
                                          ? (~operand_b_unsigned + 1'b1)
                                          : operand_b_unsigned;

    // One-cycle pulse at the start of an EXECUTE phase.  Needed because the core
    // now stays in EXECUTE for several cycles per DIV: without it the divider
    // would restart on every one of them.
    reg exec_seen;
    always @(posedge clk) begin
        if (reset) begin
            exec_seen <= 1'b0;
        end else begin
            exec_seen <= (core_state == 3'b101);
        end
    end
    wire exec_start = (core_state == 3'b101) && !exec_seen;

    reg [1:0] dv_state;
    reg [CNT_BITS-1:0] dv_count;
    reg [DATA_BITS-1:0] dv_divisor_reg;
    reg [DATA_BITS-1:0] dv_shift_reg;     // dividend, consumed MSB first
    reg [DATA_BITS-1:0] dv_rem_reg;       // always < divisor, so DATA_BITS is enough
    reg [DATA_BITS-1:0] dv_quot_reg;
    reg dv_quot_neg, dv_rem_neg;
    reg [DATA_BITS-1:0] dv_result;
    reg dv_done;                          // one-cycle pulse: dv_result is valid

    wire dv_start = exec_start && enable && (dv_state == DV_IDLE) && dv_needs_hw;
    assign div_busy = (dv_state != DV_IDLE) || dv_start;

    // Two restoring steps per clock, so a 32-bit division costs 16 clocks
    // instead of 32.  Two chained 33-bit subtractors stay well inside a
    // 100 MHz budget on 7-series parts; four would not.
    // (DATA_BITS is expected to be even, which it is for every instantiation.)
    wire [DATA_BITS:0] dv_divisor_ext = {1'b0, dv_divisor_reg};

    wire [DATA_BITS:0] dv_rem_step1 = {dv_rem_reg, dv_shift_reg[DATA_BITS-1]};
    wire dv_ge1 = (dv_rem_step1 >= dv_divisor_ext);
    wire [DATA_BITS:0] dv_rem_part1 = dv_ge1 ? (dv_rem_step1 - dv_divisor_ext)
                                             : dv_rem_step1;

    wire [DATA_BITS:0] dv_rem_step2 = {dv_rem_part1[DATA_BITS-1:0],
                                       dv_shift_reg[DATA_BITS-2]};
    wire dv_ge2 = (dv_rem_step2 >= dv_divisor_ext);
    wire [DATA_BITS:0] dv_rem_part2 = dv_ge2 ? (dv_rem_step2 - dv_divisor_ext)
                                             : dv_rem_step2;

    always @(posedge clk) begin
        if (reset) begin
            dv_state <= DV_IDLE;
            dv_count <= 0;
            dv_divisor_reg <= 0;
            dv_shift_reg <= 0;
            dv_rem_reg <= 0;
            dv_quot_reg <= 0;
            dv_quot_neg <= 1'b0;
            dv_rem_neg <= 1'b0;
            dv_result <= 0;
            dv_done <= 1'b0;
        end else if (enable) begin
            dv_done <= 1'b0;
            case (dv_state)
                DV_IDLE: begin
                    if (dv_start) begin
                        dv_divisor_reg <= dv_divisor_mag;
                        dv_shift_reg <= dv_dividend_mag;
                        dv_quot_neg <= dv_signed &&
                                       (rs[DATA_BITS-1] != operand_b[DATA_BITS-1]);
                        dv_rem_neg <= dv_signed && rs[DATA_BITS-1];
                        dv_rem_reg <= 0;
                        dv_quot_reg <= 0;
                        dv_count <= DATA_BITS;
                        dv_state <= DV_ITER;
                    end
                end
                DV_ITER: begin
                    dv_rem_reg <= dv_rem_part2[DATA_BITS-1:0];
                    dv_quot_reg <= {dv_quot_reg[DATA_BITS-3:0], dv_ge1, dv_ge2};
                    dv_shift_reg <= {dv_shift_reg[DATA_BITS-3:0], 2'b00};
                    dv_count <= dv_count - 2'd2;
                    if (dv_count == 2) begin
                        dv_state <= DV_FIN;
                    end
                end
                default: begin  // DV_FIN
                    dv_result <= dv_is_rem
                        ? (dv_rem_neg ? (~dv_rem_reg + 1'b1) : dv_rem_reg)
                        : (dv_quot_neg ? (~dv_quot_reg + 1'b1) : dv_quot_reg);
                    dv_done <= 1'b1;
                    dv_state <= DV_IDLE;
                end
            endcase
        end
    end

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
            // A completed division writes back through here.  It can never
            // collide with the case below: dv_done only pulses in DV_FIN, which
            // is several cycles into EXECUTE, while exec_start only pulses on the
            // first one.
            if (dv_done) begin
                alu_out_reg <= dv_result;
            end

            // Calculate alu_out on the first cycle of EXECUTE.  Multi-cycle
            // divisions are excluded -- the divider above owns them.
            if (exec_start && !dv_needs_hw) begin 
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
                        // Only the single-cycle special cases land here (every
                        // other division is done by the iterative divider):
                        // x/0 = -1, INT_MIN/-1 = INT_MIN
                        alu_out_reg <= divisor_is_zero ? {DATA_BITS{1'b1}} : rs;
                    end
                    DIVU: begin 
                        // Only x/0 lands here: 2^32-1
                        alu_out_reg <= {DATA_BITS{1'b1}};
                    end
                    REM: begin 
                        // Only the single-cycle special cases land here:
                        // x%0 = x, INT_MIN%-1 = 0
                        alu_out_reg <= divisor_is_zero ? rs : {DATA_BITS{1'b0}};
                    end
                    REMU: begin 
                        // Only x%0 lands here: x%0 = x
                        alu_out_reg <= rs;
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
                    AND: begin 
                        // Bitwise AND / ANDI (immediate is sign-extended by the decoder)
                        alu_out_reg <= rs & operand_b;
                    end
                    OR: begin 
                        // Bitwise OR / ORI
                        alu_out_reg <= rs | operand_b;
                    end
                    XOR: begin 
                        // Bitwise XOR / XORI (`XORI rd, rs1, #-1` is the `not` pseudo-instruction)
                        alu_out_reg <= rs ^ operand_b;
                    end
                endcase
            end
        end
    end
endmodule
