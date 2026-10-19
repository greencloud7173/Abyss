#include "abyss.h"

/* 2x2 matrix multiply, one output element per hardware thread.
 * Byte addresses: A at 0, B at 16, C at 32; N is passed in a0. */
void kernel(int N) {
  int i = __abyss_linear_idx();
  int row = i / N;
  int col = i - row * N;

  int a[2][2] = {{1, 2}, {3, 4}};
  int b[2][2] = {{1, 2}, {3, 4}};

  int *A = (int *)abyss_mem(0);
  int *B = (int *)abyss_mem(16);
  int *C = (int *)abyss_mem(32);

  for (int r = 0; r < N; r++)
    for (int c = 0; c < N; c++) {
      A[r * N + c] = a[r][c];
      B[r * N + c] = b[r][c];
    }

  int acc = 0;
  for (int k = 0; k < N; k++)
    acc += A[row * N + k] * B[k * N + col];

  C[row * N + col] = acc;
}
