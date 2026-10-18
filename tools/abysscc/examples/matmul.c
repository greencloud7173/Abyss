#include "abyss.h"

/* 2x2 matrix multiply, one output element per hardware thread.
 * Byte addresses: A at 0, B at 16, C at 32; N is passed in a0. */
ABYSS_MATRIX(abyss_example_mat2x2i, int, 2, 2);

void kernel(int N) {
  int i = __abyss_linear_idx();
  int row = i / N;
  int col = i - row * N;

  abyss_example_mat2x2i *A = (abyss_example_mat2x2i *)abyss_mem(0);
  abyss_example_mat2x2i *B = (abyss_example_mat2x2i *)abyss_mem(16);
  abyss_example_mat2x2i *C = (abyss_example_mat2x2i *)abyss_mem(32);

  int acc = 0;
  for (int k = 0; k < N; k++)
    acc += A->data[row][k] * B->data[k][col];

  C->data[row][col] = acc;
}
