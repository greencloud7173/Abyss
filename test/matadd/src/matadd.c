#include "abyss.h"

/* C[i] = A[i] + B[i], 8 threads (2 blocks x 4 threads).
 * Byte addresses: A at bytes 0..31, B at bytes 32..63, C at bytes 64..95. */
ABYSS_MATRIX(abyss_i32_8x1, int, 8, 1);

void kernel(void) {
  int i = __abyss_linear_idx();
  abyss_i32_8x1 *A = (abyss_i32_8x1 *)abyss_mem(0);
  abyss_i32_8x1 *B = (abyss_i32_8x1 *)abyss_mem(32);
  abyss_i32_8x1 *C = (abyss_i32_8x1 *)abyss_mem(64);

  (*A)[i][0] = i;
  (*B)[i][0] = i;
  (*C)[i][0] = (*A)[i][0] + (*B)[i][0];
}
