#include "abyss.h"

/* C[i] = A[i] + B[i], one element per hardware thread.
 * Byte addresses: A at 0, B at 32, C at 64. */
void kernel(void) {
  int i = __abyss_block_idx() * __abyss_block_dim() + __abyss_thread_idx();
  ABYSS_ST(64, i, ABYSS_LD(0, i) + ABYSS_LD(32, i));
}
