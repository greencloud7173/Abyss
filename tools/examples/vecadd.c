#include "abyss.h"

/* C[i] = A[i] + B[i], one element per hardware thread.
 * Byte addresses: A at 0, B at 32, C at 64. */
void kernel(void) {
  int i = __abyss_linear_idx();

  int a[8] = {0, 1, 2, 3, 4, 5, 6, 7};
  int b[8] = {0, 1, 2, 3, 4, 5, 6, 7};

  int *A = (int *)abyss_mem(0);
  int *B = (int *)abyss_mem(32);
  int *C = (int *)abyss_mem(64);

  A[i] = a[i];
  B[i] = b[i];
  C[i] = A[i] + B[i];
}
