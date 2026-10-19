#include "abyss.h"

/* Exercise the bitwise instructions: AND / OR / XOR and ANDI / ORI / XORI.
 *
 * Inputs (byte addresses, 4 words each):
 *   a at bytes  0..15  (words 0..3)
 *   b at bytes 16..31  (words 4..7)
 *
 * Outputs, 4 words (16 bytes) per group:
 *   bytes  32..47  (words  8..11)  a & b            -> AND
 *   bytes  48..63  (words 12..15)  a | b            -> OR
 *   bytes  64..79  (words 16..19)  a ^ b            -> XOR
 *   bytes  80..95  (words 20..23)  a & 0xFF         -> ANDI (mask off the low byte)
 *   bytes  96..111 (words 24..27)  a | 0x0F         -> ORI  (set the low nibble)
 *   bytes 112..127 (words 28..31)  ~a               -> XORI #-1 (`not`)
 *   bytes 128..143 (words 32..35)  a & -16          -> ANDI #-16 (align down to 16)
 *   bytes 144..159 (words 36..39)  (a >> 8) & 0xFF  -> SRLI + ANDI (extract a bit-field)
 */
ABYSS_MATRIX(abyss_i32_4x1, int, 4, 1);
ABYSS_MATRIX(abyss_i32_8x4, int, 8, 4);

void kernel(void) {
  int i = __abyss_linear_idx();
  abyss_i32_4x1 *a_ptr = (abyss_i32_4x1 *)abyss_mem(0);
  abyss_i32_4x1 *b_ptr = (abyss_i32_4x1 *)abyss_mem(16);
  abyss_i32_8x4 *out = (abyss_i32_8x4 *)abyss_mem(32);

  int a = 0x55;
  a = (i == 0) ? 0x12345678 : a;
  a = (i == 1) ? -1 : a;
  a = (i == 2) ? 0 : a;
  a = (i == 3) ? (int)0x80000000u : a;
  int b = 0x55;
  b = (i == 0) ? (int)0xF0F0F0F0u : b;
  b = (i == 1) ? 0x00FF00FF : b;
  b = (i == 2) ? -1 : b;
  b = (i == 3) ? 0x7FFFFFFF : b;
  (*a_ptr)[i][0] = a;
  (*b_ptr)[i][0] = b;

  a = (*a_ptr)[i][0];
  b = (*b_ptr)[i][0];

  (*out)[0][i] = a & b;
  (*out)[1][i] = a | b;
  (*out)[2][i] = a ^ b;
  (*out)[3][i] = a & 0xFF;
  (*out)[4][i] = a | 0x0F;
  (*out)[5][i] = ~a;
  (*out)[6][i] = a & -16;
  (*out)[7][i] = (a >> 8) & 0xFF;
}
