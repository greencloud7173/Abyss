from collections import defaultdict
from typing import List
from .logger import logger

class Memory:
    def __init__(self, dut, addr_bits, data_bits, channels, name):
        self.dut = dut
        self.addr_bits = addr_bits
        self.data_bits = data_bits
        # Sparse storage: absent addresses read as zero, so DRAM powers on
        # fully zeroed.  Kernels are responsible for writing test inputs.
        self.memory = defaultdict(int)
        self.channels = channels
        self.name = name

        self.mem_read_valid = getattr(dut, f"{name}_mem_read_valid")
        self.mem_read_address = getattr(dut, f"{name}_mem_read_address")
        self.mem_read_ready = getattr(dut, f"{name}_mem_read_ready")
        self.mem_read_data = getattr(dut, f"{name}_mem_read_data")

        if name != "program":
            self.mem_write_valid = getattr(dut, f"{name}_mem_write_valid")
            self.mem_write_address = getattr(dut, f"{name}_mem_write_address")
            self.mem_write_data = getattr(dut, f"{name}_mem_write_data")
            self.mem_write_mask = getattr(dut, f"{name}_mem_write_mask", None)
            self.mem_write_ready = getattr(dut, f"{name}_mem_write_ready")

    def run(self):
        mem_read_valid = [
            int(str(self.mem_read_valid.value)[i:i+1], 2)
            for i in range(0, len(str(self.mem_read_valid.value)), 1)
        ]

        mem_read_address = [
            int(str(self.mem_read_address.value)[i:i+self.addr_bits], 2)
            for i in range(0, len(str(self.mem_read_address.value)), self.addr_bits)
        ]
        mem_read_ready = [0] * self.channels
        mem_read_data = [0] * self.channels

        for i in range(self.channels):
            if mem_read_valid[i] == 1:
                mem_read_data[i] = self.memory[mem_read_address[i]]
                mem_read_ready[i] = 1
            else:
                mem_read_ready[i] = 0

        self.mem_read_data.value = int(''.join(format(d, '0' + str(self.data_bits) + 'b') for d in mem_read_data), 2)
        self.mem_read_ready.value = int(''.join(format(r, '01b') for r in mem_read_ready), 2)

        if self.name != "program":
            mem_write_valid = [
                int(str(self.mem_write_valid.value)[i:i+1], 2)
                for i in range(0, len(str(self.mem_write_valid.value)), 1)
            ]
            mem_write_address = [
                int(str(self.mem_write_address.value)[i:i+self.addr_bits], 2)
                for i in range(0, len(str(self.mem_write_address.value)), self.addr_bits)
            ]
            mem_write_data = [
                int(str(self.mem_write_data.value)[i:i+self.data_bits], 2)
                for i in range(0, len(str(self.mem_write_data.value)), self.data_bits)
            ]
            mem_write_ready = [0] * self.channels

            # Byte enables: only the lanes selected by mem_write_mask are updated,
            # the remaining bytes keep their old value (byte / half-word stores)
            if self.mem_write_mask is not None:
                mem_write_mask = [
                    int(str(self.mem_write_mask.value)[i:i+4], 2)
                    for i in range(0, len(str(self.mem_write_mask.value)), 4)
                ]
            else:
                mem_write_mask = [(1 << 4) - 1] * self.channels

            for i in range(self.channels):
                if mem_write_valid[i] == 1:
                    address = mem_write_address[i]
                    old = self.memory[address]
                    new = 0
                    for lane in range(self.addr_bits // 8):
                        if (mem_write_mask[i] >> lane) & 1:
                            new |= mem_write_data[i] & (0xFF << (8 * lane))
                        else:
                            new |= old & (0xFF << (8 * lane))
                    self.memory[address] = new & 0xFFFFFFFF
                    mem_write_ready[i] = 1
                else:
                    mem_write_ready[i] = 0

            self.mem_write_ready.value = int(''.join(format(w, '01b') for w in mem_write_ready), 2)

    def write(self, address, data):
        if 0 <= address < (1 << self.addr_bits):
            self.memory[address] = data

    def load(self, rows: List[int]):
        for address, data in enumerate(rows):
            self.write(address, data)

    def display(self, rows, decimal=True):
        logger.info("\n")
        logger.info(f"{self.name.upper()} MEMORY")
        
        table_size = (8 * 2) + 3
        logger.info("+" + "-" * (table_size - 3) + "+")

        header = "| Addr | Data "
        logger.info(header + " " * (table_size - len(header) - 1) + "|")

        logger.info("+" + "-" * (table_size - 3) + "+")
        for i in range(rows):
            data = self.memory[i]
            if decimal:
                row = f"| {i:<4} | {data:<4}"
                logger.info(row + " " * (table_size - len(row) - 1) + "|")
            else:
                data_bin = format(data, f'0{self.data_bits}b')
                row = f"| {i:<4} | {data_bin} |"
                logger.info(row + " " * (table_size - len(row) - 1) + "|")
        logger.info("+" + "-" * (table_size - 3) + "+")