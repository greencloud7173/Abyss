#include "abyss.h"

/* C[i] = A[i] + B[i], 8 threads (2 blocks x 4 threads).
 * Byte addresses: A at bytes 0..31 (words 0..7), B at bytes 32..63 (words 8..15),
 * C at bytes 64..95 (words 16..23). */
void kernel(void) {
  int i = __abyss_block_idx() * __abyss_block_dim() + __abyss_thread_idx();
  ABYSS_ST(64, i, ABYSS_LD(0, i) + ABYSS_LD(32, i));
}
