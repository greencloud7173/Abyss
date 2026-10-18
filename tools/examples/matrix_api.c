#include "abyss.h"

/* Typed matrix API demonstration.
 *
 * The matrix dimension and element type are encoded in the C type.  The
 * ABYSS_MAT_* macros check them with _Static_assert, so an invalid add or
 * multiply is a compile-time error rather than a silent memory bug.
 *
 * A at bytes 0..15, B at bytes 16..31, C at bytes 32..47.
 */
ABYSS_MATRIX(my_mat2x2i, int, 2, 2);

void kernel(void) {
  my_mat2x2i *A = (my_mat2x2i *)abyss_mem(0);
  my_mat2x2i *B = (my_mat2x2i *)abyss_mem(16);
  my_mat2x2i *C = (my_mat2x2i *)abyss_mem(32);

  ABYSS_MAT_ADD(C, A, B);
  ABYSS_MAT_MUL(C, A, B);
}
