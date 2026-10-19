#include "abyss.h"

/* Exercise DIV / DIVU / REM / REMU, including the RISC-V rules for a zero
 * divisor and for INT_MIN / -1.
 *
 * Inputs (byte addresses, 4 words each):
 *   a at bytes  0..15  (words 0..3)
 *   b at bytes 16..31  (words 4..7)
 *   z at bytes 32..47  (words 8..11), runtime zeros -> division by zero
 *
 * Outputs, 4 words (16 bytes) per group:
 *   bytes  48..63  (words 12..15)  a / b        signed   -> DIV
 *   bytes  64..79  (words 16..19)  a % b        signed   -> REM
 *   bytes  80..95  (words 20..23)  ua / ub      unsigned -> DIVU
 *   bytes  96..111 (words 24..27)  ua % ub      unsigned -> REMU
 *   bytes 112..127 (words 28..31)  a / 0        -> -1
 *   bytes 128..143 (words 32..35)  a % 0        -> a
 *   bytes 144..159 (words 36..39)  ua / 0u      -> 0xFFFFFFFF
 *   bytes 160..175 (words 40..43)  ua % 0u      -> ua
 *
 * Note: dividing by zero / overflowing INT_MIN is UB in C, but the operands
 * come from memory so clang emits the plain divide instructions and the
 * hardware defines the result.  This test pins that ISA behaviour down.
 *
 * The remainder groups divide `az = a + z` (z is 0, so the value is identical)
 * on purpose: when both `a / b` and `a % b` appear with the *same* operands,
 * LLVM's RISC-V backend folds them into `div` + `mul` + `sub` and never emits
 * REM/REMU.  Adding the runtime zero defeats that fold, so the test really
 * exercises the hardware remainder instructions.
 */
ABYSS_MATRIX(abyss_i32_4x1, int, 4, 1);
ABYSS_MATRIX(abyss_i32_4x1_volatile, volatile int, 4, 1);
ABYSS_MATRIX(abyss_i32_8x4, int, 8, 4);

void kernel(void) {
  int i = __abyss_linear_idx();
  abyss_i32_4x1 *a_ptr = (abyss_i32_4x1 *)abyss_mem(0);
  abyss_i32_4x1 *b_ptr = (abyss_i32_4x1 *)abyss_mem(16);
  abyss_i32_4x1_volatile *z_ptr = (abyss_i32_4x1_volatile *)abyss_mem(32);
  abyss_i32_8x4 *out = (abyss_i32_8x4 *)abyss_mem(48);

  int a = 0x55;
  a = (i == 0) ? 1 : a;
  a = (i == 1) ? -7 : a;
  a = (i == 2) ? 0x7FFFFFFF : a;
  a = (i == 3) ? (int)0x80000000u : a;
  int b = 0x55;
  b = (i == 0) ? 0 : b;
  b = (i == 1) ? 2 : b;
  b = (i == 2) ? 3 : b;
  b = (i == 3) ? -1 : b;
  (*a_ptr)[i][0] = a;
  (*b_ptr)[i][0] = b;
  (*z_ptr)[i][0] = 0;

  a = (*a_ptr)[i][0];
  b = (*b_ptr)[i][0];
  int z = (*z_ptr)[i][0];
  int az = a + z;
  unsigned ua = (unsigned)a;
  unsigned ub = (unsigned)b;
  unsigned uz = (unsigned)z;
  unsigned uaz = ua + uz;

  (*out)[0][i] = a / b;
  (*out)[1][i] = az % b;
  (*out)[2][i] = (int)(ua / ub);
  (*out)[3][i] = (int)(uaz % ub);
  (*out)[4][i] = a / z;
  (*out)[5][i] = az % z;
  (*out)[6][i] = (int)(ua / uz);
  (*out)[7][i] = (int)(uaz % uz);
}
