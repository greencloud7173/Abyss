#include "abyss.h"

/* 2x2 matrix multiply, one output element per hardware thread.
 * Data layout: A at word 0, B at word 4, C at word 8, N is passed in a0. */
void kernel(int N) {
  int i = __abyss_block_idx() * __abyss_block_dim() + __abyss_thread_idx();
  int row = i / N;
  int col = i - row * N;
  int acc = 0;

  for (int k = 0; k < N; k++)
    acc += ABYSS_LD(0, row * N + k) * ABYSS_LD(4, k * N + col);

  ABYSS_ST(8, i, acc);
}
