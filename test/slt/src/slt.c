#include "abyss.h"

/* Exercise SLT / SLTU / SLTI / SLTIU (set-less-than), the last piece of the
 * RISC-V base integer set that was still missing.
 *
 * Inputs (byte addresses, 4 words each):
 *   a at bytes  0..15  (words 0..3)
 *   b at bytes 16..31  (words 4..7)
 *
 * Outputs, 4 words (16 bytes) per group:
 *   bytes  32..47  (words  8..11)  a  <  b          signed   -> SLT
 *   bytes  48..63  (words 12..15)  ua <  ub         unsigned -> SLTU
 *   bytes  64..79  (words 16..19)  a  <  5          signed   -> SLTI
 *   bytes  80..95  (words 20..23)  ua <  5u         unsigned -> SLTIU
 *   bytes  96..111 (words 24..27)  a  <  -1         signed   -> SLTI (negative immediate)
 *   bytes 112..127 (words 28..31)  ua <  0xFFFFFFFF unsigned -> SLTIU (imm -1, sign-extended)
 *
 * The last group is the interesting one for SLTIU: the immediate is
 * sign-extended to 0xFFFFFFFF and then compared *unsigned*, so `0 < -1` must
 * give 1 (a signed compare would give 0).
 */
ABYSS_MATRIX(abyss_i32_4x1, int, 4, 1);
ABYSS_MATRIX(abyss_i32_6x4, int, 6, 4);

void kernel(void) {
  int i = __abyss_linear_idx();
  abyss_i32_4x1 *a_ptr = (abyss_i32_4x1 *)abyss_mem(0);
  abyss_i32_4x1 *b_ptr = (abyss_i32_4x1 *)abyss_mem(16);
  abyss_i32_6x4 *out = (abyss_i32_6x4 *)abyss_mem(32);

  int a = 0x55;
  a = (i == 0) ? 0 : a;
  a = (i == 1) ? -1 : a;
  a = (i == 2) ? 0x7FFFFFFF : a;
  a = (i == 3) ? (int)0x80000000u : a;
  int b = 0x55;
  b = (i == 0) ? 0 : b;
  b = (i == 1) ? 1 : b;
  b = (i == 2) ? 0x7FFFFFFF : b;
  b = (i == 3) ? -1 : b;
  (*a_ptr)[i][0] = a;
  (*b_ptr)[i][0] = b;

  a = (*a_ptr)[i][0];
  b = (*b_ptr)[i][0];
  unsigned ua = (unsigned)a;
  unsigned ub = (unsigned)b;

  (*out)[0][i] = a < b;
  (*out)[1][i] = ua < ub;
  (*out)[2][i] = a < 5;
  (*out)[3][i] = ua < 5u;
  (*out)[4][i] = a < -1;
  (*out)[5][i] = ua < 4294967295u;
}
