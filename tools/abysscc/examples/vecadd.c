#include "abyss.h"

/* C[i] = A[i] + B[i], one element per hardware thread.
 * Data layout: A at word 0, B at word 8, C at word 16. */
void kernel(void) {
  int i = __abyss_block_idx() * __abyss_block_dim() + __abyss_thread_idx();
  ABYSS_ST(16, i, ABYSS_LD(0, i) + ABYSS_LD(8, i));
}
