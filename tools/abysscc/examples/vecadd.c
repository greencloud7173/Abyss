#include "abyss.h"

/* C[i] = A[i] + B[i], one element per hardware thread.
 * Byte addresses: A at 0, B at 32, C at 64. */
void kernel(void) {
  int i = __abyss_linear_idx();
  int *A = (int *)abyss_mem(0);
  int *B = (int *)abyss_mem(32);
  int *C = (int *)abyss_mem(64);
  C[i] = A[i] + B[i];
}
