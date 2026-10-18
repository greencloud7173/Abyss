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
  int i = __abyss_linear_idx();
  int *src = (int *)abyss_mem(0);
  signed char *bytes = (signed char *)abyss_mem(16);
  unsigned char *ubytes = (unsigned char *)abyss_mem(16);
  short *halves = (short *)abyss_mem(16);
  unsigned short *uhalves = (unsigned short *)abyss_mem(16);
  int *out = (int *)abyss_mem(64);

  int v = src[i];

  bytes[i * 4 + 0] = (signed char)v;
  bytes[i * 4 + 1] = (signed char)(v >> 8);
  halves[i * 2 + 1] = (short)(v >> 16);

  out[i] = bytes[i * 4 + 0];
  out[4 + i] = ubytes[i * 4 + 1];
  out[8 + i] = halves[i * 2 + 1];
  out[12 + i] = uhalves[i * 2 + 1];
}
