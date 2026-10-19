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

  int src[4] = {(int)0x80017F80u,
                (int)(0x80017F80u + 0x10101u),
                (int)(0x80017F80u + 0x20202u),
                (int)(0x80017F80u + 0x30303u)};

  int *S = (int *)abyss_mem(0);
  signed char *bytes = (signed char *)abyss_mem(16);
  unsigned char *ubytes = (unsigned char *)abyss_mem(16);
  short *halves = (short *)abyss_mem(16);
  unsigned short *uhalves = (unsigned short *)abyss_mem(16);
  int *out = (int *)abyss_mem(64);

  S[i] = src[i];
  int v = S[i];

  bytes[i * 4 + 0] = (signed char)v;
  bytes[i * 4 + 1] = (signed char)(v >> 8);
  halves[i * 2 + 1] = (short)(v >> 16);

  out[0 * 4 + i] = bytes[i * 4 + 0];
  out[1 * 4 + i] = ubytes[i * 4 + 1];
  out[2 * 4 + i] = halves[i * 2 + 1];
  out[3 * 4 + i] = uhalves[i * 2 + 1];
}
