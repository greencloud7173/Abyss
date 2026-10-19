#include "abyss.h"

/* 2x2 matrix multiply, 4 threads (1 block x 4 threads).
 * Byte addresses: A at bytes 0..15, B at bytes 16..31, C at bytes 32..47.
 * N is passed in a0 by the startup stub. */
ABYSS_MATRIX(abyss_mat2x2i, int, 2, 2);

void kernel(int N) {
  int i = __abyss_linear_idx();
  int row = i / N;
  int col = i - row * N;

  abyss_mat2x2i *A = (abyss_mat2x2i *)abyss_mem(0);
  abyss_mat2x2i *B = (abyss_mat2x2i *)abyss_mem(16);
  abyss_mat2x2i *C = (abyss_mat2x2i *)abyss_mem(32);

  /* Every thread writes the same input matrices, so no thread depends on
   * another thread having completed its stores. */
  for (int r = 0; r < N; r++)
    for (int c = 0; c < N; c++) {
      int v = r * N + c + 1;
      (*A)[r][c] = v;
      (*B)[r][c] = v;
    }

  int acc = 0;
  for (int k = 0; k < N; k++)
    acc += (*A)[row][k] * (*B)[k][col];

  (*C)[row][col] = acc;
}
