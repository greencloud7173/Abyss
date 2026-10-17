#include "abyss.h"

/* C[i] = A[i] + B[i], 8 threads (2 blocks x 4 threads).
 * Data layout: A at words 0..7, B at words 8..15, C at words 16..23. */
void kernel(void) {
  int i = __abyss_block_idx() * __abyss_block_dim() + __abyss_thread_idx();
  ABYSS_ST(16, i, ABYSS_LD(0, i) + ABYSS_LD(8, i));
}
