#ifndef ABYSS_H
#define ABYSS_H

/*
 * Abyss C support header.
 *
 * There are no ABYSS_LD/ABYSS_ST-style load/store macros.  Abyss data memory
 * is byte-addressed and ordinary C pointers work exactly as expected:
 *
 *     int *A = (int *)abyss_mem(0);
 *     int *B = (int *)abyss_mem(32);
 *     int *C = (int *)abyss_mem(64);
 *     C[i] = A[i] + B[i];
 *
 * Compile with -fno-delete-null-pointer-checks: test data may legitimately
 * start at byte address 0, and plain C would otherwise treat a NULL
 * dereference as undefined behaviour.
 *
 * abyss_mem() only converts a byte address to a pointer; it is not a
 * load/store primitive.  The compiler scales int indices by four.
 */

typedef unsigned int abyss_addr_t;

static inline void *abyss_mem(abyss_addr_t byte_address) {
  return (void *)(unsigned long)byte_address;
}

/* Hardware thread coordinates: R29/R30/R31 are read-only. */
static inline int __abyss_block_idx(void) {
  int v;
  __asm__ volatile("mv %0, x29" : "=r"(v));
  return v;
}

static inline int __abyss_block_dim(void) {
  int v;
  __asm__ volatile("mv %0, x30" : "=r"(v));
  return v;
}

static inline int __abyss_thread_idx(void) {
  int v;
  __asm__ volatile("mv %0, x31" : "=r"(v));
  return v;
}

static inline int __abyss_linear_idx(void) {
  return __abyss_block_idx() * __abyss_block_dim() + __abyss_thread_idx();
}

/*
 * Matrix types are ordinary C structs with a public `data[rows][cols]`
 * member.  The type macro enforces positive, constant dimensions.
 *
 * Example:
 *
 *     ABYSS_MATRIX(abyss_i32_2x2, int, 2, 2);
 *     abyss_i32_2x2 *A = (abyss_i32_2x2 *)abyss_mem(0);
 *
 * Matrix operations are macros so that sizeof/typeof facts are available to
 * _Static_assert.  Wrong element types or incompatible dimensions therefore
 * fail at compile time, before the backend ever sees the code.
 */
#define ABYSS_MATRIX(name, type, rows, cols)                                \
  typedef struct {                                                          \
    type data[(rows)][(cols)];                                              \
  } name;                                                                   \
  _Static_assert((rows) > 0 && (cols) > 0,                                  \
                 "Abyss matrix dimensions must be positive")

#define ABYSS_MAT_ROWS(m) (sizeof((m)->data) / sizeof((m)->data[0]))
#define ABYSS_MAT_COLS(m) \
  (sizeof((m)->data[0]) / sizeof((m)->data[0][0]))

#define ABYSS_MAT_CHECK_ELEMENT(dst, a, b)                                  \
  _Static_assert(                                                           \
      __builtin_types_compatible_p(__typeof__((dst)->data[0][0]),            \
                                   __typeof__((a)->data[0][0])) &&           \
          __builtin_types_compatible_p(__typeof__((a)->data[0][0]),          \
                                       __typeof__((b)->data[0][0])),         \
      "Abyss matrix element types must be compatible")

/* dst = lhs + rhs; all three matrices must have the same shape. */
#define ABYSS_MAT_ADD(dst, lhs, rhs)                                        \
  do {                                                                      \
    _Static_assert(ABYSS_MAT_ROWS(dst) == ABYSS_MAT_ROWS(lhs) &&             \
                       ABYSS_MAT_ROWS(dst) == ABYSS_MAT_ROWS(rhs),           \
                   "Abyss matrix add: row counts differ");                   \
    _Static_assert(ABYSS_MAT_COLS(dst) == ABYSS_MAT_COLS(lhs) &&             \
                       ABYSS_MAT_COLS(dst) == ABYSS_MAT_COLS(rhs),           \
                   "Abyss matrix add: column counts differ");                \
    ABYSS_MAT_CHECK_ELEMENT(dst, lhs, rhs);                                  \
    for (int abyss_i = 0; abyss_i < (int)ABYSS_MAT_ROWS(dst); ++abyss_i)     \
      for (int abyss_j = 0; abyss_j < (int)ABYSS_MAT_COLS(dst); ++abyss_j)   \
        (dst)->data[abyss_i][abyss_j] =                                     \
            (lhs)->data[abyss_i][abyss_j] +                                 \
            (rhs)->data[abyss_i][abyss_j];                                  \
  } while (0)

/* dst = lhs * rhs; dst must be distinct from lhs and rhs. */
#define ABYSS_MAT_MUL(dst, lhs, rhs)                                        \
  do {                                                                      \
    _Static_assert(ABYSS_MAT_COLS(lhs) == ABYSS_MAT_ROWS(rhs),               \
                   "Abyss matrix multiply: inner dimensions differ");        \
    _Static_assert(ABYSS_MAT_ROWS(dst) == ABYSS_MAT_ROWS(lhs),               \
                   "Abyss matrix multiply: destination row count differs");  \
    _Static_assert(ABYSS_MAT_COLS(dst) == ABYSS_MAT_COLS(rhs),               \
                   "Abyss matrix multiply: destination column count differs");\
    ABYSS_MAT_CHECK_ELEMENT(dst, lhs, rhs);                                  \
    for (int abyss_i = 0; abyss_i < (int)ABYSS_MAT_ROWS(dst); ++abyss_i) {   \
      for (int abyss_j = 0; abyss_j < (int)ABYSS_MAT_COLS(dst); ++abyss_j) { \
        __typeof__((dst)->data[0][0]) abyss_acc = 0;                         \
        for (int abyss_k = 0; abyss_k < (int)ABYSS_MAT_COLS(lhs); ++abyss_k) \
          abyss_acc += (lhs)->data[abyss_i][abyss_k] *                       \
                       (rhs)->data[abyss_k][abyss_j];                        \
        (dst)->data[abyss_i][abyss_j] = abyss_acc;                           \
      }                                                                      \
    }                                                                        \
  } while (0)

#define ABYSS_MAT_SCALE(dst, src, scalar)                                    \
  do {                                                                      \
    _Static_assert(ABYSS_MAT_ROWS(dst) == ABYSS_MAT_ROWS(src) &&             \
                       ABYSS_MAT_COLS(dst) == ABYSS_MAT_COLS(src),            \
                   "Abyss matrix scale: dimensions differ");                 \
    ABYSS_MAT_CHECK_ELEMENT(dst, src, src);                                  \
    for (int abyss_i = 0; abyss_i < (int)ABYSS_MAT_ROWS(dst); ++abyss_i)     \
      for (int abyss_j = 0; abyss_j < (int)ABYSS_MAT_COLS(dst); ++abyss_j)   \
        (dst)->data[abyss_i][abyss_j] =                                     \
            (src)->data[abyss_i][abyss_j] * (scalar);                        \
  } while (0)

/* A couple of commonly used types; users can define their own with ABYSS_MATRIX. */
ABYSS_MATRIX(abyss_i32_2x2, int, 2, 2);
ABYSS_MATRIX(abyss_i32_4x4, int, 4, 4);

#endif
