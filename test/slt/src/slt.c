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

void kernel(void) {
  int i = __abyss_linear_idx();

  int a[4] = {0, -1, 0x7FFFFFFF, (int)0x80000000u};
  int b[4] = {0, 1, 0x7FFFFFFF, -1};

  int *A = (int *)abyss_mem(0);
  int *B = (int *)abyss_mem(16);
  int *out = (int *)abyss_mem(32);

  A[i] = a[i];
  B[i] = b[i];

  int av = A[i];
  int bv = B[i];
  unsigned ua = (unsigned)av;
  unsigned ub = (unsigned)bv;

  out[0 * 4 + i] = av < bv;
  out[1 * 4 + i] = ua < ub;
  out[2 * 4 + i] = av < 5;
  out[3 * 4 + i] = ua < 5u;
  out[4 * 4 + i] = av < -1;
  out[5 * 4 + i] = ua < 4294967295u;
}
