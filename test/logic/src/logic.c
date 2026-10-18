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
  int i = __abyss_block_idx() * __abyss_block_dim() + __abyss_thread_idx();
  int a = ABYSS_LD(0, i);
  int b = ABYSS_LD(16, i);

  ABYSS_ST(32, i, a & b);
  ABYSS_ST(48, i, a | b);
  ABYSS_ST(64, i, a ^ b);
  ABYSS_ST(80, i, a & 0xFF);
  ABYSS_ST(96, i, a | 0x0F);
  ABYSS_ST(112, i, ~a);
  ABYSS_ST(128, i, a & -16);
  ABYSS_ST(144, i, (a >> 8) & 0xFF);
}
