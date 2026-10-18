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
    raster.py         # 光栅化测试的采样校验与图片导出
    raster_kernel.h   # 分辨率无关的分支无关光栅化内核
  matadd/
    __init__.py
    test_matadd.py    # 只写 data / threads / 二进制名
    src/
      matadd.c
      start.s
    build/            # 该用例的构建/渲染产物；整个目录被 .gitignore 忽略
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
  icache/
    __init__.py
    test_icache.py        # 同时断言结果、命中率与周期数
    src/
      icache.c            # 200 次循环，取指几乎全命中
      start.s
    build/
      icache.o
      icache.bin
  raster16x16/             # 以及 raster32x32 ... raster1024x1024
    __init__.py
    test_rasterNxN.py
    src/
      rasterNxN.c          # 只定义宽、高、线程数，内核在 helpers 中
      start.s
    build/
      rasterNxN.bin
      rasterNxN.png        # 渲染结果
      rasterNxN.pixels.bin # 原始 32 位像素字
```

光栅化用例共有 `raster16x16`、`raster32x32`、`raster64x64`、
`raster128x128`、`raster256x256`、`raster512x512`、`raster1024x1024` 七种分辨率。
三角形顶点可用 `RASTER_AX/.../RASTER_CY` 宏调整，具体写法见
`tools/README.md` 的“调整三角形顶点”一节。

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
make test icache

make test raster16x16
make test raster32x32
make test raster64x64
make test raster128x128

# rasterNxN 测试会生成 build/rasterNxN.png 和 build/rasterNxN.pixels.bin

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

RTL 配置为 4 个 CU、每个 CU 8 线程/块。优化后仿真时间随像素数增长：
16x16 约 5 秒、32x32 约 23 秒、64x64 约 1.5 分钟、128x128 约 5 分钟；
256x256 及以上需要更长时间，但仍必须使用 RTL：

```bash
make test raster256x256
make test raster512x512
make test raster1024x1024
```

Python 功能模拟（`tools/run_abyss.py`、`tools/render_raster.py`）已标记为过时，
禁止用于测试验证或生成验收图片。

### RTL 性能分析

设置 `ABYSS_PROFILE=1` 可以统计每个 core 的状态周期和已发射指令：

```bash
ABYSS_PROFILE=1 make test raster64x64
```

输出包含 `IDLE` / `FETCH` / `DECODE` / `REQUEST` / `WAIT` / `EXECUTE` /
`UPDATE` 的周期占比、指令类型计数和 LSU 阻塞线程周期，可直接用于定位瓶颈。

`make test matadd` 会委托给 `test/matadd/Makefile`：

1. 用 `clang --target=abyss -O2 -fno-vectorize -fno-slp-vectorize -c` 编译
   `src/matadd.c`，用 `llvm-mc -arch=abyss` 汇编 `src/start.s`；
2. 用 `ld.lld --image-base=0 -Ttext=0 -e _start` 链接成
   `test/matadd/build/matadd.elf`，再提取 `.bin`；
3. 调用根目录的 `make sim` 构建共享 Verilog 模型 `build/gpu.v` 和
   `build/sim.vvp`；
4. Python 入口通过 `test/helpers/program.py` 直接加载 `.bin`。

`test/<case>/build/` 只放该测试自己的产物（`.o`、`.elf`、`.bin`，光栅化用例还有
`.png` 和 `.pixels.bin`），整个目录由 `.gitignore` 中的 `test/*/build/` 忽略。
根目录 `build/` 仍只放 RTL 产物。

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
