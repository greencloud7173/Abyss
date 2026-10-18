#include "abyss.h"

/* Exercise SB/LB/LBU and SH/LH/LHU.
 *
 * Byte addresses:
 *   0..15    source words
 *   16..31   scratch bytes written by SB/SH
 *   64..79   signed byte results
 *   80..95   unsigned byte results
 *   96..111  signed half results
 *   112..127 unsigned half results
 */
void kernel(void) {
  int i = __abyss_block_idx() * __abyss_block_dim() + __abyss_thread_idx();
  int v = ABYSS_LD(0, i);

  ABYSS_STB(16, i * 4 + 0, v);
  ABYSS_STB(16, i * 4 + 1, v >> 8);
  ABYSS_STH(16, i * 2 + 1, v >> 16);

  ABYSS_ST(64, i, ABYSS_LDB(16, i * 4 + 0));
  ABYSS_ST(80, i, ABYSS_LDBU(16, i * 4 + 1));
  ABYSS_ST(96, i, ABYSS_LDH(16, i * 2 + 1));
  ABYSS_ST(112, i, ABYSS_LDHU(16, i * 2 + 1));
}
