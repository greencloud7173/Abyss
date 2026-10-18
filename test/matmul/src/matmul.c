#include "abyss.h"

/* 2x2 matrix multiply, 4 threads (1 block x 4 threads).
 * Byte addresses: A at bytes 0..15 (words 0..3), B at bytes 16..31 (words 4..7),
 * C at bytes 32..47 (words 8..11).
 * N is passed in a0 by the startup stub. */
void kernel(int N) {
  int i = __abyss_block_idx() * __abyss_block_dim() + __abyss_thread_idx();
  int row = i / N;
  int col = i - row * N;
  int acc = 0;

  for (int k = 0; k < N; k++)
    acc += ABYSS_LD(0, row * N + k) * ABYSS_LD(16, k * N + col);

  ABYSS_ST(32, i, acc);
}
