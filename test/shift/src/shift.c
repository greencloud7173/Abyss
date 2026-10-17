#include "abyss.h"

/* Exercise SLL/SRL/SRA and SLLI/SRLI/SRAI.
 *
 * Data layout:
 *   a  at words 0..3
 *   sh at words 4..7
 *
 * Each output array is 4 words wide:
 *   8..11   a << 2
 *   12..15  a >> 1        (signed -> SRA)
 *   16..19  ua >> 1       (unsigned -> SRL)
 *   20..23  a << sh
 *   24..27  a >> sh       (signed -> SRA)
 *   28..31  ua >> sh      (unsigned -> SRL)
 */
void kernel(void) {
  int i = __abyss_block_idx() * __abyss_block_dim() + __abyss_thread_idx();
  int a = ABYSS_LD(0, i);
  unsigned ua = (unsigned)a;
  int sh = ABYSS_LD(4, i);

  ABYSS_ST(8, i, a << 2);
  ABYSS_ST(12, i, a >> 1);
  ABYSS_ST(16, i, ua >> 1);
  ABYSS_ST(20, i, a << sh);
  ABYSS_ST(24, i, a >> sh);
  ABYSS_ST(28, i, ua >> sh);
}
