# abysscc — 简化版 Abyss C 编译器

用系统 clang 的 RISC-V 前端/代码生成，把 RISC-V 汇编翻译成 Abyss 汇编，再用
LLVM 的 Abyss MC 层汇编成 32 位 Abyss 目标文件。这样**不需要重新构建 clang**，
就能开始写 C 内核；以后要做真正的 Clang target / LLVM 后端时，这套流程和测试
可以继续复用。

```
C 源码
  │  clang --target=riscv32-unknown-elf -march=rv32im -mabi=ilp32 -O2
  ▼
RISC-V 汇编 (.riscv.s)
  │  riscv2abyss.py（寄存器映射 + 伪指令展开）
  ▼
Abyss 汇编 (.abyss.s)
  │  llvm-mc -arch=abyss -filetype=obj
  ▼
Abyss ELF 目标文件 (.o)
```

## 依赖

- 带 RISC-V target 的系统 `clang`（本机 22.1.8 可用）
- Python 3
- 本仓库构建出的 `build/bin/llvm-mc`、`build/bin/llvm-objcopy`
- 运行硬件测试时另需 `iverilog`、`cocotb`、`sv2v`（tiny-gpu 原有依赖）

## 用法

```bash
cd /home/greencloud7173/tiny-gpu/tools/abysscc

# 向量加法：8 个线程，2 个 block，每 block 4 线程
./abysscc --start start_vecadd.s examples/vecadd.c -o /tmp/vecadd.o

# 2x2 矩阵乘法：4 个线程，1 个 block
./abysscc --start start_matmul.s examples/matmul.c -o /tmp/matmul.o

# 加 --keep 保留中间汇编：
./abysscc --start start_vecadd.s --keep examples/vecadd.c -o /tmp/vecadd.o
# 生成 /tmp/vecadd.riscv.s、/tmp/vecadd.kernel.abyss.s、/tmp/vecadd.abyss.s

# 加 --raw 额外输出纯 .text 二进制（小端 32 位字）：
./abysscc --start start_matmul.s --raw examples/matmul.c -o /tmp/matmul.o
# 生成 /tmp/matmul.o 和 /tmp/matmul.bin
```

`--start` 指定启动 stub。stub 负责：

1. 设置 `sp`（示例用字地址 `0x1000`）；
2. 设置翻译器用的常量寄存器 `R23=8`、`R27=2`、`R28=4`（常量移位用）；
3. 可选地设置内核参数（如 matmul 的 `N=2` 放在 `a0`/`R10`）；
4. `JAL R1, kernel` 调用 C 内核；
5. `RET` 结束该 block。

内核的 `ret` 会通过 `JALR x0, 0(R1)` 返回到 stub 的 `RET`。

## 功能验证

功能模拟器（不依赖 Verilog）：

```bash
python3 run_abyss.py /tmp/vecadd.o --test vecadd
python3 run_abyss.py /tmp/matmul.o --test matmul
# vecadd: got [0, 2, 4, ...], want [...], OK
# matmul: got [7, 10, 15, 22], want [...], OK
```

真实硬件模型（cocotb + iverilog）：

```bash
cd /home/greencloud7173/tiny-gpu
make test matadd
make test matmul
# 等价写法：make test_matadd / make test_matmul
```

测试会自动把 `test/<case>/src/<case>.c` 编译成
`test/<case>/build/<case>.bin`，Python 入口只提供数据内存参数和二进制名，
由 `test/helpers/program.py` 负责加载和运行。两个用例均通过。

## 文件说明

| 文件 | 作用 |
| --- | --- |
| `abysscc` | 驱动脚本：clang → 翻译 → llvm-mc |
| `riscv2abyss.py` | RISC-V 汇编到 Abyss 汇编的翻译器 |
| `abyss.h` | `blockIdx/blockDim/threadIdx` 访问和字地址 `ABYSS_LD/ST` 宏 |
| `start_vecadd.s` / `start_matmul.s` | 示例启动 stub |
| `examples/vecadd.c` / `examples/matmul.c` | 示例 C 内核 |
| `run_abyss.py` | 17 条指令的 Abyss 功能模拟器 |
| `../../test/matadd/src/` / `../../test/matmul/src/` | cocotb 测试用的 C 源码和启动 stub |

## C 语言子集与限制

当前目标是“能产生与测试例程功能相同的机器码”，不是完整的 C 环境。翻译器遇到
不支持的指令会**报错**，不会静默生成错误代码。

### 必须注意

- **数据内存按字寻址**：地址 1 是第二个 32 位字，不是字节 1。不要用 `int *`
  指针算术（LLVM 会按 4 字节缩放）；用 `abyss.h` 的整数地址宏：
  ```c
  ABYSS_ST(16, i, ABYSS_LD(0, i) + ABYSS_LD(8, i));
  ```
- 只使用 `int`（32 位）。不要用 `char`/`short`/`long long`/浮点。
- 不要用位运算 `& | ^`，不要用大于 3 的常量移位。
- 不要用无符号除法/取余（`unsigned` 的 `/`、`%`）；ISA 只有有符号 `DIV`。
- 不支持全局变量、`la`、PIC、VLAs、可变参数、`libc`。数据由测试 harness 预先
  放在约定的字地址。
- 函数调用：`call`/`tail` 会翻译成直接 `JAL`；`ret` 翻译成 `JALR x0, 0(ra)`。
  嵌套调用由 clang 正常保存/恢复 `ra`，但被调用函数同样要遵守上述内存/类型限制。
- 栈指针由 stub 设为字地址 `0x1000`。clang 的栈偏移在硬件上按“字偏移”解释，
  帧会变成 4 倍大小的字，但函数内部访问一致；只要栈区不与数据区重叠即可。

### 已支持

- `+ - * /`（有符号）、比较、`if`、`for`/`while`、函数调用/返回
- `ADDI`、`LDR`/`STR`（字）、六种分支、`LUI`/`AUIPC`、`JAL`/`JALR`、`RET`
- 常量移位 0/1/2/3（分别用 `ADDI`、`MUL` ×2、×4、×8 展开）
- `slt`/`sltu`/`slti`/`sltiu` 展开为比较+分支
- `rem` 展开为 `DIV` + `MUL` + `SUB`

### 不支持（会明确报错）

- `andi/ori/xori/and/or/xor`（`andi sp, sp, -16` 作为对齐 no-op 被丢弃）
- `srli/srai/sll/srl/sra` 及大于 3 的 `slli`
- `divu/remu`
- `lh/lhu/sh/lb/lbu/sb`（无字节/半字访存）
- 浮点、64 位、原子、压缩指令等

## 寄存器约定

编译器以 `-ffixed-x23..x31` 调用，因此 C 代码不会用这些寄存器：

| 寄存器 | 用途 |
| --- | --- |
| `x0` | 恒 0 |
| `R1` (`ra`) | 返回地址 |
| `R2` (`sp`) | 栈指针（字地址） |
| `R10-R17` (`a0-a7`) | 参数/返回值 |
| `R23` | 翻译器常量 8（`slli 3`） |
| `R24`/`R25` | `slt`/`slti` 展开临时寄存器 |
| `R26` | `rem` 展开临时寄存器 |
| `R27`/`R28` | 常量 2 / 4（`slli 1/2`） |
| `R29`/`R30`/`R31` | `%blockIdx` / `%blockDim` / `%threadIdx`（只读） |

`abyss.h` 用内联汇编读取 `x29/x30/x31`，效果等同于 Clang builtin；这是简化路线，
没有改 clang 源码。以后若要做真正的 Clang target，可以把这三个函数替换成
`__builtin_abyss_*`。

## 检查生成的程序字

用 `--raw` 可以直接得到 `.bin`；也可以手动提取来检查编码：

```bash
/home/greencloud7173/llvm-project/build/bin/llvm-objcopy \
  -O binary --only-section=.text /tmp/vecadd.o /tmp/vecadd.bin
python3 - <<'PY'
import struct
raw = open('/tmp/vecadd.bin','rb').read()
print(',\n'.join('0x%08X' % w for w in struct.unpack('<%dI' % (len(raw)//4), raw)))
PY
```

测试现在直接加载 `.bin`（见 `test/helpers/program.py`），不需要再手工把程序字
粘进 Python 文件。
