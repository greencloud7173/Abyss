.text
.globl _start
_start:
  LUI R2, 0x1          ; sp = 0x1000 (word address)
  ADDI R23, x0, #8     ; constant used to lower slli by 3
  ADDI R27, x0, #2     ; slli by 1
  ADDI R28, x0, #4     ; slli by 2
  JAL R1, kernel
  RET
