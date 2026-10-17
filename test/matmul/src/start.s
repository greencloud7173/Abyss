.text
.globl _start
_start:
  LUI R2, 0x1          ; sp = 0x1000 (word address)
  ADDI R10, x0, #2     ; N = 2 (a0)
  JAL R1, kernel
  RET
