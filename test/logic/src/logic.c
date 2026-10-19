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

void kernel(void) {
  int i = __abyss_linear_idx();

  int a[4] = {0x12345678, -1, 0, (int)0x80000000u};
  int b[4] = {(int)0xF0F0F0F0u, 0x00FF00FF, -1, 0x7FFFFFFF};

  int *A = (int *)abyss_mem(0);
  int *B = (int *)abyss_mem(16);
  int *out = (int *)abyss_mem(32);

  A[i] = a[i];
  B[i] = b[i];

  int av = A[i];
  int bv = B[i];

  out[0 * 4 + i] = av & bv;
  out[1 * 4 + i] = av | bv;
  out[2 * 4 + i] = av ^ bv;
  out[3 * 4 + i] = av & 0xFF;
  out[4 * 4 + i] = av | 0x0F;
  out[5 * 4 + i] = ~av;
  out[6 * 4 + i] = av & -16;
  out[7 * 4 + i] = (av >> 8) & 0xFF;
}
