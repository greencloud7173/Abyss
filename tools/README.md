# Abyss C 工具链与测试

当前测试不再使用 `abysscc` 或 `riscv2abyss.py`。每个 `test/<case>/` 目录都有自己的
`Makefile`，直接使用本仓库构建出的原生 Abyss Clang：

```
test/<case>/src/<case>.c
  │  clang --target=abyss -O2 -fno-delete-null-pointer-checks \
  │       -fno-vectorize -fno-slp-vectorize -c
  ▼
build/<case>.o
  │  ld.lld --image-base=0 -Ttext=0 -e _start  +  start.o
  ▼
build/<case>.elf
  │  llvm-objcopy -O binary --only-section=.text
  ▼
build/<case>.bin
  │  cocotb + iverilog
  ▼
RTL 测试
```

`start.s` 由 `llvm-mc -arch=abyss` 单独汇编，然后与内核目标文件链接。

## 构建与运行

```bash
cd /home/greencloud7173/tiny-gpu

make test matadd
make test matmul
make test shift
make test mem
make test div
make test slt
make test logic
make test raster16x16
make test raster32x32
make test raster64x64
make test raster128x128
```

等价写法：

```bash
make test CASE=matadd
make test_matadd
make -C test/matadd
```

每个测试目录自行负责：

- `build/<case>.o`：`clang --target=abyss` 编译 C
- `build/start.o`：`llvm-mc` 汇编启动 stub
- `build/<case>.elf`：`ld.lld` 链接
- `build/<case>.bin`：提取 `.text`
- 调用根目录的 `make sim` 构建共享 RTL 仿真器，再运行 cocotb
- DRAM 上电全为 0；C 内核负责写入测试输入，Python 只提供参考模型和断言
- 每次构建都会保留 `build/<case>.s`，方便检查生成的汇编

测试产物位于 `test/<case>/build/`，已被 `.gitignore` 忽略。

## 依赖

- `build-abyss-clang/bin/clang`：只包含 Abyss target 的本地 Clang
- `build/bin/llvm-mc`、`build/bin/llvm-objcopy`
- `ld.lld`（LLD 22 可用）
- `iverilog`、`cocotb`

路径可以在命令行覆盖，例如：

```bash
make -C test/matadd ABYSS_CLANG=/path/to/clang LLVM_MC=/path/to/llvm-mc
```

## 目录内容

| 文件 | 作用 |
| --- | --- |
| `abyss.h` | `blockIdx/blockDim/threadIdx`、`abyss_mem()` 指针转换、`ABYSS_MATRIX` 二维数组类型与 `ABYSS_MAT_*` 运算宏 |
| `run_abyss.py` | **已过时**：Python 功能模拟器，禁止用于验证 |
| `render_raster.py` | **已过时**：基于 Python CPU 模型渲染，禁止用于验证 |
| `pixels_to_image.py` | RTL 帧缓冲像素转 PNG/PPM，可作为库或命令行工具 |
| `examples/` | 示例 C 内核 |
| `start_*.s` | 示例启动 stub |

## CUDA 风格内核

当前测试内核直接使用普通 C 数组和 flat 索引。输入数据在声明处初始化，随后写入
`abyss_mem()` 指向的 DRAM：

```c
int a[8] = {0, 1, 2, 3, 4, 5, 6, 7};
int b[8] = {0, 1, 2, 3, 4, 5, 6, 7};

int *A = (int *)abyss_mem(0);
int *B = (int *)abyss_mem(32);
int *C = (int *)abyss_mem(64);

A[i] = a[i];
B[i] = b[i];
C[i] = A[i] + B[i];
```

二维矩阵同样直接声明为 `int a[n][n] = {...}`。编译器会把局部常量数组提升为
常量全局，Abyss 后端会把它们物化到每个线程的栈帧中，因此不需要额外的只读数据段。

## 矩阵类型与编译期检查

`ABYSS_MATRIX` 仍作为可选的带维度 API 保留；测试内核本身使用上面的普通 C 数组风格。
不再使用 `ABYSS_LD/ABYSS_ST` 这类把地址和访存都藏在宏里的接口。普通指针直接指向
字节地址：

```c
int *A = (int *)abyss_mem(0);
int *B = (int *)abyss_mem(32);
int *C = (int *)abyss_mem(64);
C[i] = A[i] + B[i];
```

需要带维度/元素类型信息的矩阵时，直接定义成 C 二维数组：

```c
ABYSS_MATRIX(my_mat2x2i, int, 2, 2);

my_mat2x2i *A = (my_mat2x2i *)abyss_mem(0);
my_mat2x2i *B = (my_mat2x2i *)abyss_mem(16);
my_mat2x2i *C = (my_mat2x2i *)abyss_mem(32);

(*C)[row][col] = (*A)[row][k] * (*B)[k][col];
ABYSS_MAT_ADD(C, A, B);   // 维度/元素类型由 _Static_assert 检查
ABYSS_MAT_MUL(C, A, B);   // 内维不匹配会在编译期报错
```

`ABYSS_MATRIX` 生成的是 `type[rows][cols]` 数组 typedef；数组类型本身携带形状，
所以函数参数写成 `my_mat2x2i *` 就能保留完整维度信息。`ABYSS_MATRIX_ATTR(type)`
默认使用自然元素对齐，可在包含头文件前覆盖它来追加项目自定义 attribute。
`_Static_assert(sizeof(name) == sizeof(type) * rows * cols)` 再交叉校验扁平大小。

仍然可以按一维索引或强制转换：

```c
int *flat = ABYSS_MAT_FLAT(A);
flat[row * ABYSS_MAT_COLS(A) + col] = 0;

int *raw = (int *)A;   // 显式转换同样允许
raw[0] = 1;
```

`ABYSS_MAT_ADD` / `ABYSS_MAT_MUL` / `ABYSS_MAT_SCALE` 用 `sizeof` 推导
rows/cols，用 `__builtin_types_compatible_p` 检查元素类型，因此非法运算不会拖到
运行时。`abyss_mem()` 仍只做字节地址到指针的转换，保留对内存布局的精细控制。

一维数据也直接用 `ABYSS_MATRIX` 表示，例如 `N x 1` 列向量：

```c
ABYSS_MATRIX(abyss_i32_8x1, int, 8, 1);

abyss_i32_8x1 *A = (abyss_i32_8x1 *)abyss_mem(0);
(*A)[i][0] = 1;

int *flat = ABYSS_MAT_FLAT(A);
flat[i] = 2;
```

矩阵类型就是统一的数组类型，`1 x N` 或 `N x 1` 都可以表示向量；需要扁平索引时
使用 `ABYSS_MAT_FLAT`，需要显式转换时直接转换。

Clang 本身还提供 `__attribute__((matrix_type(rows, cols)))` 和
`__builtin_matrix_add/multiply`；ARM NEON 用 `int32x4_t` + intrinsics，CUDA 用
`int4`/WMMA fragment 类型和 `threadIdx` 内置变量。当前 Abyss 最小后端还没有
vector/matrix 类型的 lowering，所以这里先用标准 C 二维数组 + `_Static_assert`
实现同样的编译期约束；等后端支持向量类型后可以把这些宏替换成 Clang builtins。

## C 语言子集

当前后端面向测试所需整数子集：

- 支持 `int`/`unsigned`/`char`/`short`、算术、位运算、移位、除法/取余、比较、
  分支、循环、`phi`、`select`、`alloca`、函数调用/返回。
- 数据内存按字节寻址；直接使用普通 C 指针访问，矩阵类型/运算由 `_Static_assert` 做编译期检查。
- 不支持浮点、64 位、全局变量、PIC、libc、可变参数；函数/调用参数最多 8 个。
- 每个线程由后端按 `blockIdx * blockDim + threadIdx` 分配独立栈帧。
- 后端对每个基本块做线性扫描寄存器分配，块内值尽量留在寄存器；跨块值和 PHI
  保持栈槽，调用前会溢出活跃寄存器。

光栅化用例位于 `test/raster16x16`、`raster32x32`、`raster64x64`、
`raster128x128`、`raster256x256`、`raster512x512`、`raster1024x1024`。所有
分辨率共用 `test/helpers/raster_kernel.h`：

- 背景：黑色 `0x000000`
- 三角形内部：根据三条边函数的权重，从边缘蓝色 `0x0000FF` 渐变到中心绿色 `0x00FF00`
- 颜色格式：`0x00RRGGBB`
- 帧缓冲：字节地址 0 开始，每个像素一个 32 位字
- 内核不使用条件分支或 `select`，每个线程固定写满自己的像素；这样可避开 GPU
  对分歧线程的串行化路径

运行 RTL 测试：

```bash
make test raster16x16
make test raster64x64
```

### 调整三角形顶点

顶点在 `test/helpers/raster_kernel.h` 中通过宏定义：

```c
RASTER_AX / RASTER_AY   // 顶点 A
RASTER_BX / RASTER_BY   // 顶点 B
RASTER_CX / RASTER_CY   // 顶点 C
```

默认值按分辨率缩放，是一个绕质心逆时针旋转约 210°（之前约 120° 再
逆时针旋转 90°）的 **钝角不等腰三角形**：

- `A = (width * 789 / 1000, height * 364 / 1000)`
- `B = (width * 139 / 1000, height * 739 / 1000)`
- `C = (width * 447 / 1000, height * 273 / 1000)`

C 点的角为钝角，三条边长互不相等。只改某个用例时，在该用例的 C 文件里、
`#include` 之前覆盖：

```c
#define RASTER_WIDTH 16
#define RASTER_HEIGHT 16
#define RASTER_THREADS 16

#define RASTER_AX 2
#define RASTER_AY 2
#define RASTER_BX 13
#define RASTER_BY 4
#define RASTER_CX 5
#define RASTER_CY 13

#include "../../helpers/raster_kernel.h"
```

坐标原点是帧缓冲左上角，x 向右、y 向下；顶点可以超出帧缓冲，最终会自然裁剪。
边的颜色仍由三条边函数的最小权重决定：边上蓝色，中心绿色。内部/外部判断、
`D=area` 和绕序方向都会由 `RASTER_CROSS`、`RASTER_ORIENT`、`RASTER_AREA`
自动处理；绕序反过来也可以。顶点退化（面积为 0）会在编译期报错。

测试的期望像素模型会读取同名宏，因此只需修改 C 顶点，不需要再改
`test/helpers/raster.py` 里的公式。

测试结束后会生成 `test/rasterNxN/build/rasterNxN.png`，同时导出
`test/rasterNxN/build/rasterNxN.pixels.bin`（原始 32 位像素字）。

RTL 配置为 **4 个 CU，每个 CU 8 线程/块**（`src/gpu.v` 中的
`NUM_CORES=4`、`THREADS_PER_BLOCK=8`）。仿真耗时随像素数增长，实测
`16x16` 约 5 秒、`32x32` 约 23 秒、`64x64` 约 1.5 分钟、
`128x128` 约 5 分钟；
`256x256` 及以上需要数十分钟到数小时，但**必须继续使用 RTL**。

Python 功能模拟已过时，不再作为验证或生成参考图的手段。测试只接受
cocotb + Icarus RTL 的结果。

也可以把已有的像素数据交给独立工具：

```bash
python3 tools/pixels_to_image.py test/raster16x16/build/raster16x16.pixels.bin \
  --width 16 --height 16 -o /tmp/raster16x16.png
```

`pixels_to_image.py` 工具支持：

- 输入：原始 little-endian `.bin`，或每行一个 `0xRRGGBB` 的文本文件
- 输出：PNG（默认）或 `.ppm`
- 作为库使用：`from tools.pixels_to_image import memory_pixels, save_png`

## 已过时的 Python 功能模拟

`run_abyss.py` 和 `render_raster.py` 保留仅用于历史对比，**已过时，禁止用于
测试验证或生成验收图片**。所有测试结果必须来自 RTL：

```bash
make test matmul
make test raster16x16