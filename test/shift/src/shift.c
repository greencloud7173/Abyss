#include "abyss.h"

/* Exercise SLL/SRL/SRA and SLLI/SRLI/SRAI.
 *
 * Addresses are byte addresses (words 0..3 == bytes 0..15):
 *   a  at words 0..3   (bytes 0..15)
 *   sh at words 4..7   (bytes 16..31)
 *
 * Each output array is 4 words wide:
 *   words  8..11  (bytes  32..47)  a << 2
 *   words 12..15  (bytes  48..63)  a >> 1        (signed -> SRA)
 *   words 16..19  (bytes  64..79)  ua >> 1       (unsigned -> SRL)
 *   words 20..23  (bytes  80..95)  a << sh
 *   words 24..27  (bytes  96..111) a >> sh       (signed -> SRA)
 *   words 28..31  (bytes 112..127) ua >> sh      (unsigned -> SRL)
 */
void kernel(void) {
  int i = __abyss_block_idx() * __abyss_block_dim() + __abyss_thread_idx();
  int a = ABYSS_LD(0, i);
  unsigned ua = (unsigned)a;
  int sh = ABYSS_LD(16, i);

  ABYSS_ST(32, i, a << 2);
  ABYSS_ST(48, i, a >> 1);
  ABYSS_ST(64, i, ua >> 1);
  ABYSS_ST(80, i, a << sh);
  ABYSS_ST(96, i, a >> sh);
  ABYSS_ST(112, i, ua >> sh);
}
