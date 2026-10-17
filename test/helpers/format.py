from typing import List, Optional
from .logger import logger

def _to_int(value) -> int:
    # cocotb 2.x exposes signal/parameter values as LogicArray objects, which don't
    # support arithmetic directly, so unwrap handles and coerce to a plain int.
    if hasattr(value, "value"):
        value = value.value
    if isinstance(value, str):
        return int(value, 2)
    return int(value)

def format_register(register: int) -> str:
    if register == 0:
        return "x0"
    if register < 29:
        return f"R{register}"
    if register == 29:
        return f"%blockIdx"
    if register == 30:
        return f"%blockDim"
    if register == 31:
        return f"%threadIdx"
    
def format_instruction(instruction: str) -> str:
    # Instruction layout (see isa/isa.md), MSB-first string offsets:
    #   R-type: funct7[31:25] | rs2[24:20] | rs1[19:15] | funct3[14:12] | rd[11:7] | opcode[6:0]
    #   I-type: imm[11:0][31:20]           | rs1[19:15] | funct3[14:12] | rd[11:7] | opcode[6:0]
    #   U-type: imm[31:12]                 | rd[11:7] | opcode[6:0]
    #   J-type: imm[20|10:1|11|19:12]     | rd[11:7] | opcode[6:0]
    opcode = instruction[25:32]
    funct7 = instruction[0:7]
    rs2 = instruction[7:12]
    rs1 = instruction[12:17]
    funct3 = instruction[17:20]
    rd = instruction[20:25]
    imm = int(instruction[0:12], 2)
    # I-type immediates are signed; branch targets (custom-0) are unsigned absolute addresses
    signed_imm = imm - 4096 if imm >= 2048 else imm

    rd_name = format_register(int(rd, 2))
    rs1_name = format_register(int(rs1, 2))
    rs2_name = format_register(int(rs2, 2))

    if opcode == "0110011":  # OP
        if funct3 == "000":
            return {
                "0000000": f"ADD {rd_name}, {rs1_name}, {rs2_name}",
                "0100000": f"SUB {rd_name}, {rs1_name}, {rs2_name}",
                "0000001": f"MUL {rd_name}, {rs1_name}, {rs2_name}",
            }.get(funct7, f"OP/funct7={funct7}")
        if funct3 == "100" and funct7 == "0000001":
            return f"DIV {rd_name}, {rs1_name}, {rs2_name}"
    elif opcode == "0010011":  # OP-IMM: ADDI (`li rd, imm` when rs1 = x0)
        if funct3 == "000":
            if rd == "00000" and rs1 == "00000" and imm == 0:
                return "NOP"  # ADDI x0, x0, 0
            return f"ADDI {rd_name}, {rs1_name}, #{signed_imm}"
    elif opcode == "0000011":  # LOAD (LDR = `lw rd, imm(rs1)`)
        if funct3 == "010":
            return f"LDR {rd_name}, {signed_imm}({rs1_name})"
    elif opcode == "0100011":  # STORE (STR = `sw rs2, imm(rs1)`); S-type imm is split
        if funct3 == "010":
            store_imm = int(instruction[0:7] + instruction[20:25], 2)
            if store_imm >= 2048:
                store_imm -= 4096
            return f"STR {rs2_name}, {store_imm}({rs1_name})"
    elif opcode == "1100011":  # BRANCH, B-type: `Bcc rs1, rs2, offset` (offset in bytes)
        branch_names = {"000": "BEQ", "001": "BNE", "100": "BLT", "101": "BGE", "110": "BLTU", "111": "BGEU"}
        if funct3 in branch_names:
            # B-type immediate is split: imm[12]=inst[31], imm[11]=inst[7],
            # imm[10:5]=inst[30:25], imm[4:1]=inst[11:8], imm[0]=0
            branch_imm = int(instruction[0] + instruction[24] + instruction[1:7] + instruction[20:24] + "0", 2)
            if branch_imm >= 4096:
                branch_imm -= 8192
            return f"{branch_names[funct3]} {rs1_name}, {rs2_name}, {branch_imm}"
    elif opcode == "1011011":  # custom-2: RET
        return "RET"
    elif opcode == "0110111":  # U-type LUI: rd = imm20 << 12 (imm is unsigned)
        return f"LUI {rd_name}, #{int(instruction[0:20], 2)}"
    elif opcode == "0010111":  # U-type AUIPC: rd = PC + (imm20 << 12)
        return f"AUIPC {rd_name}, #{int(instruction[0:20], 2)}"
    elif opcode == "1100111":  # I-type JALR: rd = PC + 4, PC = (rs1 + imm) & ~1
        if funct3 == "000":
            return f"JALR {rd_name}, {signed_imm}({rs1_name})"
    elif opcode == "1101111":  # J-type JAL: rd = PC + 4, PC += offset (offset in bytes)
        # imm[20]=inst[31], imm[10:1]=inst[30:21], imm[11]=inst[20], imm[19:12]=inst[19:12], imm[0]=0
        jal_imm = int(instruction[0] + instruction[12:20] + instruction[11] + instruction[1:11] + "0", 2)
        if jal_imm >= 1048576:  # 2 ** 20
            jal_imm -= 2097152  # 2 ** 21
        return f"JAL {rd_name}, {jal_imm}"
    return "UNKNOWN"

def format_core_state(core_state: str) -> str:
    core_state_map = {
        "000": "IDLE",
        "001": "FETCH",
        "010": "DECODE",
        "011": "REQUEST",
        "100": "WAIT",
        "101": "EXECUTE",
        "110": "UPDATE",
        "111": "DONE"
    }
    return core_state_map[core_state]

def format_fetcher_state(fetcher_state: str) -> str:
    fetcher_state_map = {
        "000": "IDLE",
        "001": "FETCHING",
        "010": "FETCHED"
    }
    return fetcher_state_map[fetcher_state]

def format_lsu_state(lsu_state: str) -> str:
    lsu_state_map = {
        "00": "IDLE",
        "01": "REQUESTING",
        "10": "WAITING",
        "11": "DONE"
    }
    return lsu_state_map[lsu_state]

def format_memory_controller_state(controller_state: str) -> str:
    controller_state_map = {
        "000": "IDLE",
        "010": "READ_WAITING",
        "011": "WRITE_WAITING",
        "100": "READ_RELAYING",
        "101": "WRITE_RELAYING"
    }
    return controller_state_map[controller_state]

def format_registers(registers: List[str]) -> str:
    formatted_registers = []
    for i, reg_value in enumerate(registers):
        decimal_value = int(reg_value, 2)  # Convert binary string to decimal
        reg_idx = 31 - i # Register data is provided in reverse order
        formatted_registers.append(f"{format_register(reg_idx)} = {decimal_value}")
    formatted_registers.reverse()
    return ', '.join(formatted_registers)

def format_cycle(dut, cycle_id: int, thread_id: Optional[int] = None):
    logger.debug(f"\n================================== Cycle {cycle_id} ==================================")

    for core in dut.cores:
        # Not exactly accurate, but good enough for now
        if _to_int(dut.thread_count) <= _to_int(core.i) * _to_int(dut.THREADS_PER_BLOCK):
            continue

        logger.debug(f"\n+--------------------- Core {_to_int(core.i)} ---------------------+")

        instruction = str(core.core_instance.instruction.value)
        for thread in core.core_instance.threads:
            if _to_int(thread.i) < _to_int(core.core_instance.thread_count): # if enabled
                block_idx = _to_int(core.core_instance.block_id)
                block_dim = _to_int(core.core_instance.THREADS_PER_BLOCK)
                thread_idx = _to_int(thread.register_instance.THREAD_ID)
                idx = block_idx * block_dim + thread_idx

                rs = int(str(thread.register_instance.rs.value), 2)
                rt = int(str(thread.register_instance.rt.value), 2)

                reg_input_mux = int(str(core.core_instance.decoded_reg_input_mux.value), 2)
                alu_out = int(str(thread.alu_instance.alu_out.value), 2)
                lsu_out = int(str(thread.lsu_instance.lsu_out.value), 2)
                constant = int(str(core.core_instance.decoded_immediate.value), 2)

                if (thread_id is None or thread_id == idx):
                    logger.debug(f"\n+-------- Thread {idx} --------+")

                    logger.debug("PC:", int(str(core.core_instance.current_pc.value), 2))
                    logger.debug("Instruction:", format_instruction(instruction))
                    logger.debug("Core State:", format_core_state(str(core.core_instance.core_state.value)))
                    logger.debug("Fetcher State:", format_fetcher_state(str(core.core_instance.fetcher_state.value)))
                    logger.debug("LSU State:", format_lsu_state(str(thread.lsu_instance.lsu_state.value)))
                    logger.debug("Registers:", format_registers([str(item.value) for item in thread.register_instance.registers]))
                    logger.debug(f"RS = {rs}, RT = {rt}")

                    if reg_input_mux == 0:
                        logger.debug("ALU Out:", alu_out)
                    if reg_input_mux == 1:
                        logger.debug("LSU Out:", lsu_out)
                    if reg_input_mux == 2:
                        logger.debug("Constant:", constant)

        logger.debug("Core Done:", str(core.core_instance.done.value))