#ifndef ABYSS_H
#define ABYSS_H

/*
 * Abyss C runtime header for the simplified clang toolchain.
 *
 * The compiler is invoked with -ffixed-x23..x31, so the C compiler never
 * allocates those registers.  The assembly translator uses R24/R25 for
 * slt/slti and R26 for rem; R29/R30/R31 are the hardware
 * blockIdx/blockDim/threadIdx registers.
 */

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

/*
 * Abyss data memory is *byte* addressed (like RISC-V), so plain `int *`
 * pointer arithmetic works: the compiler scales the index by 4 (SLLI/SLL).
 * Byte 0 .. 3 live in word 0, byte 4 .. 7 in word 1, and so on.
 *
 * Use the narrow helpers for char / short accesses: they lower to
 * LB / LH / LBU / LHU / SB / SH, which the LSU masks down to one lane.
 */
#define ABYSS_LD(base, idx) (((volatile int *)(base))[idx])
#define ABYSS_ST(base, idx, val) \
  (((volatile int *)(base))[idx] = (int)(val))

#define ABYSS_LDB(base, idx) (((volatile signed char *)(base))[idx])
#define ABYSS_LDBU(base, idx) (((volatile unsigned char *)(base))[idx])
#define ABYSS_LDH(base, idx) (((volatile short *)(base))[idx])
#define ABYSS_LDHU(base, idx) (((volatile unsigned short *)(base))[idx])
#define ABYSS_STB(base, idx, val) \
  (((volatile signed char *)(base))[idx] = (signed char)(val))
#define ABYSS_STH(base, idx, val) \
  (((volatile short *)(base))[idx] = (short)(val))

#endif
