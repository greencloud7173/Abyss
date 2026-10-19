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
ABYSS_MATRIX(abyss_i32_4x1, int, 4, 1);
ABYSS_MATRIX(abyss_i8_4x4, signed char, 4, 4);
ABYSS_MATRIX(abyss_u8_4x4, unsigned char, 4, 4);
ABYSS_MATRIX(abyss_i16_4x2, short, 4, 2);
ABYSS_MATRIX(abyss_u16_4x2, unsigned short, 4, 2);
ABYSS_MATRIX(abyss_i32_4x4, int, 4, 4);

void kernel(void) {
  int i = __abyss_linear_idx();
  abyss_i32_4x1 *src = (abyss_i32_4x1 *)abyss_mem(0);
  abyss_i8_4x4 *bytes = (abyss_i8_4x4 *)abyss_mem(16);
  abyss_u8_4x4 *ubytes = (abyss_u8_4x4 *)abyss_mem(16);
  abyss_i16_4x2 *halves = (abyss_i16_4x2 *)abyss_mem(16);
  abyss_u16_4x2 *uhalves = (abyss_u16_4x2 *)abyss_mem(16);
  abyss_i32_4x4 *out = (abyss_i32_4x4 *)abyss_mem(64);

  unsigned seed = 0x80017F80u + (unsigned)i * 0x10101u;
  (*src)[i][0] = (int)seed;
  int v = (*src)[i][0];

  (*bytes)[i][0] = (signed char)v;
  (*bytes)[i][1] = (signed char)(v >> 8);
  (*halves)[i][1] = (short)(v >> 16);

  (*out)[0][i] = (*bytes)[i][0];
  (*out)[1][i] = (*ubytes)[i][1];
  (*out)[2][i] = (*halves)[i][1];
  (*out)[3][i] = (*uhalves)[i][1];
}
