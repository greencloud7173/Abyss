# Abyss ISA 手册

> **Abyss ISA**(2026-10 起启用此名)是 tiny-gpu 的 32 位 SIMD 指令集。
> 适用实现:`src/decoder.sv`、`src/registers.sv`、`src/pc.sv`、`src/alu.sv`、`src/lsu.sv`(2026-10 版本)
> 状态:`make test matadd`、`make test matmul` 均 PASS,iverilog 无位宽告警
> (已用临时用例逐条验证 B 型六种分支条件、`LUI`/`AUIPC`/`JAL`/`JALR`、以及 6 条移位指令)。
> **指令格式遵循 RISC-V**(字段位置、funct3/funct7 分派、opcode 低两位为 `11`、custom 段用官方保留编码);
> 本文描述**当前实现**的语义,与旧版本的差异见第 10 节。

---

## 1. 概览

- **定长 32 位指令**,格式与译码风格**对齐 RISC-V**;数据与地址 32 位;每个线程 32 个寄存器。
- **执行模型(SIMD)**:一个 core 处理一个 block;block 内 8 个线程(`THREADS_PER_BLOCK`,可配 16)共享 1 个 fetcher + 1 个 decoder,
  但每个线程各有独立的 ALU、LSU、PC、寄存器堆 —— 同一拍所有线程执行同一条指令。
- **指令集**:43 条 —— R 型 15 条(`ADD` `SUB` `MUL` `DIV` `DIVU` `REM` `REMU` `SLT` `SLTU` `AND` `OR` `XOR` `SLL` `SRL` `SRA`)、
  I 型 15 条(`ADDI` `SLTI` `SLTIU` `ANDI` `ORI` `XORI` `LDR` `JALR` `SLLI` `SRLI` `SRAI` `LB` `LH` `LBU` `LHU`)、
  S 型 3 条(`STR` `SB` `SH`)、
  B 型 6 条(`BEQ` `BNE` `BLT` `BGE` `BLTU` `BGEU`)、U 型 2 条(`LUI` `AUIPC`)、J 型 1 条(`JAL`)、GPU 专用 1 条(`RET`,也是 I 型编码)。
  除 `RET` 之外**全部与 RISC-V 官方编码逐位一致**(R/I/S/B/U/J 六种类型齐全)。
- **数据内存按字节寻址**(与 RISC-V 一致):字节 0..3 = 字 0、字节 4..7 = 字 1 ……
  访存单元(LSU)负责 `字节地址 → 字地址 + 字节通道` 的转换,并用**掩码**完成字节/半字读写(第 4.5 节)。
- **`x0` 恒 0**:`R0`(= `x0`)读恒为 0、写入被忽略(与 RISC-V 一致),因此**不能当普通寄存器用**。
- **伪指令**:`NOP` = `ADDI x0, x0, #0`(编码 `0x00000013`)、`LI rd, #imm` = `ADDI rd, x0, #imm`、
  `J offset` = `JAL x0, offset`;已经没有单独的 `NOP`/`CONST` 指令。
- **控制流**:条件分支是 RISC-V **B 型**(`PC + 符号扩展字节偏移`),调用/直接跳转是 **J 型 `JAL`**,
  返回/间接跳转是 **I 型 `JALR`**;`AUIPC`/`JAL`/`JALR` 的写回值由 PC 单元产生;**没有 NZP 标志寄存器**;
  固定 8 个状态(第 6 节),
  不支持分支发散 —— 假设所有线程每步收敛到同一 PC。
- **译码取向**:所有字段都是**固定切片**;译码 = `case (opcode)`(R 型内再嵌 `case (funct3)` / `case (funct7)`),
  没有"按指令类型切换字段来源"的 mux。

## 2. 指令格式与指令类型

### 2.1 位域布局(与 RISC-V 相同)

| 位域 | 宽度 | R-type | I-type | S-type | B-type | U-type | J-type |
| - | - | - | - | - | - | - | - |
| `[6:0]` | 7 | opcode | opcode | opcode | opcode | opcode | opcode |
| `[11:7]` | 5 | rd | rd | imm[4:0] | imm[4:1] | rd | rd |
| `[14:12]` | 3 | funct3 | funct3 | funct3 | funct3 = 分支条件 | —(imm) | —(imm) |
| `[19:15]` | 5 | rs1 | rs1 | rs1 = 地址寄存器 | rs1 = 左操作数 | —(imm) | —(imm) |
| `[24:20]` | 5 | rs2 | — | rs2 = 数据寄存器 | rs2 = 右操作数 | —(imm) | —(imm) |
| `[31:25]` | 7 | funct7 | imm[11:0] 的高 7 位 | imm[11:5] | imm[12]+imm[10:5] | imm[31:25] | imm[20]+imm[10:5] |

要点:

- **opcode 在最低 7 位**,低两位固定为 `11`(与 RISC-V 一致,表示"不是 16 位压缩指令")。
- I 型的立即数 `imm = instruction[31:20]` 是**连续切片**;S 型(`STR`)的 12 位偏移分成
  `imm[11:5] = instruction[31:25]` 和 `imm[4:0] = instruction[11:7]` 两段(硬件在 `STORE` 分支里拼装)。
- B 型的立即数按 RISC-V 原样**打散**(图中 `12`/`11` 就是 `imm[12]`/`imm[11]` 所在位):
  `imm[12]`=bit31、`imm[10:5]`=bits[30:25]、`imm[4:1]`=bits[11:8]、`imm[11]`=bit7、`imm[0]`=0。
- J 型同样打散:`imm[20]`=bit31、`imm[10:1]`=bits[30:21]、`imm[11]`=bit20、`imm[19:12]`=bits[19:12]、`imm[0]`=0(偏移是 2 的倍数)。
  U 型则相反:`imm[31:12]` 是连续切片(它本身就是高位立即数)。
- **立即数在 decoder 里统一成 32 位**(I/S/B/J 做符号扩展,U 左移 12 位且不扩展),
  ALU / LSU / PC 直接当成 32 位有符号值使用,三个模块里没有一行符号判断代码;PC 里的 `>>> 2` 也只是接线。
- RTL 内部沿用旧命名:`rs` ≡ RISC-V 的 `rs1`,`rt` ≡ `rs2`。
- 所有字段都是固定切片;funct3/funct7 只用于**选择**指令,不改变字段位置 ⇒ **不需要额外的 mux**。

### 2.2 指令类型总表(完整)

| 类型 | 指令 | opcode[6:0] | funct3[14:12] | funct7[31:25] | 汇编写法 | 使用的字段 | RISC-V 对应 |
| - | - | - | - | - | - | - | - |
| R | `ADD` | `0110011` | `000` | `0000000` | `ADD rd, rs1, rs2` | rd, rs1, rs2 | `add` |
| R | `SUB` | `0110011` | `000` | `0100000` | `SUB rd, rs1, rs2` | rd, rs1, rs2 | `sub` |
| R | `MUL` | `0110011` | `000` | `0000001` | `MUL rd, rs1, rs2` | rd, rs1, rs2 | `mul`(M 扩展) |
| R | `DIV` | `0110011` | `100` | `0000001` | `DIV rd, rs1, rs2` | rd, rs1, rs2(**有符号**商) | `div`(M 扩展) |
| R | `DIVU` | `0110011` | `101` | `0000001` | `DIVU rd, rs1, rs2` | 同上(**无符号**商) | `divu`(M 扩展) |
| R | `REM` | `0110011` | `110` | `0000001` | `REM rd, rs1, rs2` | 同上(**有符号**余,符号跟被除数) | `rem`(M 扩展) |
| R | `REMU` | `0110011` | `111` | `0000001` | `REMU rd, rs1, rs2` | 同上(**无符号**余) | `remu`(M 扩展) |
| R | `SLL` | `0110011` | `001` | `0000000` | `SLL rd, rs1, rs2` | rd, rs1, rs2(`rs2[4:0]` = 移位量) | `sll` |
| R | `SRL` | `0110011` | `101` | `0000000` | `SRL rd, rs1, rs2` | 同上(逻辑右移) | `srl` |
| R | `SRA` | `0110011` | `101` | `0100000` | `SRA rd, rs1, rs2` | 同上(算术右移) | `sra` |
| R | `SLT` | `0110011` | `010` | `0000000` | `SLT rd, rs1, rs2` | rd=0/1(`rs1 < rs2`,**有符号**) | `slt` |
| R | `SLTU` | `0110011` | `011` | `0000000` | `SLTU rd, rs1, rs2` | rd=0/1(`rs1 < rs2`,**无符号**) | `sltu` |
| R | `AND` | `0110011` | `111` | `0000000` | `AND rd, rs1, rs2` | rd, rs1, rs2(逐位与) | `and` |
| R | `OR` | `0110011` | `110` | `0000000` | `OR rd, rs1, rs2` | 同上(逐位或) | `or` |
| R | `XOR` | `0110011` | `100` | `0000000` | `XOR rd, rs1, rs2` | 同上(逐位异或) | `xor` |
| I | `LDR` | `0000011` | `010` | — | `LDR rd, imm(rs1)` | rd, rs1, imm12 字节偏移 | `lw rd, imm(rs1)` |
| I | `LB` | `0000011` | `000` | — | `LB rd, imm(rs1)` | 同上(取 1 字节,符号扩展) | `lb` |
| I | `LH` | `0000011` | `001` | — | `LH rd, imm(rs1)` | 同上(取 2 字节,符号扩展) | `lh` |
| I | `LBU` | `0000011` | `100` | — | `LBU rd, imm(rs1)` | 同上(取 1 字节,零扩展) | `lbu` |
| I | `LHU` | `0000011` | `101` | — | `LHU rd, imm(rs1)` | 同上(取 2 字节,零扩展) | `lhu` |
| S | `STR` | `0100011` | `010` | — | `STR rs2, imm(rs1)` | rs1=基址, rs2=数据, imm12 字节偏移 | `sw rs2, imm(rs1)` |
| S | `SB` | `0100011` | `000` | — | `SB rs2, imm(rs1)` | 同上(只写 1 字节) | `sb` |
| S | `SH` | `0100011` | `001` | — | `SH rs2, imm(rs1)` | 同上(只写 2 字节) | `sh` |
| I | `ADDI` | `0010011` | `000` | — | `ADDI rd, rs1, #imm12` | rd, rs1, imm12(符号扩展) | `addi` |
| I | `SLTI` | `0010011` | `010` | — | `SLTI rd, rs1, #imm12` | rd=0/1(`rs1 < 符号扩展(imm12)`,**有符号**) | `slti` |
| I | `SLTIU` | `0010011` | `011` | — | `SLTIU rd, rs1, #imm12` | rd=0/1(imm **符号扩展后当无符号**比) | `sltiu` |
| I | `ANDI` | `0010011` | `111` | — | `ANDI rd, rs1, #imm12` | rd ← rs1 & 符号扩展(imm12) | `andi` |
| I | `ORI` | `0010011` | `110` | — | `ORI rd, rs1, #imm12` | rd ← rs1 \| 符号扩展(imm12) | `ori` |
| I | `XORI` | `0010011` | `100` | — | `XORI rd, rs1, #imm12` | rd ← rs1 ^ 符号扩展(imm12);`#-1` 即 `not` | `xori` |
| I | `SLLI` | `0010011` | `001` | —(imm[11:5]=`0000000`) | `SLLI rd, rs1, shamt` | rd, rs1, `imm[4:0]` = 移位量 | `slli` |
| I | `SRLI` | `0010011` | `101` | —(imm[11:5]=`0000000`) | `SRLI rd, rs1, shamt` | 同上(逻辑右移) | `srli` |
| I | `SRAI` | `0010011` | `101` | —(imm[11:5]=`0100000`) | `SRAI rd, rs1, shamt` | 同上(算术右移) | `srai` |
| B | `BEQ` | `1100011` | `000` | — | `BEQ rs1, rs2, offset` | rs1, rs2, imm13 字节偏移 | `beq` |
| B | `BNE` | `1100011` | `001` | — | `BNE rs1, rs2, offset` | 同上 | `bne` |
| B | `BLT` | `1100011` | `100` | — | `BLT rs1, rs2, offset` | 同上(有符号比较) | `blt` |
| B | `BGE` | `1100011` | `101` | — | `BGE rs1, rs2, offset` | 同上(有符号比较) | `bge` |
| B | `BLTU` | `1100011` | `110` | — | `BLTU rs1, rs2, offset` | 同上(无符号比较) | `bltu` |
| B | `BGEU` | `1100011` | `111` | — | `BGEU rs1, rs2, offset` | 同上(无符号比较) | `bgeu` |
| U | `LUI` | `0110111` | — | — | `LUI rd, imm20` | rd,imm20(写入 `imm20<<12`) | `lui` |
| U | `AUIPC` | `0010111` | — | — | `AUIPC rd, imm20` | rd,imm20(写入 `PC + imm20<<12`) | `auipc` |
| J | `JAL` | `1101111` | — | — | `JAL rd, offset` | rd,imm21(链接值 `PC+4`) | `jal` |
| I | `JALR` | `1100111` | `000` | — | `JALR rd, imm(rs1)` | rd, rs1=目标基址, imm12 偏移(链接值 `PC+4`) | `jalr` |
| I | `RET` | `1011011` | `000` | — | `RET` | 全 0 | —(custom-2) |

类型判定一览:

| 类型 | 判定条件 | 字段解释 |
| - | - | - |
| R-type | `opcode == 0110011` | `funct3`(+`funct7`)选运算;rd 目的,rs1/rs2 源 |
| I-type | `opcode == 0010011` / `0000011` / `1011011` | `imm[11:0]` 是立即数或偏移;`funct3` 区分变体 |
| S-type | `opcode == 0100011` | `imm[11:5]`+`imm[4:0]` 是偏移;rs1 基址,rs2 数据 |
| B-type | `opcode == 1100011` | `funct3` 是分支条件;rs1/rs2 是操作数;`imm[12:0]` 是 PC 相对字节偏移 |
| U-type | `opcode == 0110111` / `0010111` | `imm[31:12]` 是 20 位立即数;无 rs1/rs2(funct3 也是立即数的一部分) |
| J-type | `opcode == 1101111` | `imm[20:1]` 是 PC 相对字节偏移;rd 是链接寄存器 |
| 保留 | 其它 opcode,或已分配 opcode 里其它 funct3/funct7 | 等同 `NOP` |

RISC-V 保留的 custom 段分配(便于将来扩展,均已避开官方指令编码):

| opcode | RISC-V 名称 | 本 ISA 用途 |
| - | - | - |
| `0001011` | custom-0 | 预留 |
| `0101011` | custom-1 | 预留 |
| `1011011` | custom-2 | 线程控制(`RET`) |
| `1111011` | custom-3 | 预留 |

伪指令(汇编器展开,没有独立编码):

| 伪指令 | 展开为 | 说明 |
| - | - | - |
| `NOP` | `ADDI x0, x0, #0` | 编码 `0x00000013`,与 RISC-V `nop` 一致 |
| `LI rd, #imm` | `ADDI rd, x0, #imm` | 取常量,与 RISC-V `li` 一致 |
| `J offset` | `JAL x0, offset` | 无条件跳转(不写链接寄存器),与 RISC-V `j` 一致 |

## 3. 寄存器模型

每线程 32 个 32 位寄存器(5 位地址):

| 寄存器 | 名称 | 可写 | 内容 |
| - | - | - | - |
| `R0` | `x0` / `zero` | ✗(恒 0) | 读恒 0,写入被忽略 |
| `R1`–`R28` | 通用 | ✓ | 线程私有,reset 后为 0 |
| `R29` | `%blockIdx` | ✗ | 当前 block 编号(由 dispatcher 写入) |
| `R30` | `%blockDim` | ✗ | `THREADS_PER_BLOCK`(默认 4) |
| `R31` | `%threadIdx` | ✗ | 线程在 block 内的下标(0 … `THREADS_PER_BLOCK`-1) |

- 写回条件为 `rd != 0 && rd < 29`:写入 `x0` 与只读寄存器都会被**静默忽略**。
- `x0` 的实现没有额外硬件:它从不被写,于是始终等于 reset 值 0,读地址 0 直接得到 0(不需要读 mux)。
- `%blockIdx` 每拍跟随 `block_id` 更新;`%blockDim`/`%threadIdx` 在 reset 时初始化,之后不变。
- 内核里常用的全局线程号 `idx = %blockIdx * %blockDim + %threadIdx` 是**内核自己算的**(用 `MUL` + `ADD`),不是硬件特性。

## 4. 指令集参考

"控制信号"列是 `src/decoder.sv` 里的实际取值(未列出的控制信号保持 0)。

### 4.1 R 型算术(opcode `0110011` = RISC-V OP)

| funct3 | funct7 | 指令 | 语法 | 操作 | 关键控制信号 |
| - | - | - | - | - | - |
| `000` | `0000000` | `ADD` | `ADD rd, rs1, rs2` | `rd ← rs1 + rs2` | `reg_write=1`,`reg_input_mux=00`,`alu_mux=00` |
| `000` | `0100000` | `SUB` | `SUB rd, rs1, rs2` | `rd ← rs1 − rs2`(模 2³²) | `reg_write=1`,`reg_input_mux=00`,`alu_mux=01` |
| `000` | `0000001` | `MUL` | `MUL rd, rs1, rs2` | `rd ← rs1 × rs2`(取低 32 位) | `reg_write=1`,`reg_input_mux=00`,`alu_mux=10` |
| `100` | `0000001` | `DIV` | `DIV rd, rs1, rs2` | `rd ← rs1 ÷ rs2`(**有符号**,向零取整,x/0 = −1) | `reg_write=1`,`reg_input_mux=00`,`alu_mux=0011` |
| `101` | `0000001` | `DIVU` | `DIVU rd, rs1, rs2` | `rd ← rs1 ÷ rs2`(**无符号**,x/0 = 2³²−1) | `reg_write=1`,`reg_input_mux=00`,`alu_mux=0111` |
| `110` | `0000001` | `REM` | `REM rd, rs1, rs2` | `rd ← rs1 mod rs2`(**有符号**,符号跟被除数,x%0 = x) | `reg_write=1`,`reg_input_mux=00`,`alu_mux=1000` |
| `111` | `0000001` | `REMU` | `REMU rd, rs1, rs2` | `rd ← rs1 mod rs2`(**无符号**,x%0 = x) | `reg_write=1`,`reg_input_mux=00`,`alu_mux=1001` |
| `001` | `0000000` | `SLL` | `SLL rd, rs1, rs2` | `rd ← rs1 << rs2[4:0]` | `reg_write=1`,`reg_input_mux=00`,`alu_mux=100` |
| `101` | `0000000` | `SRL` | `SRL rd, rs1, rs2` | `rd ← rs1 >> rs2[4:0]`(**逻辑**) | `reg_write=1`,`reg_input_mux=00`,`alu_mux=101` |
| `101` | `0100000` | `SRA` | `SRA rd, rs1, rs2` | `rd ← rs1 >>> rs2[4:0]`(**算术**,带符号) | `reg_write=1`,`reg_input_mux=00`,`alu_mux=110` |
| `010` | `0000000` | `SLT` | `SLT rd, rs1, rs2` | `rd ← (rs1 < rs2) ? 1 : 0`(**有符号**比较) | `reg_write=1`,`reg_input_mux=00`,`alu_mux=1010` |
| `011` | `0000000` | `SLTU` | `SLTU rd, rs1, rs2` | `rd ← (rs1 < rs2) ? 1 : 0`(**无符号**比较) | `reg_write=1`,`reg_input_mux=00`,`alu_mux=1011` |
| `111` | `0000000` | `AND` | `AND rd, rs1, rs2` | `rd ← rs1 & rs2` | `reg_write=1`,`reg_input_mux=00`,`alu_mux=1100` |
| `110` | `0000000` | `OR` | `OR rd, rs1, rs2` | `rd ← rs1 \| rs2` | `reg_write=1`,`reg_input_mux=00`,`alu_mux=1101` |
| `100` | `0000000` | `XOR` | `XOR rd, rs1, rs2` | `rd ← rs1 ^ rs2` | `reg_write=1`,`reg_input_mux=00`,`alu_mux=1110` |

`ADD`/`SUB`/`MUL`/`DIV`/`SLT`/`SLTU`/`AND`/`OR`/`XOR` 的编码与 RISC-V 官方一致(含 M 扩展的 `funct7=0000001`)。
❗`funct3` 的 `100`/`110`/`111` 是与 `DIV`/`REM`/`REMU` **共用**的,靠 `funct7` 区分:
`0000000` = 逻辑运算,`0000001` = M 扩展的除/余。

### 4.2 B 型条件分支(opcode `1100011` = RISC-V BRANCH)

| funct3 | 指令 | 语法 | 跳转条件(满足则 `PC ← PC + (offset >>> 2)`) | 关键控制信号 |
| - | - | - | - | - |
| `000` | `BEQ` | `BEQ rs1, rs2, offset` | `rs1 == rs2` | `branch_enable=1`,`branch_cond=000` |
| `001` | `BNE` | `BNE rs1, rs2, offset` | `rs1 != rs2` | `branch_enable=1`,`branch_cond=001` |
| `100` | `BLT` | `BLT rs1, rs2, offset` | `rs1 < rs2`(有符号) | `branch_enable=1`,`branch_cond=100` |
| `101` | `BGE` | `BGE rs1, rs2, offset` | `rs1 >= rs2`(有符号) | `branch_enable=1`,`branch_cond=101` |
| `110` | `BLTU` | `BLTU rs1, rs2, offset` | `rs1 < rs2`(无符号) | `branch_enable=1`,`branch_cond=110` |
| `111` | `BGEU` | `BGEU rs1, rs2, offset` | `rs1 >= rs2`(无符号) | `branch_enable=1`,`branch_cond=111` |

- 没有 rd(不写寄存器),`reg_write` / `mem_read_enable` / `mem_write_enable` 全为 0;
  控制信号只有 `decoded_branch_enable` 与 `decoded_branch_cond = funct3`(不再有 `pc_mux`)。
- 立即数是 **PC 相对字节偏移**(B 型 13 位有符号,`imm[0]` 恒 0;decoder 把它符号扩展成 32 位);**`offset` 相对于当前指令自身**,
  所以“跳过紧随其后的一条指令”写 `offset = 8`,`offset = 0` 则原地循环。
- 偏移的 `>>> 2` 在 `src/pc.sv` 里只是**接线**:PC 以“指令条数”计,程序存储器按字寻址 ⇒ 字节偏移右移两位就是指令条数。
- 比较在 `src/pc.sv` 里**每线程各做一次**,直接比较 `rs1`/`rs2`,不经 ALU、不写任何标志位。

### 4.3 U 型、J 型与 JALR(高位立即数 / 跳转)

| opcode | 指令 | 语法 | 操作 | 关键控制信号 |
| - | - | - | - | - |
| `0110111` | `LUI` | `LUI rd, imm20` | `rd ← imm20 << 12`(低 12 位为 0) | `reg_write=1`,`reg_input_mux=00`,`alu_mux=00`(ADD),`alu_imm_enable=1`,rs1 被强指为 `x0` |
| `0010111` | `AUIPC` | `AUIPC rd, imm20` | `rd ← PC + (imm20 << 12)` | `reg_write=1`,`reg_input_mux=10`(PC 单元算值) |
| `1101111` | `JAL` | `JAL rd, offset` | `rd ← PC + 4`;`PC ← PC + (offset >>> 2)` | `reg_write=1`,`reg_input_mux=10`,`jump_enable=1` |
| `1100111` | `JALR`(I 型) | `JALR rd, imm(rs1)` | `rd ← PC + 4`;`PC ← (rs1 + imm) >>> 2` | `reg_write=1`,`reg_input_mux=10`,`jalr_enable=1`,funct3 必须是 `000` |

- `LUI` 复用 ALU 的 ADD:**把 rs1 地址强指成 `x0`**(=0),B 操作数用立即数,于是 `0 + (imm20 << 12)`。
  没有新增 ALU 运算,也没有新增 mux —— 只需 decoder 把 `decoded_rs_address` 改成 0。
- `AUIPC`/`JAL`/`JALR` 的写回值不是 ALU 结果,而是 **PC 单元算出来的值**(`reg_input_mux = 10`,即原来空着的编码):
  `JAL`/`JALR` 的链接值是 `(PC + 1) << 2`(**纯接线**),`AUIPC` 是 `PC + (imm20 << 12)`。
- PC 单元里只有 **2 个 32 位加法器/线程**:一个算 `next_pc`,另一个由 **AUIPC 与 JALR 共享** ——
  A 端口在 `PC_byte`(AUIPC)与 `rs1`(JALR)之间切,B 端口恒为立即数。
- `JALR` 是**寄存器间接跳转**:目标字节地址 = `rs1 + 符号扩展(imm12)`,再 `>>> 2` 变指令下标。
  这个加法必须在 **PC 单元**做(不能用 ALU):ALU 输出是**寄存器打拍**的,EXECUTE 当拍拿不到结果,
  而 `next_pc` 必须在 EXECUTE 拍内算好。
- `JALR` 要求目标 4 字节对齐:`>>> 2` 会丢掉最低两位(RISC-V 是 `& ~1`,本实现再向下取整到 4),不 trap。
- **PC 表示“第几条指令”,而 PC 相关量按 RISC-V 语义是字节地址**:`PC_byte = current_pc * 4`;`*4` 与 `>>> 2` 都只是接线。
- `offset` 相对**当前**指令:`8` = 跳过下一条,`-8` = 往回一条(必须是 2 的倍数)。
- `rd = x0` 时写入被忽略 ⇒ **`JAL x0, offset` 就是无条件跳转**(伪指令 `J offset`);
  `JAL ra, offset` 是调用,链接值 = 下一条指令的字节地址;配上 `JALR x0, 0(ra)` 就是完整的调用/返回。
- `imm20` 是**无符号** 20 位(`LUI rd, 0xFFFFF` → `0xFFFFF000`);`JAL` 的偏移是**有符号** 21 位。
- 立即数范围:`LUI`/`AUIPC` 的 imm20 = 0 … 1048575;`JAL` 偏移 = −1048576 … +1048574。

### 4.4 GPU 专用指令(RISC-V custom-2)

| opcode | funct3 | 指令 | 语法 | 操作 | 关键控制信号 |
| - | - | - | - | - | - |
| `1011011` | `000` | `RET` | `RET` | 结束本 block,scheduler 置 `done` | `ret=1` |

### 4.5 I 型与 S 型(单指令运算 / 访存)

| opcode | funct3 | 指令 | 语法 | 操作 | 关键控制信号 |
| - | - | - | - | - | - |
| `0010011` | `000` | `ADDI` | `ADDI rd, rs1, #imm12` | `rd ← rs1 + 符号扩展(imm12)` | `reg_write=1`,`reg_input_mux=00`,`alu_mux=00`,`alu_imm_enable=1` |
| `0000011` | `000` / `001` | `LB` / `LH` | `LB/LH rd, imm(rs1)` | `rd ← sign_ext(mem8/16[rs1+imm])` | `reg_write=1`,`reg_input_mux=01`,`mem_read_enable=1`,`mem_size=00/01` |
| `0000011` | `100` / `101` | `LBU` / `LHU` | `LBU/LHU rd, imm(rs1)` | `rd ← zero_ext(mem8/16[...])` | 同上,再加 `mem_unsigned=1` |
| `0000011` | `010` | `LDR` | `LDR rd, imm(rs1)` | `rd ← mem[rs1 + imm]`(异步) | `reg_write=1`,`reg_input_mux=01`,`mem_read_enable=1`,`mem_size=10` |
| `0100011` | `010` | `STR` | `STR rs2, imm(rs1)` | `mem[rs1 + imm] ← rs2`(异步) | `mem_write_enable=1`,`mem_size=10`,mask=4'b1111 |
| `0100011` | `000` / `001` | `SB` / `SH` | `SB/SH rs2, imm(rs1)` | 只写 1 / 2 字节 | `mem_write_enable=1`,`mem_size=00/01`,mask 由 lane 算出 |
| `0010011` | `001` | `SLLI` | `SLLI rd, rs1, shamt` | `rd ← rs1 << shamt`(shamt = `imm[4:0]`,`imm[11:5]` 必须为 0) | `reg_write=1`,`reg_input_mux=00`,`alu_mux=100`,`alu_imm_enable=1` |
| `0010011` | `101` | `SRLI` / `SRAI` | `SRLI/SRAI rd, rs1, shamt` | `rd ← rs1 >> shamt` / `rd ← rs1 >>> shamt` | 同上,`alu_mux=101` / `110`,靠 `imm[11:5]`(`0000000` / `0100000`)区分 |
| `0010011` | `010` | `SLTI` | `SLTI rd, rs1, #imm12` | `rd ← (rs1 < imm) ? 1 : 0`(**有符号**) | `reg_write=1`,`reg_input_mux=00`,`alu_mux=1010`,`alu_imm_enable=1` |
| `0010011` | `011` | `SLTIU` | `SLTIU rd, rs1, #imm12` | `rd ← (rs1 < imm) ? 1 : 0`(**无符号**,imm 先符号扩展) | 同上,`alu_mux=1011` |
| `0010011` | `111` | `ANDI` | `ANDI rd, rs1, #imm12` | `rd ← rs1 & imm` | `reg_write=1`,`reg_input_mux=00`,`alu_mux=1100`,`alu_imm_enable=1` |
| `0010011` | `110` | `ORI` | `ORI rd, rs1, #imm12` | `rd ← rs1 \| imm` | 同上,`alu_mux=1101` |
| `0010011` | `100` | `XORI` | `XORI rd, rs1, #imm12` | `rd ← rs1 ^ imm`(`#-1` = `not`) | 同上,`alu_mux=1110` |

- `ADDI` 把 ALU 的 B 操作数从 `rs2` 切到符号扩展后的 `imm12`(`decoded_alu_imm_enable`,ALU 内部一个 2:1 mux),运算仍是 ADD。
  `ADDI rd, x0, #imm` 就是伪指令 `LI rd, #imm`;`ADDI x0, x0, #0` 就是 `NOP`(写入 x0 被忽略,所以真的什么都不做)。
- `LDR`/`STR`/`LB`/`LH`/`LBU`/`LHU`/`SB`/`SH` 是 RISC-V 的**偏移寻址 + 字节地址**:
  `byte_address = rs1 + 符号扩展(imm12)`,加法在 LSU 里做(每线程一个 32 位加法器)。
- **内存端口是字宽(32 位),LSU 负责桥接**:`word_address = byte_address >>> 2`,`lane = byte_address[1:0]`。
  - 读:`LB`/`LH` 把选中的字节/半字**移到低位**再符号扩展,`LBU`/`LHU` 零扩展,`LDR` 取整字;
  - 写:`SB`/`SH` 把数据移进对应 lane 并输出 **`mem_write_mask`(4 位字节使能)**,内存只更新被选中的字节。
- 宽度由 **`funct3`** 选:`000` 字节、`001` 半字、`010` 字;load 的 bit2 = 1 表示无符号(`LBU`/`LHU`)。
- `STR`/`SB`/`SH` 是 S 型,偏移被拆到 `[31:25]`/`[11:7]` 两段,`decoder` 在 `STORE` 分支里拼成 12 位再送给 LSU。
- 立即数范围:`ADDI` 与访存偏移为 −2048 … 2047(符号扩展);B 型字节偏移为 −4096 … +4094(且必须是 4 的倍数)。
- 对齐:`LDR`/`STR` 要求 4 字节对齐,`LH`/`LHU`/`SH` 要求 2 字节对齐;不对齐时本实现**不 trap**,而是按所在字 + lane
  截断处理(见第 9 节)。
- `DIV`/`DIVU`/`REM`/`REMU` 四件套对应 RISC-V 的 `div`/`divu`/`rem`/`remu`:**商与余都提供,有符号与无符号都提供**。
  除零不再传播 `x`,而是按 RISC-V 规则:`DIV`/`DIVU` 返回全 1(`−1` / `0xFFFFFFFF`),`REM`/`REMU` 返回被除数;
  `INT_MIN / −1` 回绕成 `INT_MIN`(两补码除法溢出,与 RISC-V 一致)。
- `SLT`/`SLTU`/`SLTI`/`SLTIU` **只写 0 或 1**,不需要新的写回通路(仍走 `reg_input_mux=00`) —— ALU 内部就两个
  比较器(`<` 有符号 / `<` 无符号),结果零扩展成 32 位送 rd。
  ⚠️ `SLTIU` 的立即数**先符号扩展再当无符号用**(与 RISC-V 一致):`SLTIU rd, rs1, #-1` 实际是 `rs1 < 0xFFFFFFFF`,
  而不是 `rs1 < −1`;这正是 C 里 `x < 0xFFFFFFFFu` 编译出来的形式。

### 4.6 每条指令的执行阶段

| 指令 | 读寄存器 | 计算 / 访存 | 写回 |
| - | - | - | - |
| `ADD` `SUB` `MUL` `DIV` `DIVU` `REM` `REMU` | `REQUEST` 采样 rs、rt | `EXECUTE` ALU 运算 | `UPDATE` 写 rd |
| `SLL` `SRL` `SRA` `SLLI` `SRLI` `SRAI` | `REQUEST` 采样 rs1、rs2 | `EXECUTE` 桶形移位器(1 拍) | `UPDATE` 写 rd |
| `LDR` `LB` `LH` `LBU` `LHU` | `REQUEST` 采样 rs1(基址) | 字节地址→字地址+lane;`REQUEST` 发起读,`WAIT` 等应答 | `UPDATE` 写 rd(选择 lane 后扩展) |
| `STR` `SB` `SH` | `REQUEST` 采样 rs1(基址)、rs2(数据) | 同上;写数据移位到 lane,并带 4 位字节掩码 | — |
| `ADDI` | `REQUEST` 采样 rs1 | `EXECUTE` ALU 加立即数 | `UPDATE` 写 rd |
| `SLT` `SLTU` `SLTI` `SLTIU` | `REQUEST` 采样 rs1、rs2(或立即数) | `EXECUTE` ALU 比较,得出 0/1 | `UPDATE` 写 rd |
| `AND` `OR` `XOR` `ANDI` `ORI` `XORI` | `REQUEST` 采样 rs1、rs2(或立即数) | `EXECUTE` ALU 逐位运算 | `UPDATE` 写 rd |
| `LUI` | 无需读(rs1 强指 `x0`) | `EXECUTE` ALU 加 `imm20<<12` | `UPDATE` 写 rd |
| `AUIPC` | — | `EXECUTE` PC 单元算 `PC + imm` | `UPDATE` 写 rd |
| `JAL` | — | `EXECUTE` 算目标 PC | `UPDATE` 写 rd(链接值)**并**改 PC |
| `JALR`(I 型) | `REQUEST` 采样 rs1(目标基址) | `EXECUTE` 算 `(rs1 + imm) >>> 2` | `UPDATE` 写 rd(链接值)**并**改 PC |
| B 型分支 | `REQUEST` 采样 rs1、rs2 | `EXECUTE` 比较并决定是否跳转 | `UPDATE` 改 PC |
| `NOP` `RET` | — | — | — |

## 5. 分支与跳转

- 分支**没有标志寄存器**(已删除旧的 NZP):`Bcc rs1, rs2, offset` 在 `EXECUTE` 阶段直接比较两个操作数,
  当拍决定是否跳转(`src/pc.sv`)。
- 比较规则(与 RISC-V 一致):

| funct3 | 指令 | 条件 | 比较方式 |
| - | - | - | - |
| `000` | `BEQ` | `rs1 == rs2` | 位相等 |
| `001` | `BNE` | `rs1 != rs2` | 位相等取反 |
| `100` | `BLT` | `rs1 < rs2` | **有符号**(32 位补码) |
| `101` | `BGE` | `rs1 >= rs2` | **有符号**取反 |
| `110` | `BLTU` | `rs1 < rs2` | **无符号** |
| `111` | `BGEU` | `rs1 >= rs2` | **无符号**取反 |

- 不跳转时 `PC ← PC + 1`;跳转时 `PC ← PC + (imm >>> 2)`(立即数在 decoder 里已符号扩展成 32 位的**字节**偏移)。
  汇编里的 `offset` 相对**当前**指令,所以“跳过下一条”写 `offset = 8`。
- **`JAL` 是无条件跳转**:`PC ← PC + (offset >>> 2)` 且 `rd ← PC + 4`(链接值);
  `JAL x0, offset` 不写任何寄存器,就是纯跳转。
- **`JALR` 是寄存器间接跳转**:`PC ← (rs1 + imm) >>> 2` 且 `rd ← PC + 4`。
  目标来自寄存器 ⇒ 可以跳“算出来的地址”(返回/函数指针/跳转表);`JALR x0, 0(ra)` 就是 `return`。
- **`AUIPC` 不改变控制流**(`PC ← PC + 1`),只把 `PC + (imm20<<12)` 写进 rd;
  它与 `JAL`/`JALR` 都用 `reg_input_mux = 10` 从 PC 单元写回。
- `JAL` / `JALR` / `AUIPC` 写入的 rd 值是 **字节地址**(PC × 4);与 B 型偏移保持同一套“PC 相关量按字节计”的约定。
- 分支与比较是同一条指令 ⇒ 条件跳转**不再需要**“标志位先由另一条指令写入”(旧的 `CMP` + `BRnzp` 要隔一条)。
- 实现细节(`src/pc.sv`):`rs_signed < rt_signed`(有符号)与 `rs < rt`(无符号)两个比较结果 + 一个 `case` 选条件;
  `>>> 2`、`PC*4` 与符号扩展都是接线,没有额外算术逻辑。
- 无分支发散:一个 block 的 8 个线程各算各的条件,实际 PC 取**最后一个线程**的值
  (`current_pc <= next_pc[THREADS_PER_BLOCK-1]`),所以内核里要保持各线程控制流一致。

## 6. 执行模型与流水阶段

每个 core 的状态机(`src/scheduler.sv`)固定 8 态,block 内所有线程同步前进:

| core_state | 名称 | 本拍发生的事 |
| - | - | - |
| `000` | IDLE | 等 `start`(dispatcher 分配 block) |
| `001` | FETCH | fetcher 读取 `instruction[current_pc]` |
| `010` | DECODE | decoder 锁存字段、产生控制信号 |
| `011` | REQUEST | 寄存器堆采样 `rs`/`rt`;`LDR`/`STR` 在此发起内存请求 |
| `100` | WAIT | 若有 LSU 处于 REQUESTING/WAITING 就继续等待(内存延迟);**非访存指令跳过本态** |
| `101` | EXECUTE | ALU 运算 / 比较;PC 单元算分支、跳转与 `pc_result` |
| `110` | UPDATE | 写回 rd(ALU / LSU / PC 单元三种来源)、更新 PC |
| `111` | DONE | 本 block 结束(遇到 `RET`) |

写汇编 / 看波形时要记住的几条:

1. 每条指令都走完整流程(`LDR`/`STR` 的 `WAIT` 因内存延迟更长),因此相邻指令之间天然隔开约 5 拍;
   `ALU` / 分支 / `JAL` / `LUI` / `AUIPC` / `RET` 这类不访问数据内存的指令在 `REQUEST` 之后**直接进 `EXECUTE`**(见 6.2)。
2. `rs`/`rt` 在 `REQUEST` 采样 —— 指令用的是"它到达 REQUEST 那一刻"的寄存器值,**紧邻的写后读依赖也安全**。
3. `WAIT` 会等到**所有**线程的 LSU 都不在 REQUESTING/WAITING 才进 `EXECUTE`(SIMD 锁步)。
4. 只在 `UPDATE` 写:运算类 / `LDR` / `LUI` / `AUIPC` / `JAL` 写 rd,分支与跳转改 PC;`STR` 不写寄存器。
5. 分支在 `EXECUTE` 比较、在 `UPDATE` 改 PC;分支自己就带比较,不需要任何前置比较指令。
6. 无分支发散:`current_pc <= next_pc[THREADS_PER_BLOCK-1]`,即取最后一个线程的下一 PC;要求各线程每步收敛到同一 PC。
7. 每个 block 的 PC 从 0 开始;`RET` 后 core 被 dispatcher 复位并接收下一个 block。

### 6.1 指令 cache(2026-10)

`src/fetcher.sv` 里每个 core 带一个**直接映射指令 cache**:

| 项 | 取值 |
| - | - |
| 结构 | 直接映射,行 = 1 条 32 位指令,`CACHE_LINES` 行(`parameter`,默认 128,必须是 2 的幂) |
| 索引 / 标记 | `index = pc[INDEX_BITS-1:0]`,`tag = pc[ADDR_BITS-1:INDEX_BITS]` |
| 命中 | **完全不访问 program memory**;`instruction` 直接从 cache 取,`FETCH` 只占 1 拍 |
| 未命中 | 发一次 `program_mem_read`,收到的字写回该行(数据 + tag + valid) |
| 冲刷 | `flush` 拉高时整块失效;`core.sv` 在 `core_state == IDLE` 时拉高,即**每次新一轮执行前** |
| 计数 | `cache_hits` / `cache_misses`(32 位,可从 cocotb 层次化读取) |

命中路径为什么能省两拍:命中时 fetcher 在 `FETCH` 那一拍就把 `instruction` 和
`fetcher_state = FETCHED` 同时置好,并把 `fetch_hit` 送给 scheduler;`FETCH` 分支写成
`fetcher_state == FETCHED || fetch_hit`,于是下一拍直接进 `DECODE`,不需要等内存往返。
未命中时仍走 `IDLE → FETCHING → FETCHED` 的老路。

⚠️ 冲刷为什么挂在 IDLE 上:一次 kernel launch 内 program memory 不会变,但换 kernel 时会变,
而 core 在两块之间一定经过 IDLE。把 flush 绑在这里等价于"流水线冲刷":没有一条取过的指令
能活过重启点。想改成"分支时冲刷"(即 control hazard 式的 flush)也可以,但循环每跳一次就全失效,
反而比不做 cache 更慢。

实测(同一条内核,仅 `fetch_hit` 置 0 做对照):

| 用例 | 无 cache | 有 cache | 变化 |
| - | - | - | - |
| `raster32x32`(内层循环 92 条指令) | 1.90e9 ns | 5.75e8 ns | **−70%** |
| `raster16x16` | 4.29e8 ns | 2.66e8 ns | −38% |
| `icache`(200 次循环) | 5.3 万拍 | 3.3 万拍 | −38%(命中率 98.3%) |
| `matmul`(循环只有 2 次) | 4.30e7 ns | 4.00e7 ns | −7% |
| `logic`(直线代码) | 2.98e7 ns | 2.98e7 ns | 0 |

面积代价:每行 `32 + TAG + 1` 位,128 行约 7.4 kbit/core。若内层循环比 `CACHE_LINES` 长,
直接映射会冲突抖动(raster 的 92 条指令循环在 `CACHE_LINES = 32` 时几乎全部未命中),
此时把 `CACHE_LINES` 调大或改成组相联即可。

### 6.2 跳过 WAIT:非访存指令不再空等(2026-10)

`WAIT` 原本对**每条**指令都要待一拍,即使它根本不碰内存。现在 `REQUEST` 之后先看
`decoded_mem_read_enable || decoded_mem_write_enable`:

| 指令 | 旧路径 | 新路径 |
| - | - | - |
| `LDR`/`LB`/`LH`/`LBU`/`LHU`/`STR`/`SB`/`SH` | `REQUEST → WAIT → EXECUTE` | 不变 |
| `ADD`/`DIV`/`SLT`/`AND`/移位/分支/`JAL`/`JALR`/`LUI`/`AUIPC`/`RET` | `REQUEST → WAIT → EXECUTE` | **`REQUEST → EXECUTE`**(省 1 拍) |

顺手把 `any_lsu_waiting` 从"clocked block 里带 `break` 的 for 循环"改成模块级
**OR-reduce**(`wire any_lsu_waiting = |lsu_busy;`),综合出来是一条宽或门,不再是串行优先级链。

实测(raster16x16,采样 profiler):

| 指标 | 优化前 | 优化后 |
| - | - | - |
| 总拍数 | 10,633 | **9,270**(−12.8%) |
| `WAIT` 占忙时 | 25.3%(1.85 拍/指令) | **14.3%**(0.91 拍/指令) |
| 剩余 `WAIT` | 每条指令 1 拍 | 只剩访存指令在等 LSU |

影响面:访存比例越高的内核收益越小(标量访存型内核约 −7%,光栅这类计算型约 −14%)。

## 7. 编码速查

```
R 型:instr = (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode
I 型:instr = (imm12  << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode
S 型:instr = (imm[11:5] << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (imm[4:0] << 7) | opcode
B 型:instr = (imm[12] << 31) | (imm[10:5] << 25) | (rs2 << 20) | (rs1 << 15)
              | (funct3 << 12) | (imm[4:1] << 8) | (imm[11] << 7) | opcode
U 型:instr = (imm20 << 12) | (rd << 7) | opcode
J 型:instr = (imm[20] << 31) | (imm[10:1] << 21) | (imm[11] << 20) | (imm[19:12] << 12) | (rd << 7) | opcode
移位(R 型):instr 同 R 型,只需 funct3/funct7(SLL = 001/0000000,SRL = 101/0000000,SRA = 101/0100000)
移位(I 型):instr = ((0x20 或 0) << 25) | (shamt << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode
            SLLI/SRLI 的 imm[11:5] = 0000000,SRAI 的 = 0100000;shamt 恒为 0 … 31
```

(完整分配见 [2.2 指令类型总表](#22-指令类型总表完整)。)

本 ISA 与真实 RISC-V 的重合情况(这几条可以直接用 RISC-V 汇编器/反汇编器验证):

| 本 ISA | 等价 RISC-V | 是否逐位相同 |
| - | - | - |
| `ADD/SUB/MUL/DIV` | `add/sub/mul/div` | ✅(含 M 扩展 funct7) |
| `DIVU/REM/REMU` | `divu/rem/remu` | ✅(funct3 `101`/`110`/`111` + funct7 `0000001`) |
| `SLL/SRL/SRA` | `sll/srl/sra` | ✅ |
| `SLT/SLTU` / `SLTI/SLTIU` | `slt/sltu` / `slti/sltiu` | ✅(funct3 `010`/`011` 完全一致) |
| `AND/OR/XOR` / `ANDI/ORI/XORI` | `and/or/xor` / `andi/ori/xori` | ✅(funct3 `111`/`110`/`100` + funct7 `0000000`) |
| `SLLI/SRLI/SRAI` | `slli/srli/srai` | ✅(imm[11:5] 的 0000000 / 0100000 完全一致) |
| `ADDI rd, rs1, #imm` | `addi rd, rs1, imm` | ✅ |
| `LDR rd, imm(rs1)` | `lw rd, imm(rs1)` | ✅ |
| `LB/LH/LBU/LHU rd, imm(rs1)` | `lb/lh/lbu/lhu rd, imm(rs1)` | ✅(funct3 完全一致) |
| `STR rs2, imm(rs1)` | `sw rs2, imm(rs1)` | ✅ |
| `SB/SH rs2, imm(rs1)` | `sb/sh rs2, imm(rs1)` | ✅ |
| `BEQ/BNE/BLT/BGE/BLTU/BGEU` | `beq/bne/blt/bge/bltu/bgeu` | ✅ |
| `LUI rd, imm20` | `lui rd, imm20` | ✅ |
| `AUIPC rd, imm20` | `auipc rd, imm20` | ✅ |
| `JAL rd, offset` | `jal rd, offset` | ✅ |
| `JALR rd, imm(rs1)` | `jalr rd, imm(rs1)` | ✅ |
| `NOP`(`ADDI x0, x0, #0`) / `LI rd, #imm` / `J offset` | `nop` / `li rd, imm` / `j offset` | ✅ |
| `RET` | — | custom-2 |

内核里实际用到的编码(可直接抄进测试):

| 汇编 | 编码 |
| - | - |
| `MUL R13, %blockIdx, %blockDim` | **0x03EE86B3** |
| `ADD R13, R13, %threadIdx` | **0x01F686B3** |
| `ADDI R1, x0, #0`(=`LI R1, 0`) | **0x00000093** |
| `ADDI R2, x0, #8` | **0x00800113** |
| `ADDI R2, R1, #1` | **0x00108113** |
| `ADD R4, R1, R13` | **0x00D08233** |
| `LDR R4, 0(R13)` | **0x0006A203** |
| `LDR R5, 8(R13)` | **0x0086A283** |
| `LDR R11, 4(R11)` | **0x0045A583** |
| `STR R6, 0(R1)` | **0x0060A023** |
| `STR R8, 8(R13)` | **0x0086A423** |
| `ADD R6, R4, R5` | **0x00520333** |
| `SUB R7, R13, R7` | **0x407683B3** |
| `DIV R6, R13, R2` | **0x0226C333** |
| `BLT R9, R2, LOOP`(偏移 −36 字节 = 往回 9 条) | **0xFC24CEE3** |
| `JAL R5, 12`(链接值 4) | **0x00C002EF** |
| `JALR x0, 0(R5)`(返回) | **0x00028067** |
| `JALR R7, 1(R6)`(目标 = `(R6+1) >>> 2`) | **0x001303E7** |
| `SLLI R2, R1, 3`(R1=6 → 48) | **0x00309113** |
| `SRLI R3, R2, 2`(48 → 12) | **0x00215193** |
| `SRAI R5, R4, 1`(R4=-8 → -4) | **0x40125293** |
| `SRL R10, R2, R7`(48 >> R7[4:0]) | **0x00715533** |
| `SRA R11, R4, R7`(-8 >>> R7[4:0]) | **0x407255B3** |
| `DIV R4, R1, R2` | **0x0220C233** |
| `DIVU R6, R1, R2` | **0x0220D333** |
| `REM R5, R1, R2` | **0x0220E2B3** |
| `REMU R7, R1, R2` | **0x0220F3B3** |
| `SLT R4, R1, R2` | **0x0020A233** |
| `SLTU R5, R1, R2` | **0x0020B2B3** |
| `SLTI R6, R1, #5` | **0x0050A313** |
| `SLTIU R7, R1, #-1`(即 `R1 < 0xFFFFFFFF` 无符号) | **0xFFF0B393** |
| `AND R4, R1, R2` | **0x0020F233** |
| `OR R5, R1, R2` | **0x0020E2B3** |
| `XOR R6, R1, R2` | **0x0020C333** |
| `ANDI R7, R1, #255` | **0x0FF0F393** |
| `ORI R8, R1, #15` | **0x00F0E413** |
| `XORI R9, R1, #-1`(=`NOT R9, R1`) | **0xFFF0C493** |
| `LUI R1, 0x12345` | **0x123450B7** |
| `AUIPC R2, 0x00000` | **0x00000117** |
| `AUIPC R5, 0x00001` | **0x00001297** |
| `JAL R3, 8`(链接值 = `PC+4`) | **0x008001EF** |
| `JAL R14, 8` | **0x0080076F** |
| `J x0, −8`(=`JAL x0, -8`,往回跳 2 条) | **0xFF9FF06F** |
| `RET` | **0x0000005B** |
| `NOP`(=`ADDI x0, x0, #0`) | **0x00000013** |

B 型“跳过下一条指令”(`offset = +8`)的六种条件编码(以 `R1, R2` 为例):

| 汇编 | 编码 |
| - | - |
| `BEQ R1, R2, 8` | **0x00208463** |
| `BNE R1, R2, 8` | **0x00209463** |
| `BLT R1, R2, 8` | **0x0020C463** |
| `BGE R1, R2, 8` | **0x0020D463** |
| `BLTU R1, R2, 8` | **0x0020E463** |
| `BGEU R1, R2, 8` | **0x0020F463** |

全 0 字(`0x00000000`)是**未分配 opcode**:硬件上无副作用(PC 仍 +1),但它**不是**推荐的 NOP 写法。

## 8. 汇编书写约定与常见坑

- 位序(高位 → 低位):R 型 `funct7 | rs2 | rs1 | funct3 | rd | opcode`,I 型 `imm12 | rs1 | funct3 | rd | opcode`,
  S 型 `imm[11:5] | rs2 | rs1 | funct3 | imm[4:0] | opcode`,U 型 `imm20 | rd | opcode`,
  J 型 `imm[20] | imm[10:1] | imm[11] | imm[19:12] | rd | opcode`;未用字段一律写 0。
- opcode 低两位固定是 `11`;新增指令优先用 RISC-V 保留的 custom 段(`0001011` / `0101011` / `1011011` / `1111011`)。
- 寄存器写法:`x0`(恒 0)、通用 `R1`–`R28`、只读 `%blockIdx` / `%blockDim` / `%threadIdx`(编码 29 / 30 / 31)。
  **`x0` 不能当普通寄存器**——写它等于没写、读它永远得 0;内核里存 `i` 这类值请用 `R13`/`R28` 等通用寄存器。
- `ADDI rd, rs1, #imm12`(符号扩展,范围 −2048 … 2047;`ADDI rd, x0, #imm` = `LI rd, #imm`)。
- 分支写 `Bcc rs1, rs2, offset`(B 型:`BEQ` `BNE` `BLT` `BGE` `BLTU` `BGEU`);`offset` 是**相对当前指令**的字节数
  (实际要求 4 的倍数;`8` = 跳过下一条,`−36` = 往回 9 条,`0` = 原地死循环)。
  换算:`offset = (目标指令下标 − 当前指令下标) × 4`。
- 跳转/调用写 `JAL rd, offset`(`offset` 同样是相对当前指令的字节数,要求 2 的倍数;`rd ← PC + 4`)。
  **无条件跳转**用 `JAL x0, offset`(伪指令 `J offset`)—— 不写任何寄存器,也不用 `x0` 做比较。
- 间接跳转/返回写 `JALR rd, imm(rs1)`:目标 = `rs1 + imm`(字节地址,需 4 字节对齐)。
  返回惯例是 `JALR x0, 0(ra)`;本项目还没有 ABI,自己先固定 `ra`(建议 `R1`)和 `sp`(建议 `R2`)。
- 取高位常量写 `LUI rd, imm20`(`rd = imm20 << 12`,立即数**无符号**);PC 相对地址写 `AUIPC rd, imm20`。
  组合出任意 32 位常量:`LUI rd, %hi(x)` + `ADDI rd, rd, #%lo(x)`。
- `PC` 相关量的单位是**字节**(`PC 字节地址 = 指令下标 × 4`):`JAL`/`JALR`/`AUIPC` 写进 rd 的值、B/J 型偏移都是字节量;
- 访存写 `LDR rd, imm(rs1)` / `STR rs2, imm(rs1)`(以及 `LB/LH/LBU/LHU`、`SB/SH`):
  地址是**字节地址** `rs1 + 符号扩展(imm12)`,偏移可以是负数(如 `-4(R1)`)——`LDR R1, -4(R2)` 读 `R2` 前一个字。
  **字节 0..3 属于字 0**,所以“下一个字”的偏移是 `+4`,不是 `+1`;`LDR`/`STR` 必须 4 字节对齐。
- 窄访问:`LB/LBU`(1 字节)、`LH/LHU`(2 字节)、`SB/SH` 的地址同样按字节算;例:`LB R1, 5(R2)` 取 `R2+5` 那个字节。
- 空操作写 `NOP`(= `ADDI x0, x0, #0`,`0x00000013`),不要再依赖全 0 字。
- 移位写 `SLLI/SRLI/SRAI rd, rs1, shamt`(shamt = 0 … 31,**不带 `#`**)或 `SLL/SRL/SRA rd, rs1, rs2`。
  移位量恒取低 5 位 (`mod 32`):`SLL rd, rs1, r` 里 `r = 33` 实际只移 1 位;
  `>>` 选 `SRL`(逻辑,无符号语义)还是 `SRA`(算术,有符号语义)**必须按 C 类型自己选**:
  `unsigned >>` 用 `SRL`,`int >>` 用 `SRA`。乘 2 的幂可以用 `SLLI` 代替 `MUL`。
- 测试目前直接写字面量,注意:
  - **必须正好 32 位** —— 多一位/少一位都会让字段整体错位(历史上就踩过这个坑);
  - 推荐按 `0b` + R 型 `7/5/5/3/5/7`、I 型 `12/5/3/5/7` 分段书写,并在行尾注明对应的汇编,便于 review。
- 反汇编下标(MSB-first,下标 = 31 − 位号):`opcode=[25:32]`、`rd=[20:25]`、`funct3=[17:20]`、`rs1=[12:17]`、`rs2=[7:12]`、`funct7=[0:7]`、`imm12=[0:12]`;
  B 型的立即数散在 `[0:1]`(`imm[12]`)、`[1:7]`(`imm[10:5]`)、`[20:24]`(`imm[4:1]`)、`[24:25]`(`imm[11]`)里;
  U 型立即数 = `[0:20]`;J 型立即数散在 `[0:1]`(`imm[20]`)、`[1:11]`(`imm[10:1]`)、`[11:12]`(`imm[11]`)、`[12:20]`(`imm[19:12]`)里。
- 目前**没有汇编器**:`test/helpers/format.py` 只提供反汇编(单向)。

## 9. 保留编码与未定义行为

| 情况 | 行为 |
| - | - |
| 未分配的 opcode | 控制信号全 0 ⇒ 等同 `NOP`,PC 仍 +1 |
| 已分配 opcode 里未分配的 `funct3` / `funct7`(例如 `LOAD` 的 funct3 ≠ `010`、`BRANCH` 的 funct3 = `010`/`011`) | 同上,等同 `NOP` |
| 向 `x0` 写(`rd = 0`) | 静默忽略(所以 `ADDI x0, ...` 真的无副作用) |
| 指令里未使用的字段非 0 | 被忽略(硬件只看它需要的切片;注意 `ADDI` 的 rs1 是**有效**字段;`LUI` 的 rs1/rs2/funct3 都属于立即数,不影响行为) |
| 向 `R29`–`R31` 写(`rd >= 29`) | 静默忽略,不产生写动作 |
| `DIV`/`DIVU` 且 `rs2 == 0` | 返回全 1(`−1` / `0xFFFFFFFF`),不再传播 `x`(2026-10 起对齐 RISC-V) |
| `REM`/`REMU` 且 `rs2 == 0` | 返回**被除数**(RISC-V 语义) |
| `DIV`/`REM` 且 `rs1 = INT_MIN, rs2 = −1` | 商回绕成 `INT_MIN`,余数 0(两补码除法溢出)。⚠️ 这是 Verilog 的**实现相关**行为:同一份 `rs_signed / operand_b` 在 Icarus 下回绕成 `0x80000000`、在 Verilator 下给 `0`,所以 `alu.sv` 显式判断 `dividend_is_min && divisor_is_minus1`,不依赖仿真器 |
| 读未初始化 / 越界的数据内存 | 测试的 `Memory` 是稀疏 `defaultdict(int)`,读到 0 |
| 分支目标超出程序长度 | 取到全 0(NOP)后继续顺序执行,不 trap |
| B/J 型偏移不是 4 的倍数 | 低两位被右移丢弃(硬件只取 `imm >>> 2`),等价于向下取整到 4 的倍数 |
| U/J 型没有 funct3/funct7 | 那几位就是立即数(`LUI`/`AUIPC`/`JAL` 的该 opcode 全空间都有定义,不存在“未分配 funct3”) |
| `JALR` 的 funct3 ≠ `000` | 该编码未分配,等同 `NOP`(`JALR` 是 I 型,有 funct3) |
| `JALR` 目标不是 4 的倍数 | 低两位被 `>>> 2` 丢弃(向下取整),不 trap(RISC-V 是 `& ~1` 后对齐异常) |
| 移位的 funct7 / imm[11:5] 不合法(如 `SLL` 的 funct7 ≠ 0、`SLLI` 的 imm[11:5] ≠ 0) | 该编码未分配,等同 `NOP` |
| 移位量 ≥ 32 | 硬件只取低 5 位(自动 `mod 32`);汇编器/编译器应当提前拒绝 |
| 访存宽度未分配(`LOAD`/`STORE` 的 funct3 = `011`/`110`/`111`) | 等同 `NOP`,不发内存请求 |
| 窄访问地址不对齐(如 `LH` 落在奇数地址) | **不 trap**:`lane` 直接取 `byte_address[1:0]`,跨字部分被丢(结果未定义;RISC-V 会报 misaligned 异常) |
| 字节地址超出自存宽度 | 高 30 位直接当字地址,无范围检查 |

## 10. 版本历史

| 项 | 16 位 ISA(旧) | 32 位 ISA(现在) |
| - | - | - |
| 指令宽度 | 16 位 | 32 位 |
| opcode | `[15:12]` | `[31:26]`;R-type 统一 `000000` + `funct[5:0]` |
| rd / rs / rt | `[11:8]` / `[7:4]` / `[3:0]`(各 4 位) | `[25:21]` / `[20:16]` / `[15:11]`(各 5 位) |
| 立即数 | `imm8 = [7:0]`(叠加在 rs/rt 上) | `imm16 = [15:0]`(连续字段) |
| nzp 掩码 | `[11:9]` | `rd[2:0] = [23:21]` |
| 寄存器数 | 16(`R0`–`R12` 通用,`R13/14/15` 只读) | 32(`R0`–`R28` 通用,`R29/30/31` 只读) |
| 分支目标 | 8 位绝对地址 | 16 位绝对地址 |

迁移时踩过 / 需要留意的点:

1. 测试字面量必须**正好 32 位**:旧的 33 字符写法直接搬过来会让 opcode 右移一位,`ADD` 变成 `DIV`,甚至触发除零 → `x`。
2. `CONST` / `BRnzp` 的立即数位置、`nzp` 的位置都变了,必须整体重编码。
3. `%blockIdx` / `%blockDim` / `%threadIdx` 的编号由 13 / 14 / 15 变为 29 / 30 / 31。
4. **NZP 语义修正(2026-10)**:`src/alu.sv` 原先写成 `(rs - rt > 0)` / `(rs - rt < 0)` 形式的比较,而操作数是无符号的,于是 `nzp[2]` 实际是"不相等"、`nzp[0]` 恒为 0;现已改为有符号比较(见第 5 节)。修正后 `BRn LOOP`(mask `100`)才真正表示"`k < N`",此前只是恰好等价于它。

### RISC-V 风格迁移(2026-10)

| 项 | 自定格式(上一步) | RISC-V 风格(现在) |
| - | - | - |
| opcode | `[31:26]`,R 型固定 `000000` + 6 位 funct | `[6:0]`(低两位固定 `11`),直接采用 RISC-V 标准 opcode |
| 寄存器字段 | rd `[25:21]`、rs `[20:16]`、rt `[15:11]` | rd `[11:7]`、rs1 `[19:15]`、rs2 `[24:20]` |
| 分派方式 | opcode + funct | opcode + funct3(+ funct7,仅 R 型) |
| 立即数 | `imm16 = [15:0]`,零扩展 | `imm12 = [31:20]`;`CONST` 符号扩展、`BRnzp` 零扩展 |
| nzp 掩码 | `rd[2:0]` = `[23:21]` | `funct3` = `[14:12]` |
| 访存指令 | 自定 R 型(`rd/rs/rt` 字段) | `LDR` → `lw`(I 型)、`STR` → `sw`(S 型);偏移当时为 0,2026-10 接入 |
| 分支目标 | 16 位绝对地址 | 12 位绝对地址(后续按 RISC-V 改 B 型相对偏移) |
| `DIV` | 无符号整除 | **有符号**整除(对齐 RISC-V `div`) |

迁移注意:

1. 立即数从 16 位缩到 12 位:受益是 `CONST` 现在支持负数(符号扩展);代价是 `BRnzp` 目标上限变成 4096 条指令。
2. 字面量需要全部重编码;`ADD/SUB/MUL/DIV/CONST/LDR/STR` 的编码现在与真实 RISC-V 逐位一致,可以直接用 RISC-V 工具链交叉验证。
3. `%blockIdx` / `%blockDim` / `%threadIdx` 仍是 29 / 30 / 31(与 RISC-V ABI 命名无关)。

### `x0` / `ADDI` / `NOP`(2026-10)

| 项 | 改动前 | 现在 |
| - | - | - |
| `R0` | 可写普通寄存器 | **`x0` 恒 0**(写被忽略、读恒 0) |
| 取常量 | `CONST rd, #imm12`(复用 `addi` 编码但忽略 rs1) | **`ADDI rd, rs1, #imm12`**(真加立即数;`LI` = rs1 取 x0) |
| NOP | 无独立编码,靠全 0 字 | **伪指令 `ADDI x0, x0, #0`**(`0x00000013`) |

影响:`decoder` 新增 `decoded_alu_imm_enable`;ALU 的 B 操作数多一个 2:1 mux(`rs2` / `imm12`);
寄存器堆跳过 `rd = 0` 的写入,并去掉了立即数写回通路(`decoded_reg_input_mux = 10` 现在保留);
两个内核把线程号 `i` 从 `R0` 换到 `R13`(`x0` 不能再存东西)。

### 访存偏移语义(2026-10)

| 项 | 改动前 | 现在 |
| - | - | - |
| `LDR` / `STR` | 地址 = `rs1`(imm 字段未接入数据通路) | **地址 = `rs1` + sign_ext(imm12)**(RISC-V `lw`/`sw`) |
| `STR` 的 S 型立即数 | 编码时恒为 0 | `imm[11:5]` + `imm[4:0]` 两段拼装,可用非 0 偏移 |

影响:`lsu.sv` 增加符号扩展与一个 32 位地址加法器(每线程一个);`decoder` 增加 S 型立即数拼装(12 位);
两个内核改用偏移寻址后分别少了 4 / 1 条指令,仿真时间从 4475 / 12300 µs 降到 3350 / 10100 µs。

### B 型条件分支与 NZP 的移除(2026-10)

| 项 | 改动前 | 现在 |
| - | - | - |
| 分支指令 | `CMP rs1, rs2` + `BRnzp mask, #target`(custom-1/custom-0,两条指令) | **`BEQ`/`BNE`/`BLT`/`BGE`/`BLTU`/`BGEU`**(RISC-V BRANCH `1100011`) |
| 比较 | 结果写进 3 位 NZP 寄存器,必须先 `CMP` 再 `BRnzp` | 分支指令内**直接比较 rs1/rs2**,当拍得出,无需前置指令 |
| 跳转目标 | 12 位**绝对**地址 | 13 位**PC 相对**字节偏移(`PC + (imm >>> 2)`) |
| 立即数位宽 | `decoded_immediate` 12 位 | **统一 13 位有符号**(I/S 型 sign_ext 到 13 位) |

影响:

1. `src/alu.sv` 删掉比较通路与 `decoded_alu_output_mux`,只剩 ADD/SUB/MUL/DIV。
2. `src/pc.sv` 删掉 NZP 寄存器,改为“有符号/无符号两个比较结果 + `case` 选条件”;
   PC 加法器的一个加数在 `imm >>> 2` 与 `1` 之间选择(纯接线,无新算术单元)。
3. `decoder` 删掉 `decoded_nzp` / `decoded_nzp_write_enable` / `decoded_alu_output_mux` / `decoded_pc_mux`,
   新增 `decoded_branch_enable` / `decoded_branch_cond`;custom-0 / custom-1 重新变回预留。
4. matmul 内核去掉 `CMP` + 换成 `BLT` 后从 22 条降到 21 条,仿真时间 10100 → 9550 µs。

### U 型与 J 型(2026-10)

| 项 | 改动前 | 现在 |
| - | - | - |
| 高位常量 | 没有,只能 `ADDI` 累加 | **`LUI rd, imm20`**(`0110111`)、`AUIPC rd, imm20`(`0010111`) |
| 无条件跳转 / 调用 | 只能用 `BEQ x0, x0, offset` 模拟 | **`JAL rd, offset`**(`1101111`,`rd ← PC+4`) |
| `decoded_immediate` | 13 位有符号 | **32 位**(I/S/B/J 符号扩展,U 左移 12 位),ALU/LSU/PC 不再各自做符号扩展 |
| 写回来源 | `reg_input_mux`:`00` ALU / `01` LSU | **新增 `10` = PC 单元结果**(`JAL` / `AUIPC` 用,即原来的保留编码) |

影响:

1. `decoder` 新增 `decoded_jump_enable`,新增 `JAL`/`LUI`/`AUIPC` 三个分支;`LUI` 靠把 `decoded_rs_address` 改成 0 复用 ADD
   (ALU 不变),`AUIPC`/`JAL` 只置 `reg_input_mux = 10`。
2. `pc.sv` 新增 `pc_result` 输出(`PC*4 + (JAL ? 4 : imm)`)并送入寄存器堆,PC 加法器的一个加数在 `imm>>>2`、`1` 之间选。
3. 立即数改成 32 位归一化后,`alu.sv`/`lsu.sv` 里的符号扩展代码全部删除(纯简化)。
4. 指令类型 R/I/S/B/U/J **六种齐全**;当时仍缺的 `JALR`(I 型)已在同一月补上,见下一节。

### JALR(I 型,2026-10)

| 项 | 改动前 | 现在 |
| - | - | - |
| 间接跳转 / 返回 | 没有;`JAL` 只能跳 PC 相对目标 | **`JALR rd, imm(rs1)`**(opcode `1100111`,funct3 `000`) |
| PC 单元的加法器 | 2 个:`next_pc`、`pc_result`(`PC_byte + {4, imm}`) | **仍是 2 个**:第二个改成 AUIPC(`PC_byte + imm`)与 JALR(`rs1 + imm`)共享;链接值 `(PC+1) << 2` 变成纯接线 |

影响:

1. `decoder` 新增 `decoded_jalr_enable`(只多 1 位控制信号,B 型/U/J 型的路径不变)。
2. `pc.sv` 的 A 端口多一个 2:1 mux(`PC_byte` / `rs1`),`next_pc` 前多一个目标 mux;**没有新增 32 位加法器**。
3. 调用/返回链路打通:`JAL ra, func` + `JALR x0, 0(ra)`。
   C 语言还缺:**字节/半字访存**、`SLT` 类,以及一套 ABI(栈指针、`ra`/参数用哪些寄存器);
   移位已在下一节补上。

### 移位指令(2026-10)

| 项 | 改动前 | 现在 |
| - | - | - |
| 移位 | 没有;C 的 `<<` 只能靠 `MUL` 乘 2 的幂模拟(`riscv2abyss.py` 里明确写着 “slli by more than 3 is not supported”,该脚本已删除) | **`SLL`/`SRL`/`SRA`(R 型)+ `SLLI`/`SRLI`/`SRAI`(I 型)** |
| ALU 操作码 | `decoded_alu_arithmetic_mux` 2 位(4 个操作) | **3 位**(7 个操作,`000`–`110`) |
| ALU 数据通路 | 加 / 减 / 乘 / 除 | 多一个 32 位**桶形移位器**(`<<` / `>>` / `>>>`) |

影响:

1. `decoder` 的 `OP` / `OP_IMM` 两个分支改成 `case (funct3)`:`001` = SLL/SLLI,`101` = SRL/SRA/SRLI/SRAI;
   后者靠 funct7(**I 型是 `imm[11:5]`**)区分逻辑/算术。
2. 移位量直接取 **B 操作数的低 5 位** —— R 型时 B = rs2,I 型时 B = 立即数(`decoded_alu_imm_enable` 已经切好),
   **没有新增 mux**。RISC-V 的 `mod 32` 语义因此天然成立(`SLL rd, rs1, r` 里 r = 33 只移 1 位)。
3. 操作码扩到 3 位 → `alu.sv` / `decoder.sv` / `core.sv` 三处同步;前 4 个操作的编码值保持不变。
4. 工具链:旧的 `tools/riscv2abyss.py`(已删除)删掉 `slli → MUL` 的 hack,`sll/srl/sra/slli/srli/srai` 现在直通;
   `start.s` 里为那个 hack 预置的三个常量(R23/R27/R28)可以删掉。
5. 代价:**每线程一个 32 位桶形移位器**(5 级 2:1 mux),这是本次唯一的实际面积开销。

### 除法家族补齐:DIVU / REM / REMU(2026-10)

| 项 | 改动前 | 现在 |
| - | - | - |
| 除法 | 只有 `DIV`(有符号商) | **`DIV`/`DIVU`/`REM`/`REMU`** 四条(`funct3` `100`–`111`,funct7 `0000001`) |
| 除零 | Verilog 的 `/0` 产生 `x`,写进 rd 后会扩散到整条数据通路 | 按 RISC-V:商返回全 1,余返回被除数 |
| ALU 操作码 | 3 位(7 个操作) | **4 位**(10 个操作,`0000`–`1001`) |
| 编译器侧 `%` | `DIV`+`MUL`+`SUB` 三指令模拟(R26 做 scratch) | 先仍是三指令模拟,`.td` 补齐后已改为直通(见下一小节) |

影响:

1. ⚠️ 踩到一个真实的 Verilog 坑:`alu_out_reg <= cond ? {N{1'b1}} : (rs_signed / operand_b);` 里
   因为一个分支是无符号字面量,整个条件表达式被当成**无符号**,`div` 静默变成了 `divu`
   (−7/2 得到 `0x7FFFFFFC`)。修法:先把四个结果算进各自 `signed`/无符号的中间 wire,再做 mux。
2. 操作码扩到 4 位 → `alu.sv` / `decoder.sv` / `core.sv` 同步;前 7 个操作的编码值保持不变。
3. 四条除/余指令共用同一个除法器(商与余数通常同时可用),新增面积很少。
4. 已验证:`−7/2 = −3`、`−7%2 = −1`、无符号 `0xFFFFFFF9/2 = 0x7FFFFFFC`、`0xFFFFFFF9%2 = 1`、
   四种除零情况、`INT_MIN / −1` 回绕。

### 字节寻址 + 字节/半字访存(2026-10)

| 项 | 改动前 | 现在 |
| - | - | - |
| 访存地址 | `rs1 + imm` 直接当**字**地址(LSU 不做转换) | **字节地址**:`word_address = byte_address >>> 2`,`lane = byte_address[1:0]` |
| 访存宽度 | 只有 32 位(`LDR`/`STR`) | **`LB`/`LH`/`LBU`/`LHU`/`SB`/`SH`**(`funct3` 选宽度,load 的 bit2 = 无符号) |
| 窄写 | — | LSU 把数据移进 lane,**`mem_write_mask[3:0]` 字节使能**一直传到内存接口;内存只改写选中的字节 |
| 窄读 | — | 先把 lane 移到低位,再按 `decoded_mem_unsigned` 做零扩展 / 符号扩展 |
| 内存接口 | 只有 `valid/address/data/ready` | 多了 `data_mem_write_mask`(`controller` 透传,`test/helpers/memory.py` 按位合并) |

影响:

1. ⚠️ **破坏性变更**:同一个立即数现在表示字节偏移 —— `LDR rd, 4(rs1)` 从“第 4 个字”变成“字节 4,即第 1 个字”。
   现有内核改用普通 C 指针，基址使用字节偏移。
2. `tools/abyss.h` 的宏改回真正的指针运算(`((int*)base)[idx]`,由编译器用 `SLLI` 缩放),
   头文件后来改为普通 C 指针 + `ABYSS_MATRIX` 类型宏，不再保留 `ABYSS_LD/ST` 之类宏。
3. C 语言现在可以做 `char`/`short` 和真正的字节指针演算;旧翻译器(已删除)曾新增 `lb/lh/lbu/lhu/sb/sh` 直通。
4. LSU 新增一组移位/掩码通路(读:lane 下移 + 扩展;写:数据上移 + 4 位掩码),每线程一份。

### 更名 + 手册迁址(2026-10)

| 项 | 改动前 | 现在 |
| - | - | - |
| ISA 名称 | "tiny-gpu 32-bit ISA" | **Abyss ISA** |
| 手册位置 | `isa/isa.md` | **`docs/isa.md`**(单一副本,不再维护两份) |

### LLVM 后端补齐除法 + C 除法测试(2026-10)

| 项 | 改动前 | 现在 |
| - | - | - |
| `AbyssInstrInfo.td` | 只有 `DIV`(`funct3 100`) | 补上 `DIVU`(`101`)、`REM`(`110`)、`REMU`(`111`),funct7 同为 `0000001` |
| `riscv2abyss.py` 的 `%`(脚本已删除) | 展开成 `DIV` + `MUL` + `SUB`(占 `R26`) | **直通 `REM`/`REMU`**;`R26` 释放 |
| C 侧测试 | 无 | **`test/div`**:一次跑完 `a/b`、`a%b`、`ua/ub`、`ua%ub` 和四种除零情况(32 个断言)
 |

要点:

1. 三条指令的编码与 RISC-V 逐位一致,`llvm-mc -arch=abyss --show-encoding` 可直接验:
   `DIV R4,R1,R2 = 0x0220C233`、`DIVU R6,R1,R2 = 0x0220D333`、
   `REM R5,R1,R2 = 0x0220E2B3`、`REMU R7,R1,R2 = 0x0220F3B3`。
2. ⚠️ 改完 `.td` 必须重跑 `ninja -C build llvm-mc`,否则汇编器仍报 "unrecognized
instruction mnemonic"。
3. ⚠️ 发现的 LLVM 行为:同一对操作数同时出现 `a / b` 和 `a % b` 时,**RISC-V 后端会把
它们折成 `div` + `mul` + `sub`**
   (`SDIVREM` 合并),根本不生成 `rem`。测试里用 `az = a + z`(`z` 是运行期 0)绕开,才能
真正覆盖 `REM`/`REMU`。
4. matmul 内核去掉 3 条模拟指令的其中一条后,仿真时间 11475 → 10925 µs。

### 比较指令补齐:`SLT` / `SLTU` / `SLTI` / `SLTIU`(2026-10)

| 项 | 改动前 | 现在 |
| - | - | - |
| 比较指令 | **没有**:比较只作为分支的条件存在,结果进不了寄存器 | **`SLT`/`SLTU`**(R 型 `funct3 010`/`011`)+ **`SLTI`/`SLTIU`**(I 型同 funct3) |
| ALU 操作码 | 4 位,10 个操作(`0000`–`1001`) | **仍是 4 位**,12 个操作(加 `1010` SLT / `1011` SLTU) |
| 写回通路 | — | **不变**:比较结果是 0/1,直接走 `reg_input_mux=00`(ALU) |
| 编译器侧 `<` | 展开成 `ADDI`+`BGE`+`ADDI`+`ADDI`(4~5 条,占 `R24`/`R25`) | **单条指令直通**;`R24`/`R25` 释放 |
| C 侧测试 | 无 | **`test/slt`**:符号/无符号、正/负立即数、相等情形共 24 个断言 |

影响:

1. `alu.sv` 只加了两个比较器(`rs_signed < operand_b`、`rs < operand_b_unsigned`)
   和两条 `case` 分支,结果零扩展成 32 位;**没有新增 mux、也没有新增写回来源**。
2. `decoder.sv` 的 `OP`/`OP_IMM` 两个 `case (funct3)` 各加两项(共 4 条指令)。
3. ⚠️ `SLTIU` 的立即数**符号扩展后当无符号**比较(RISC-V 语义):`SLTIU rd, rs1, #-1` 是
   `rs1 < 0xFFFFFFFF`。C 里 `0u < -1` 那种写法、以及 `x < 0xFFFFFFFFu`,都会编译成它。
4. 编码与 RISC-V 逐位一致:`SLT R4,R1,R2 = 0x0020A233`、`SLTU R5,R1,R2 = 0x0020B2B3`、
   `SLTI R6,R1,#5 = 0x0050A313`、`SLTIU R7,R1,#-1 = 0xFFF0B393`。
5. 至此 RISC-V **RV32I + M** 的整数部分只剩 `AND/OR/XOR` 与 `ANDI/ORI/XORI` 没做。

### 位运算补齐:`AND` / `OR` / `XOR` + 立即数版(2026-10)

| 项 | 改动前 | 现在 |
| - | - | - |
| 逻辑指令 | **没有**;`&`/`\|`/`^` 在翻译器里直接报 "unsupported" | **`AND`/`OR`/`XOR`**(R 型 `funct3 111/110/100`)+ **`ANDI`/`ORI`/`XORI`**(I 型同 funct3) |
| `funct3` 复用 | `100/110/111` 只给 `DIV`/`REM`/`REMU` 用 | **共用**:`funct7=0000000` 是逻辑运算,`0000001` 是除/余(和 RISC-V 一致) |
| ALU 操作码 | 4 位,12 个操作(`0000`–`1011`) | **仍是 4 位**,15 个操作(加 `1100` AND / `1101` OR / `1110` XOR) |
| 写回通路 | — | **不变**:仍走 `reg_input_mux=00` |
| 编译器侧 `&`/`\|`/`^` | 直接报错 | 直通;`andi sp, sp, -16` 的对齐 no-op 特例也删了(现在是真指令) |
| C 侧测试 | 无 | **`test/logic`**:`&`/`\|`/`^`、`ANDI #255`、`ORI #15`、`~a`(=`XORI #-1`)、`& -16`、位域提取,共 32 个断言 |

影响:

1. `alu.sv` 只加三条 `case` 分支(`rs & operand_b` 等),**没有新增硬件**。
2. `decoder.sv` 把原来的 `F3_DIV`/`F3_REM`/`F3_REMU` 三个 `case` 项合并成
   `F3_XOR`/`F3_OR`/`F3_AND`,内部再用 `funct7` 分流 —— 代码反而更短,也更贴近 RISC-V 的真实布局。
3. 旧翻译器(已删除)还顺便补了几个 clang 会产出的 RISC-V 伪指令:`zext.b`(→ `ANDI #255`)、
   `zext.h`(→ `SLLI 16` + `SRLI 16`)、`not`(→ `XORI #-1`)、`neg`(→ `SUB rd, x0, rs`)、
   `seqz`(→ `SLTIU #1`)、`snez`(→ `SLTU x0, rs`)。没有 `zext.b` 的话 `a & 0xFF` 直接编译不出来。
4. 编码与 RISC-V 逐位一致:`AND R4,R1,R2 = 0x0020F233`、`OR R5,R1,R2 = 0x0020E2B3`、
   `XOR R6,R1,R2 = 0x0020C333`、`ANDI R7,R1,#255 = 0x0FF0F393`、
   `ORI R8,R1,#15 = 0x00F0E413`、`XORI R9,R1,#-1 = 0xFFF0C493`。
5. 至此 **RV32I + M 的整数指令全部齐全**(除 `FENCE`/`ECALL`/`EBREAK` 这类系统指令)。

### SIMD 宽度:默认 8 lane,16 lane 可配置(2026-10)

| 项 | 默认(FPGA 现实) | 可选(仿真更快) |
| - | - | - |
| `THREADS_PER_BLOCK`(`gpu.sv`) | **8** | 16 |
| `DATA_MEM_NUM_CHANNELS` | **4** | 8(保持 2 线程/通道的比例) |
| 总 lane 数 | 4 core × 8 = **32** | 4 core × 16 = 64 |
| 测试 harness | 通道数从 `dut.data_mem_read_valid` 位宽推导,换宽度不用改 Python | 同左 |

为什么加宽能提速:整条流水线是**控制开销主导**的(每条指令约 6.4 拍,与 lane 数无关),
所以一次取指/译码喂的 lane 越多越划算。对固定线程数的内核:

$$\text{墙钟} \approx \frac{\text{线程数} / (\text{core 数} \times \text{lane 数}) \text{ 个 wave}}{\times\; (\text{像素数} / \text{线程数}) \text{ 次迭代}}$$

线程数 ≤ 64 时本来就只有 1 个 wave,加宽**不提速**,只是少占几个 core(并行度不变);
线程数 > 64 时 wave 数直接减半。

实测(全部用例通过):

| 用例 | 线程数 | 8 lane | 16 lane | 变化 |
| - | - | - | - | - |
| `raster128x128` | 128 | 7.34e9 ns | **3.68e9 ns** | **−50%**(4 wave → 2 wave) |
| `raster32x32` | 32 | 4.89e8 ns | 4.55e8 ns | −7%(只有 1 wave,收益来自通道翻倍) |
| `raster16x16` | 16 | 2.32e8 ns | 2.28e8 ns | −2% |
| `matadd`(4 线程) | 4 | 1.478e7 ns | 1.390e7 ns | −6% |
| `matmul`/`shift`/`mem`/`div`/`slt`/`logic` | 4~8 | 不变 | 不变 | 0 |

代价:每 core 的 ALU / LSU / 寄存器堆各翻一倍(寄存器堆 32 k → 64 k FF 总共)。

⚠️ **为什么最终又改回 8 lane**(2026-10-18 决定):

1. **面积**:16 lane 光寄存器堆就 64 k FF(4×16×32×32),4 个 core 加上控制逻辑已经贴到
   Zynq-7020(53 k LUT / 106 k FF)的上限;8 lane 只占一半。
2. **除法器才是真卡点**:`DIV`/`REM` 现在是**单拍组合除法器**,一个约 8~10 k LUT,
   32 lane 就已经放不下,更不用说 64 lane。上 FPGA 前必须先把热路径里的常量除法消掉。
3. 16 lane 的周期收益(−50%)是真的,但它换的是面积;仿真器的壁钟在 iverilog 下反而变长
   (每拍开销翻倍),换成 Verilator 后两者才能都体现出来。

## 11. 与 RTL 的对应关系

| 手册里的概念 | RTL 位置 |
| - | - |
| opcode / funct3 / funct7 分派、字段切片、控制信号 | `src/decoder.sv` |
| 寄存器堆(x0 恒 0、R1–R28 可写、只读 29/30/31) | `src/registers.sv` |
| 分支比较、PC 相对/寄存器间接跳转、`pc_result`(JAL/JALR/AUIPC 写回值)、PC 计算 | `src/pc.sv` |
| 算术运算、立即数选择(ADDI / LUI)、移位 | `src/alu.sv` |
| `LDR` / `STR` / 窄访存的异步请求、字节地址→字地址+lane、扩展/掩码 | `src/lsu.sv` + `src/controller.sv` |
| 8 态控制流 | `src/scheduler.sv` |
| block 分配与 `done` | `src/dispatch.sv` |
| 反汇编(调试日志) | `test/helpers/format.py` |

控制信号到数据通路的映射:

| 控制信号 | 取值 | 作用 |
| - | - | - |
| `decoded_reg_input_mux` | `00` ALU / `01` LSU / `10` PC 单元 | 选择写回 rd 的数据来源(`LUI` 用 `00`,`JAL`/`AUIPC` 用 `10`) |
| `decoded_alu_imm_enable` | `1` | ALU 的 B 操作数改用立即数(`ADDI` / `LUI`) |
| `decoded_alu_arithmetic_mux` | `0000` ADD / `0001` SUB / `0010` MUL / `0011` DIV / `0100` SLL / `0101` SRL / `0110` SRA / `0111` DIVU / `1000` REM / `1001` REMU / `1010` SLT / `1011` SLTU / `1100` AND / `1101` OR / `1110` XOR | ALU 运算选择(4 位;移位量取 B 操作数低 5 位) |
| `decoded_branch_enable` | `1` | PC 走分支逻辑(B 型) |
| `decoded_branch_cond` | `= funct3` | 选择分支条件(`000` BEQ / `001` BNE / `100` BLT / `101` BGE / `110` BLTU / `111` BGEU) |
| `decoded_jump_enable` | `1` | 无条件跳转 + 链接(`JAL`) |
| `decoded_jalr_enable` | `1` | 寄存器间接跳转 + 链接(`JALR`) |
| `decoded_mem_size` | `00` 字节 / `01` 半字 / `10` 字 | LSU 的访问宽度(选 lane 移位量与写掩码) |
| `decoded_mem_unsigned` | `1` | 窄 load 零扩展(`LBU`/`LHU`),0 = 符号扩展 |
| `decoded_ret` | `1` | 结束本 block(`RET`) |

## 12. 设计取舍与扩展预留

**与 RISC-V 的已知差异**(`x0` / `ADDI` / `LI`·`NOP` / 访存偏移 / B 型分支 / `LUI`·`AUIPC`·`JAL` 已在 2026-10 补齐):

| 差异 | 现状 | 补齐需要 |
| - | - | - |
| ~~无移位指令~~ | **2026-10 已补** `SLL/SRL/SRA` + `SLLI/SRLI/SRAI`(ALU 多一个 32 位桶形移位器) | — |
| 无 `JALR` | ~~只有直接跳转,没有间接跳转/返回~~ **2026-10 已补** | — |
| 无 ABI / 栈 | 有 `JAL`/`JALR`,但未约定 `ra`/`sp`/参数寄存器/栈布局 | 定 ABI + 编译器后端 |
| ~~无 `SLT`/`SLTI`/`SLTU`~~ | **2026-10 已补** `SLT`/`SLTU`/`SLTI`/`SLTIU`(ALU 直接出 0/1,写回仍走 `reg_input_mux=00`) | — |
| 无字节/半字访存与扩展加载 | ~~只有字的 `LDR`/`STR`~~ **2026-10 已补** `LB/LH/LBU/LHU/SB/SH` | — |
| 无 `FW`/`FLW` 等浮点访存 | 只有整数 | — |
| ~~无 `DIVU` / `REM`~~ | **2026-10 已补** `DIVU`/`REM`/`REMU`(除零也按 RISC-V 规则处理) | — |
| ~~数据内存按**字**寻址~~ | **2026-10 已改为字节寻址**(LSU 内做 `>>2` + lane 选择/掩码) | — |
| 无 `CSR` / 系统指令 | — | — |

**扩展方式**(新增指令):

1. 选一个未分配的 opcode,或 R 型里未分配的 `funct3`/`funct7`(优先 RISC-V 保留的 custom 段 `xx11`);
2. 在 `src/decoder.sv` 的 `case` 里加分支,置相应的控制信号;
3. 更新本手册第 2.2 / 4 / 7 节的表,以及 `test/helpers/format.py` 的反汇编表。

未分配编码等同 `NOP`,所以新增指令**不会破坏**已有程序。


