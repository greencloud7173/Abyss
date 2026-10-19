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
ABYSS_MATRIX(abyss_i32_4x1, int, 4, 1);
ABYSS_MATRIX(abyss_i32_6x4, int, 6, 4);

void kernel(void) {
  int i = __abyss_linear_idx();
  abyss_i32_4x1 *a_ptr = (abyss_i32_4x1 *)abyss_mem(0);
  abyss_i32_4x1 *sh_ptr = (abyss_i32_4x1 *)abyss_mem(16);
  abyss_i32_6x4 *out = (abyss_i32_6x4 *)abyss_mem(32);

  int a = 0x55;
  a = (i == 0) ? 1 : a;
  a = (i == 1) ? -8 : a;
  a = (i == 2) ? 0x7FFFFFFF : a;
  a = (i == 3) ? (int)0x80000000u : a;
  int sh = i + 1;
  (*a_ptr)[i][0] = a;
  (*sh_ptr)[i][0] = sh;

  a = (*a_ptr)[i][0];
  unsigned ua = (unsigned)a;
  sh = (*sh_ptr)[i][0];

  (*out)[0][i] = a << 2;
  (*out)[1][i] = a >> 1;
  (*out)[2][i] = ua >> 1;
  (*out)[3][i] = a << sh;
  (*out)[4][i] = a >> sh;
  (*out)[5][i] = ua >> sh;
}
