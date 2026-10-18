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
  int i = __abyss_block_idx() * __abyss_block_dim() + __abyss_thread_idx();
  int a = ABYSS_LD(0, i);
  int b = ABYSS_LD(16, i);
  unsigned ua = (unsigned)a;
  unsigned ub = (unsigned)b;

  ABYSS_ST(32, i, a < b);
  ABYSS_ST(48, i, ua < ub);
  ABYSS_ST(64, i, a < 5);
  ABYSS_ST(80, i, ua < 5u);
  ABYSS_ST(96, i, a < -1);
  ABYSS_ST(112, i, ua < 4294967295u);
}
