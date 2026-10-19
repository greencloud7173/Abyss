#include "abyss.h"

/* C[i] = A[i] + B[i], one element per hardware thread.
 * Byte addresses: A at 0, B at 32, C at 64. */
ABYSS_MATRIX(abyss_i32_8x1, int, 8, 1);

void kernel(void) {
  int i = __abyss_linear_idx();
  abyss_i32_8x1 *A = (abyss_i32_8x1 *)abyss_mem(0);
  abyss_i32_8x1 *B = (abyss_i32_8x1 *)abyss_mem(32);
  abyss_i32_8x1 *C = (abyss_i32_8x1 *)abyss_mem(64);
  (*C)[i][0] = (*A)[i][0] + (*B)[i][0];
}
