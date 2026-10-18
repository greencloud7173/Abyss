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
  int *a_ptr = (int *)abyss_mem(0);
  int *b_ptr = (int *)abyss_mem(16);
  int *out = (int *)abyss_mem(32);

  int a = a_ptr[i];
  int b = b_ptr[i];

  out[i] = a & b;
  out[4 + i] = a | b;
  out[8 + i] = a ^ b;
  out[12 + i] = a & 0xFF;
  out[16 + i] = a | 0x0F;
  out[20 + i] = ~a;
  out[24 + i] = a & -16;
  out[28 + i] = (a >> 8) & 0xFF;
}
