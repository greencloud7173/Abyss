# tiny-gpu 32-bit ISA 手册

> 适用实现:`src/decoder.sv`、`src/registers.sv`、`src/pc.sv`、`src/alu.sv`、`src/lsu.sv`(2026-10 版本)
> 状态:`make test_matadd`、`make test_matmul` 均 PASS,iverilog 无位宽告警
> (已用临时用例逐条验证 B 型六种分支条件、`LUI`/`AUIPC`/`JAL` 的立即数与链接值)。
> **指令格式遵循 RISC-V**(字段位置、funct3/funct7 分派、opcode 低两位为 `11`、custom 段用官方保留编码);
> 本文描述**当前实现**的语义,与旧版本的差异见第 10 节。

---

## 1. 概览

- **定长 32 位指令**,格式与译码风格**对齐 RISC-V**;数据与地址 32 位;每个线程 32 个寄存器。
- **执行模型(SIMD)**:一个 core 处理一个 block;block 内 4 个线程(`THREADS_PER_BLOCK`)共享 1 个 fetcher + 1 个 decoder,
  但每个线程各有独立的 ALU、LSU、PC、寄存器堆 —— 同一拍所有线程执行同一条指令。
- **指令集**:16 条 —— R 型 4 条(`ADD` `SUB` `MUL` `DIV`)、I 型 2 条(`ADDI` `LDR`)、S 型 1 条(`STR`)、
  B 型 6 条(`BEQ` `BNE` `BLT` `BGE` `BLTU` `BGEU`)、U 型 2 条(`LUI` `AUIPC`)、J 型 1 条(`JAL`)、GPU 专用 1 条(`RET`)。
  除 `RET` 之外**全部与 RISC-V 官方编码逐位一致**(R/I/S/B/U/J 六种类型齐全)。
- **`x0` 恒 0**:`R0`(= `x0`)读恒为 0、写入被忽略(与 RISC-V 一致),因此**不能当普通寄存器用**。
- **伪指令**:`NOP` = `ADDI x0, x0, #0`(编码 `0x00000013`)、`LI rd, #imm` = `ADDI rd, x0, #imm`、
  `J offset` = `JAL x0, offset`;已经没有单独的 `NOP`/`CONST` 指令。
- **控制流**:条件分支是 RISC-V **B 型**(`PC + 符号扩展字节偏移`),无条件跳转/调用是 **J 型 `JAL`**,
  `AUIPC`/`JAL` 的写回值由 PC 单元产生;**没有 NZP 标志寄存器**;固定 8 个状态(第 6 节),
  不支持分支发散 —— 假设所有线程每步收敛到同一 PC。
- **译码取向**:所有字段都是**固定切片**;译码 = `case (opcode)`(R 型内再嵌 `case (funct3)` / `case (funct7)`),
  没有"按指令类型切换字段来源"的 mux。

## 2. 指令格式与指令类型

### 2.1 位域布局(与 RISC-V 相同)

```
      31         25 24        20 19             15 14             12 11              7 6               0
     ┌────────────┬────────┬────────┬────────┬────────┐
R 型 │   funct7   │  rs2     │        rs1     │     funct3     │      rd        │     opcode     │
     ├────────────┼────────┴────────┼────────┼────────┤
I 型 │          imm[11:0]     │        rs1     │     funct3     │      rd        │     opcode     │
     └──────────────────────────────┴────────┴────────┘
        7 位        5 位     5 位     3 位    5 位      7 位
```

S 型(只有 `STR` 使用):

```
      31        25 24    20 19    15 14    12 11     7 6        0
     ┌────────────┬────────┬────────┬────────┬────────┬──────────┐
S 型 │  imm[11:5] │  rs2   │  rs1   │ funct3 │imm[4:0]│  opcode  │
     └────────────┴────────┴────────┴────────┴────────┴──────────┘
```

B 型(六条条件分支):

```
      31  30      25 24    20 19    15 14    12 11     8 7   6        0
     ┌────┬──────────┬────────┬────────┬────────┬────────┬────┬─────────┐
B 型 │ 12 │ imm[10:5]│  rs2   │  rs1   │ funct3 │imm[4:1]│ 11 │ opcode  │
     └────┴──────────┴────────┴────────┴────────┴────────┴────┴─────────┘
```

U 型(`LUI` / `AUIPC`):

```
      31              12 11        7 6        0
     ┌─────────────────┬───────────┬──────────┐
U 型 │    imm[31:12]   │     rd    │  opcode  │
     └─────────────────┴───────────┴──────────┘
```

J 型(只有 `JAL`):

```
      31  30        21 20 19      12 11    7 6       0
     ┌────┬────────────┬───┬─────────┬───────┬────────┐
J 型 │ 20 │  imm[10:1] │11 │imm[19:12]│  rd   │ opcode │
     └────┴────────────┴───┴─────────┴───────┴────────┘
```

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
| R | `DIV` | `0110011` | `100` | `0000001` | `DIV rd, rs1, rs2` | rd, rs1, rs2 | `div`(M 扩展) |
| I | `LDR` | `0000011` | `010` | — | `LDR rd, imm(rs1)` | rd, rs1, imm12 偏移 | `lw rd, imm(rs1)` |
| S | `STR` | `0100011` | `010` | — | `STR rs2, imm(rs1)` | rs1=基址, rs2=数据, imm12 偏移 | `sw rs2, imm(rs1)` |
| I | `ADDI` | `0010011` | `000` | — | `ADDI rd, rs1, #imm12` | rd, rs1, imm12(符号扩展) | `addi` |
| B | `BEQ` | `1100011` | `000` | — | `BEQ rs1, rs2, offset` | rs1, rs2, imm13 字节偏移 | `beq` |
| B | `BNE` | `1100011` | `001` | — | `BNE rs1, rs2, offset` | 同上 | `bne` |
| B | `BLT` | `1100011` | `100` | — | `BLT rs1, rs2, offset` | 同上(有符号比较) | `blt` |
| B | `BGE` | `1100011` | `101` | — | `BGE rs1, rs2, offset` | 同上(有符号比较) | `bge` |
| B | `BLTU` | `1100011` | `110` | — | `BLTU rs1, rs2, offset` | 同上(无符号比较) | `bltu` |
| B | `BGEU` | `1100011` | `111` | — | `BGEU rs1, rs2, offset` | 同上(无符号比较) | `bgeu` |
| U | `LUI` | `0110111` | — | — | `LUI rd, imm20` | rd,imm20(写入 `imm20<<12`) | `lui` |
| U | `AUIPC` | `0010111` | — | — | `AUIPC rd, imm20` | rd,imm20(写入 `PC + imm20<<12`) | `auipc` |
| J | `JAL` | `1101111` | — | — | `JAL rd, offset` | rd,imm21(链接值 `PC+4`) | `jal` |
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
| `100` | `0000001` | `DIV` | `DIV rd, rs1, rs2` | `rd ← rs1 ÷ rs2`(**有符号**,向零取整) | `reg_write=1`,`reg_input_mux=00`,`alu_mux=11` |

`ADD`/`SUB`/`MUL`/`DIV` 的编码与 RISC-V 官方一致(含 M 扩展的 `funct7=0000001`)。

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

### 4.3 U 型与 J 型(高位立即数 / 跳转)

| opcode | 指令 | 语法 | 操作 | 关键控制信号 |
| - | - | - | - | - |
| `0110111` | `LUI` | `LUI rd, imm20` | `rd ← imm20 << 12`(低 12 位为 0) | `reg_write=1`,`reg_input_mux=00`,`alu_mux=00`(ADD),`alu_imm_enable=1`,rs1 被强指为 `x0` |
| `0010111` | `AUIPC` | `AUIPC rd, imm20` | `rd ← PC + (imm20 << 12)` | `reg_write=1`,`reg_input_mux=10`(PC 单元算值) |
| `1101111` | `JAL` | `JAL rd, offset` | `rd ← PC + 4`;`PC ← PC + (offset >>> 2)` | `reg_write=1`,`reg_input_mux=10`,`jump_enable=1` |

- `LUI` 复用 ALU 的 ADD:**把 rs1 地址强指成 `x0`**(=0),B 操作数用立即数,于是 `0 + (imm20 << 12)`。
  没有新增 ALU 运算,也没有新增 mux —— 只需 decoder 把 `decoded_rs_address` 改成 0。
- `AUIPC`/`JAL` 的写回值不是 ALU 结果,而是 **PC 单元算出来的值**(`reg_input_mux = 10`,即原来空着的编码):
  `JAL` 是 `PC + 4`,`AUIPC` 是 `PC + (imm20 << 12)`;两者共用 PC 单元里“`PC_byte + 加数`”那个加法器,
  加数在常数 `4`(JAL)与立即数(AUIPC)之间选。
- **PC 表示“第几条指令”,而 PC 相关量按 RISC-V 语义是字节地址**:`PC_byte = current_pc * 4`;`*4` 与 `>>> 2` 都只是接线。
- `offset` 相对**当前**指令:`8` = 跳过下一条,`-8` = 往回一条(必须是 2 的倍数)。
- `rd = x0` 时写入被忽略 ⇒ **`JAL x0, offset` 就是无条件跳转**(伪指令 `J offset`);
  `JAL ra, offset` 是调用,链接值 = 下一条指令的字节地址(将来配 `JALR` 就能实现返回)。
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
| `0000011` | `010` | `LDR` | `LDR rd, imm(rs1)` | `rd ← mem[rs1 + 符号扩展(imm12)]`(异步) | `reg_write=1`,`reg_input_mux=01`,`mem_read_enable=1` |
| `0100011` | `010` | `STR` | `STR rs2, imm(rs1)` | `mem[rs1 + 符号扩展(imm12)] ← rs2`(异步) | `mem_write_enable=1` |

- `ADDI` 把 ALU 的 B 操作数从 `rs2` 切到符号扩展后的 `imm12`(`decoded_alu_imm_enable`,ALU 内部一个 2:1 mux),运算仍是 ADD。
  `ADDI rd, x0, #imm` 就是伪指令 `LI rd, #imm`;`ADDI x0, x0, #0` 就是 `NOP`(写入 x0 被忽略,所以真的什么都不做)。
- `LDR`/`STR` 是 RISC-V 的**偏移寻址**:有效地址 = `rs1 + 符号扩展(imm12)`,加法在 LSU 里做(每线程一个 32 位加法器)。
  偏移为 0 时就退化成“寄存器里的地址”;要算下标用 `ADD`/`ADDI`。
- `STR` 是 S 型,偏移被拆到 `[31:25]`/`[11:7]` 两段,`decoder` 在 `STORE` 分支里拼成 12 位再送给 LSU。
- 立即数范围:`ADDI` 与 `LDR`/`STR` 偏移为 −2048 … 2047(符号扩展);B 型字节偏移为 −4096 … +4094(且必须是 4 的倍数)。
- `DIV` 的除数 `rs2` 为 0 时结果为 `x`(见第 9 节);除零、`INT_MIN / -1` 都**未**按 RISC-V 规则特判。

### 4.6 每条指令的执行阶段

| 指令 | 读寄存器 | 计算 / 访存 | 写回 |
| - | - | - | - |
| `ADD` `SUB` `MUL` `DIV` | `REQUEST` 采样 rs、rt | `EXECUTE` ALU 运算 | `UPDATE` 写 rd |
| `LDR` | `REQUEST` 采样 rs1(基址) | 地址 = rs1 + imm;`REQUEST` 发起读,`WAIT` 等应答 | `UPDATE` 写 rd |
| `STR` | `REQUEST` 采样 rs1(基址)、rs2(数据) | 地址 = rs1 + imm;`REQUEST` 发起写,`WAIT` 等应答 | — |
| `ADDI` | `REQUEST` 采样 rs1 | `EXECUTE` ALU 加立即数 | `UPDATE` 写 rd |
| `LUI` | 无需读(rs1 强指 `x0`) | `EXECUTE` ALU 加 `imm20<<12` | `UPDATE` 写 rd |
| `AUIPC` | — | `EXECUTE` PC 单元算 `PC + imm` | `UPDATE` 写 rd |
| `JAL` | — | `EXECUTE` 算目标 PC | `UPDATE` 写 rd(链接值)**并**改 PC |
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
- **`AUIPC` 不改变控制流**(`PC ← PC + 1`),只把 `PC + (imm20<<12)` 写进 rd;
  它与 `JAL` 都用 `reg_input_mux = 10` 从 PC 单元写回(PC 单元里加数在常数 `4` 与立即数之间选)。
- `JAL` / `AUIPC` 写入的 rd 值是 **字节地址**(PC × 4);与 B/J 型偏移保持同一套“PC 相关量按字节计”的约定。
- 分支与比较是同一条指令 ⇒ 条件跳转**不再需要**“标志位先由另一条指令写入”(旧的 `CMP` + `BRnzp` 要隔一条)。
- 实现细节(`src/pc.sv`):`rs_signed < rt_signed`(有符号)与 `rs < rt`(无符号)两个比较结果 + 一个 `case` 选条件;
  `>>> 2`、`PC*4` 与符号扩展都是接线,没有额外算术逻辑。
- 无分支发散:一个 block 的 4 个线程各算各的条件,实际 PC 取**最后一个线程**的值
  (`current_pc <= next_pc[THREADS_PER_BLOCK-1]`),所以内核里要保持各线程控制流一致。

## 6. 执行模型与流水阶段

每个 core 的状态机(`src/scheduler.sv`)固定 8 态,block 内所有线程同步前进:

| core_state | 名称 | 本拍发生的事 |
| - | - | - |
| `000` | IDLE | 等 `start`(dispatcher 分配 block) |
| `001` | FETCH | fetcher 读取 `instruction[current_pc]` |
| `010` | DECODE | decoder 锁存字段、产生控制信号 |
| `011` | REQUEST | 寄存器堆采样 `rs`/`rt`;`LDR`/`STR` 在此发起内存请求 |
| `100` | WAIT | 若有 LSU 处于 REQUESTING/WAITING 就继续等待(内存延迟) |
| `101` | EXECUTE | ALU 运算 / 比较;PC 单元算分支、跳转与 `pc_result` |
| `110` | UPDATE | 写回 rd(ALU / LSU / PC 单元三种来源)、更新 PC |
| `111` | DONE | 本 block 结束(遇到 `RET`) |

写汇编 / 看波形时要记住的几条:

1. 每条指令都走完整流程(`LDR`/`STR` 的 `WAIT` 因内存延迟更长),因此相邻指令之间天然隔开约 5 拍。
2. `rs`/`rt` 在 `REQUEST` 采样 —— 指令用的是"它到达 REQUEST 那一刻"的寄存器值,**紧邻的写后读依赖也安全**。
3. `WAIT` 会等到**所有**线程的 LSU 都不在 REQUESTING/WAITING 才进 `EXECUTE`(SIMD 锁步)。
4. 只在 `UPDATE` 写:运算类 / `LDR` / `LUI` / `AUIPC` / `JAL` 写 rd,分支与跳转改 PC;`STR` 不写寄存器。
5. 分支在 `EXECUTE` 比较、在 `UPDATE` 改 PC;分支自己就带比较,不需要任何前置比较指令。
6. 无分支发散:`current_pc <= next_pc[THREADS_PER_BLOCK-1]`,即取最后一个线程的下一 PC;要求各线程每步收敛到同一 PC。
7. 每个 block 的 PC 从 0 开始;`RET` 后 core 被 dispatcher 复位并接收下一个 block。

## 7. 编码速查

```
R 型:instr = (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode
I 型:instr = (imm12  << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode
S 型:instr = (imm[11:5] << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (imm[4:0] << 7) | opcode
B 型:instr = (imm[12] << 31) | (imm[10:5] << 25) | (rs2 << 20) | (rs1 << 15)
              | (funct3 << 12) | (imm[4:1] << 8) | (imm[11] << 7) | opcode
U 型:instr = (imm20 << 12) | (rd << 7) | opcode
J 型:instr = (imm[20] << 31) | (imm[10:1] << 21) | (imm[11] << 20) | (imm[19:12] << 12) | (rd << 7) | opcode
```

(完整分配见 [2.2 指令类型总表](#22-指令类型总表完整)。)

本 ISA 与真实 RISC-V 的重合情况(这几条可以直接用 RISC-V 汇编器/反汇编器验证):

| 本 ISA | 等价 RISC-V | 是否逐位相同 |
| - | - | - |
| `ADD/SUB/MUL/DIV` | `add/sub/mul/div` | ✅(含 M 扩展 funct7) |
| `ADDI rd, rs1, #imm` | `addi rd, rs1, imm` | ✅ |
| `LDR rd, imm(rs1)` | `lw rd, imm(rs1)` | ✅ |
| `STR rs2, imm(rs1)` | `sw rs2, imm(rs1)` | ✅ |
| `BEQ/BNE/BLT/BGE/BLTU/BGEU` | `beq/bne/blt/bge/bltu/bgeu` | ✅ |
| `LUI rd, imm20` | `lui rd, imm20` | ✅ |
| `AUIPC rd, imm20` | `auipc rd, imm20` | ✅ |
| `JAL rd, offset` | `jal rd, offset` | ✅ |
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
| `BLT R9, R2, LOOP`(偏移 −36 字节 = 往回 9 条) | **0xFC24EEE3** |
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
- 取高位常量写 `LUI rd, imm20`(`rd = imm20 << 12`,立即数**无符号**);PC 相对地址写 `AUIPC rd, imm20`。
  组合出任意 32 位常量:`LUI rd, %hi(x)` + `ADDI rd, rd, #%lo(x)`。
- `PC` 相关量的单位是**字节**(`PC 字节地址 = 指令下标 × 4`):`JAL`/`AUIPC` 写进 rd 的值、非法 B/J 型偏移都是字节量;
- 访存写 `LDR rd, imm(rs1)` / `STR rs2, imm(rs1)`:有效地址 = `rs1 + 符号扩展(imm12)`,偏移可以是负数(如 `-4(R1)`)。
- 空操作写 `NOP`(= `ADDI x0, x0, #0`,`0x00000013`),不要再依赖全 0 字。
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
| `DIV` 且 `rs2 == 0` | `rs1 / 0` 在 Verilog 里是 `x`,会写进 rd 并向外扩散(曾让测试崩在 `int('XX...', 2)`);RISC-V 规定 `div` 除零返回 −1,本实现**未**实现该规则 |
| 读未初始化 / 越界的数据内存 | 测试的 `Memory` 是稀疏 `defaultdict(int)`,读到 0 |
| 分支目标超出程序长度 | 取到全 0(NOP)后继续顺序执行,不 trap |
| B/J 型偏移不是 4 的倍数 | 低两位被右移丢弃(硬件只取 `imm >>> 2`),等价于向下取整到 4 的倍数 |
| U/J 型没有 funct3/funct7 | 那几位就是立即数(`LUI`/`AUIPC`/`JAL` 的该 opcode 全空间都有定义,不存在“未分配 funct3”) |

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
4. 指令类型 R/I/S/B/U/J **六种齐全**;仍缺的是 `JALR`(I 型) 与移位/`SLT` 类。

## 11. 与 RTL 的对应关系

| 手册里的概念 | RTL 位置 |
| - | - |
| opcode / funct3 / funct7 分派、字段切片、控制信号 | `src/decoder.sv` |
| 寄存器堆(x0 恒 0、R1–R28 可写、只读 29/30/31) | `src/registers.sv` |
| 分支比较、PC 相对跳转、`pc_result`(JAL/AUIPC 写回值)、PC 计算 | `src/pc.sv` |
| 算术运算、立即数选择(ADDI / LUI) | `src/alu.sv` |
| `LDR` / `STR` 的异步请求与 `rs1 + imm` 地址加法 | `src/lsu.sv` + `src/controller.sv` |
| 8 态控制流 | `src/scheduler.sv` |
| block 分配与 `done` | `src/dispatch.sv` |
| 反汇编(调试日志) | `test/helpers/format.py` |

控制信号到数据通路的映射:

| 控制信号 | 取值 | 作用 |
| - | - | - |
| `decoded_reg_input_mux` | `00` ALU / `01` LSU / `10` PC 单元 | 选择写回 rd 的数据来源(`LUI` 用 `00`,`JAL`/`AUIPC` 用 `10`) |
| `decoded_alu_imm_enable` | `1` | ALU 的 B 操作数改用立即数(`ADDI` / `LUI`) |
| `decoded_alu_arithmetic_mux` | `00` ADD / `01` SUB / `10` MUL / `11` DIV | ALU 运算选择 |
| `decoded_branch_enable` | `1` | PC 走分支逻辑(B 型) |
| `decoded_branch_cond` | `= funct3` | 选择分支条件(`000` BEQ / `001` BNE / `100` BLT / `101` BGE / `110` BLTU / `111` BGEU) |
| `decoded_jump_enable` | `1` | 无条件跳转 + 链接(`JAL`) |
| `decoded_ret` | `1` | 结束本 block(`RET`) |

## 12. 设计取舍与扩展预留

**与 RISC-V 的已知差异**(`x0` / `ADDI` / `LI`·`NOP` / 访存偏移 / B 型分支 / `LUI`·`AUIPC`·`JAL` 已在 2026-10 补齐):

| 差异 | 现状 | 补齐需要 |
| - | - | - |
| 无移位指令 | 缺 `SLL`/`SRL`/`SRA`(RISC-V OP 的 funct3 `001`/`101`) | 移位器(译码只需 funct3) |
| 无 `JALR` | 只有直接跳转,没有间接跳转/返回 | I 型 `1100111`:把 ALU 结果接到 PC 单元作为跳转目标 |
| 无 `SLT`/`SLTI`/`SLTU` | 比较结果只用于分支,不进寄存器 | ALU 比较结果写回通路(mux 已够用,`reg_input_mux` 还有空余) |
| 无字节/半字访存与扩展加载 | 只有字的 `LDR`/`STR` | `LB`/`LH`/`LBU`/`LHU` 与写回扩展 mux |
| 无 `DIVU` / `REM` | 只有有符号 `DIV` | ALU 再加一条运算(OP 的 funct3 `101` 空着) |
| 数据内存按**字**寻址、PC 相关量按**字节** | `LDR rd, 4(rs1)` 是“第 4 个字+rs1”;`JAL`/`AUIPC` 的值是字节地址 | 字节寻址的数据内存(改 LSU 与测试内存模型) |
| 无 `CSR` / 系统指令 | — | — |

**扩展方式**(新增指令):

1. 选一个未分配的 opcode,或 R 型里未分配的 `funct3`/`funct7`(优先 RISC-V 保留的 custom 段 `xx11`);
2. 在 `src/decoder.sv` 的 `case` 里加分支,置相应的控制信号;
3. 更新本手册第 2.2 / 4 / 7 节的表,以及 `test/helpers/format.py` 的反汇编表。

未分配编码等同 `NOP`,所以新增指令**不会破坏**已有程序。


