#include "abyss.h"

/* 指令 cache 的测试载体。
 *
 * 这个内核本身没什么意义，它的作用是把"取指"变成瓶颈：
 * 循环体很小、迭代次数很多，因此除了第一次进入循环外，
 * 每一次取指都应该命中指令 cache，不该再访问 program memory。
 *
 * ⚠️ 迭代次数必须是**所有线程统一**的编译期常量：本 GPU 没有分支发散支持，
 * scheduler 取的是 `next_pc[thread_count - 1]` 的决定，因此各线程跳出循环的
 * 时机必须一致，否则先跳出的线程会被最后一条线程"拽"回去继续循环。
 *
 * 输入（字节地址）：
 *   bytes 0..15   (words 0..3)   每个线程的初值 seed
 * 输出：
 *   bytes 16..31  (words 4..7)   acc = seed 再迭代 200 次 acc = acc * 3 + k
 *
 * 故意不用 `acc += k` 这种形式：clang 会把它识别成等差求和、直接把整个
 * 循环优化掉，那样就测不到取指了。`acc * 3 + k` 是串行依赖，既不会被
 * 折叠也不会被向量化。
 */
#define ITERATIONS 200

void kernel(void) {
  int i = __abyss_linear_idx();
  int *seed_ptr = (int *)abyss_mem(0);
  int *out = (int *)abyss_mem(16);

  int acc = seed_ptr[i];

  for (int k = 0; k < ITERATIONS; k++) {
    acc = acc * 3 + k;
  }

  out[i] = acc;
}
