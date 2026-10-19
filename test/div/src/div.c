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
  int i = __abyss_linear_idx();

  int a[4] = {1, -7, 0x7FFFFFFF, (int)0x80000000u};
  int b[4] = {0, 2, 3, -1};

  int *A = (int *)abyss_mem(0);
  int *B = (int *)abyss_mem(16);
  volatile int *Z = (volatile int *)abyss_mem(32);
  int *out = (int *)abyss_mem(48);

  A[i] = a[i];
  B[i] = b[i];
  Z[i] = 0;

  int av = A[i];
  int bv = B[i];
  int zv = Z[i];
  int az = av + zv;
  unsigned ua = (unsigned)av;
  unsigned ub = (unsigned)bv;
  unsigned uz = (unsigned)zv;
  unsigned uaz = ua + uz;

  out[0 * 4 + i] = av / bv;
  out[1 * 4 + i] = az % bv;
  out[2 * 4 + i] = (int)(ua / ub);
  out[3 * 4 + i] = (int)(uaz % ub);
  out[4 * 4 + i] = av / zv;
  out[5 * 4 + i] = az % zv;
  out[6 * 4 + i] = (int)(ua / uz);
  out[7 * 4 + i] = (int)(uaz % uz);
}
