# 测试用例

每个测试用例是一个子目录，C 源码放在该子目录的 `src/` 下：

```
test/
  helpers/
    program.py        # 加载 .bin、构建 program/data memory、运行到 done
    setup.py
    memory.py
    format.py
    logger.py
  matadd/
    __init__.py
    test_matadd.py    # 只写 data / threads / 二进制名
    src/
      matadd.c
      start.s
    build/            # 只放 C 构建产物；整个目录被 .gitignore 忽略
      matadd.o
      matadd.bin
  matmul/
    __init__.py
    test_matmul.py
    src/
      matmul.c
      start.s
    build/
      matmul.o
      matmul.bin
  shift/
    __init__.py
    test_shift.py
    src/
      shift.c
      start.s
    build/
      shift.o
      shift.bin
  mem/
    __init__.py
    test_mem.py
    src/
      mem.c
      start.s
    build/
      mem.o
      mem.bin
  div/
    __init__.py
    test_div.py
    src/
      div.c
      start.s
    build/
      div.o
      div.bin
  slt/
    __init__.py
    test_slt.py
    src/
      slt.c
      start.s
    build/
      slt.o
      slt.bin
  logic/
    __init__.py
    test_logic.py
    src/
      logic.c
      start.s
    build/
      logic.o
      logic.bin
```

## 运行

```bash
cd /home/greencloud7173/tiny-gpu

make test matadd
make test matmul
make test shift
make test mem
make test div
make test slt
make test logic

# 等价写法
make test_matadd
make test_matmul
make test_shift
make test_mem
make test_div
make test_slt
make test_logic
make test CASE=matadd
```

`make test matadd` 会：

1. 用 `tools/abysscc/abysscc --start test/matadd/src/start.s --raw ...`
   把 `test/matadd/src/matadd.c` 编译成 `test/matadd/build/matadd.o` 和
   `test/matadd/build/matadd.bin`；
2. 构建共享 Verilog 模型 `build/gpu.v` 和 `build/sim.vvp`；它们和 cocotb 的
   `results.xml` 一样留在仓库根目录（`build/` 与 `results.xml` 均已被忽略）；
3. Python 入口通过 `test/helpers/program.py` 直接加载 `.bin`，不再内嵌机器码。

`test/<case>/build/` 只放 C 语言构建产物（`.o`、`.bin`，以及 `--keep` 时的中间
汇编）；整个目录由 `.gitignore` 中的 `test/*/build/` 忽略。

## 测试入口写法

入口只需要提供原来的内存参数和二进制产物名：

```python
import cocotb

from ..helpers.program import run_case


@cocotb.test()
async def test_matadd(dut):
    data = [
        0, 1, 2, 3, 4, 5, 6, 7,  # A
        0, 1, 2, 3, 4, 5, 6, 7,  # B
    ]

    data_memory, _ = await run_case(
        dut,
        "matadd",        # 对应 test/matadd/build/matadd.bin
        data=data,
        threads=8,
        display=24,
    )

    expected = [a + b for a, b in zip(data[0:8], data[8:16])]
    for i, value in enumerate(expected):
        result = data_memory.memory[i + 16]
        assert result == value, f"C[{i}] expected {value}, got {result}"
```

`run_case` 负责：

- 从 `test/<case>/build/<binary>.bin`（或 `.o`）加载程序；
- 创建 `program`/`data` memory；
- 调用 `setup` 做时钟、复位、加载、启动；
- 跑到 `dut.done == 1`，返回 `data_memory` 和周期数。

## 新增用例

1. 新建 `test/<name>/src/<name>.c` 和 `test/<name>/src/start.s`；
2. 新建 `test/<name>/test_<name>.py`，按上面的写法调用 `run_case(dut, "<name>", ...)`；
3. 新建空的 `test/<name>/__init__.py`；
4. 直接运行 `make test <name>`。`TEST_CASES` 会自动从 `test/*/src` 推导。
