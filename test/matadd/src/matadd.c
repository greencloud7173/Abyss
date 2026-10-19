#include "abyss.h"

/* C[i] = A[i] + B[i], 8 threads (2 blocks x 4 threads).
 * Byte addresses: A at bytes 0..31, B at bytes 32..63, C at bytes 64..95. */
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
