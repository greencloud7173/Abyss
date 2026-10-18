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
void kernel(void) {
  int i = __abyss_block_idx() * __abyss_block_dim() + __abyss_thread_idx();
  int a = ABYSS_LD(0, i);
  int b = ABYSS_LD(16, i);
  int z = ABYSS_LD(32, i);
  int az = a + z;
  unsigned ua = (unsigned)a;
  unsigned ub = (unsigned)b;
  unsigned uz = (unsigned)z;
  unsigned uaz = ua + uz;

  ABYSS_ST(48, i, a / b);
  ABYSS_ST(64, i, az % b);
  ABYSS_ST(80, i, (int)(ua / ub));
  ABYSS_ST(96, i, (int)(uaz % ub));
  ABYSS_ST(112, i, a / z);
  ABYSS_ST(128, i, az % z);
  ABYSS_ST(144, i, (int)(ua / uz));
  ABYSS_ST(160, i, (int)(uaz % uz));
}
