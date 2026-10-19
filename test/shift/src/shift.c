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
  int i = __abyss_linear_idx();

  int a[4] = {1, -8, 0x7FFFFFFF, (int)0x80000000u};
  int sh[4] = {1, 2, 3, 4};

  int *A = (int *)abyss_mem(0);
  int *SH = (int *)abyss_mem(16);
  int *out = (int *)abyss_mem(32);

  A[i] = a[i];
  SH[i] = sh[i];

  int av = A[i];
  unsigned ua = (unsigned)av;
  int shv = SH[i];

  out[0 * 4 + i] = av << 2;
  out[1 * 4 + i] = av >> 1;
  out[2 * 4 + i] = ua >> 1;
  out[3 * 4 + i] = av << shv;
  out[4 * 4 + i] = av >> shv;
  out[5 * 4 + i] = ua >> shv;
}
