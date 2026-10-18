# Abyss C 工具链与测试

当前测试不再使用 `abysscc` 或 `riscv2abyss.py`。每个 `test/<case>/` 目录都有自己的
`Makefile`，直接使用本仓库构建出的原生 Abyss Clang：

```
test/<case>/src/<case>.c
  │  clang --target=abyss -O2 -c
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

测试产物位于 `test/<case>/build/`，已被 `.gitignore` 忽略。

## 依赖

- `build-abyss-clang/bin/clang`：只包含 Abyss target 的本地 Clang
- `build/bin/llvm-mc`、`build/bin/llvm-objcopy`
- `ld.lld`（LLD 22 可用）
- `iverilog`、`cocotb`、`sv2v`

路径可以在命令行覆盖，例如：

```bash
make -C test/matadd ABYSS_CLANG=/path/to/clang LLVM_MC=/path/to/llvm-mc
```

## 目录内容

| 文件 | 作用 |
| --- | --- |
| `abyss.h` | `blockIdx/blockDim/threadIdx` 访问以及字节地址 `ABYSS_LD/ST` 宏 |
| `run_abyss.py` | 独立的 Abyss 功能模拟器，用于不跑 RTL 时快速检查 |
| `examples/` | 示例 C 内核 |
| `start_*.s` | 示例启动 stub |

## C 语言子集

当前后端面向测试所需整数子集：

- 支持 `int`/`unsigned`/`char`/`short`、算术、位运算、移位、除法/取余、比较、
  分支、循环、`phi`、`select`、`alloca`、函数调用/返回。
- 数据内存按字节寻址；窄访问使用 `ABYSS_LDB/LDBU/LDH/LDHU/STB/STH`。
- 不支持浮点、64 位、全局变量、PIC、libc、可变参数；函数/调用参数最多 8 个。
- 每个线程由后端按 `blockIdx * blockDim + threadIdx` 分配独立栈帧。

## 功能模拟器

```bash
make -C test/matmul
python3 tools/abysscc/run_abyss.py test/matmul/build/matmul.elf --test matmul
```
