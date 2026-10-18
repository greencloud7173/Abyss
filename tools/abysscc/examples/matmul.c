#include "abyss.h"

/* 2x2 matrix multiply, one output element per hardware thread.
 * Byte addresses: A at 0, B at 16, C at 32; N is passed in a0. */
void kernel(int N) {
  int i = __abyss_block_idx() * __abyss_block_dim() + __abyss_thread_idx();
  int row = i / N;
  int col = i - row * N;
  int acc = 0;

  for (int k = 0; k < N; k++)
    acc += ABYSS_LD(0, row * N + k) * ABYSS_LD(16, k * N + col);

  ABYSS_ST(32, i, acc);
}
