#ifndef ABYSS_H
#define ABYSS_H

/*
 * Abyss C runtime header for the simplified clang toolchain.
 *
 * The compiler is invoked with -ffixed-x23..x31, so x23/x24/x25/x26 are
 * available to the assembly translator as scratch registers, and x27/x28
 * hold the constants 2 and 4 (used to lower constant shifts), while
 * x29/x30/x31 are the hardware blockIdx/blockDim/threadIdx registers.
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
 * tiny-gpu data memory is *word* addressed: address 1 is the second 32-bit
 * word, not byte 1.  Use integer address arithmetic instead of int*
 * pointer arithmetic (which LLVM would scale by 4).
 */
#define ABYSS_LD(base, idx) (*(volatile int *)((int)(base) + (int)(idx)))
#define ABYSS_ST(base, idx, val) \
  (*(volatile int *)((int)(base) + (int)(idx)) = (int)(val))

#endif
