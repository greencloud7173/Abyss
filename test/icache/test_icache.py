import cocotb
from cocotb.triggers import RisingEdge

from ..helpers.program import run_case

ITERATIONS = 200


def u32(value):
    return value & 0xFFFFFFFF


def loop_acc(seed, n=ITERATIONS, mult=3):
    """参考模型：acc = seed，然后 n 次 acc = acc * 3 + k（32 位回绕）"""
    acc = seed
    for k in range(n):
        acc = u32(acc * mult + k)
    return acc


async def _watch_icache(dut, stats):
    """在仿真过程中采样命中/未命中计数。

    内核跑完后 dispatch 会拉高 core_reset（准备下一个 block），fetcher 的计数器
    随之清零，所以必须在运行期间连续采样、取最大值。
    """
    while True:
        await RisingEdge(dut.clk)
        for core in dut.cores:
            fetcher = core.core_instance.fetcher_instance
            try:
                hits = int(fetcher.cache_hits.value)
                misses = int(fetcher.cache_misses.value)
            except (ValueError, TypeError):
                continue  # 复位期间是 X
            stats["hits"] = max(stats["hits"], hits)
            stats["misses"] = max(stats["misses"], misses)


@cocotb.test()
async def test_icache(dut):
    # 各线程 seed 不同，但迭代次数相同（没有分支发散支持，必须收敛）
    seeds = [1, 2, 3, 0x12345678]

    stats = {"hits": 0, "misses": 0}
    watcher = cocotb.start_soon(_watch_icache(dut, stats))
    try:
        data_memory, cycles = await run_case(
            dut,
            "icache",
            data=[],
            threads=4,
            display=0,
        )
    finally:
        watcher.kill()

    for i, seed in enumerate(seeds):
        result = data_memory.memory[4 + i]
        expected = loop_acc(seed)
        assert result == expected, (
            f"thread {i}: expected {expected:#010x}, got {result:#010x}"
        )

    hits, misses = stats["hits"], stats["misses"]
    dut._log.info(f"icache: {hits} hits / {misses} misses, {cycles} cycles")

    assert hits > 0, "instruction cache never hit"
    assert misses > 0, "instruction cache never missed"
    assert hits > 20 * misses, (
        f"hit rate too low: {hits} hits vs {misses} misses "
        "(the loop body should be served almost entirely from the cache)"
    )
