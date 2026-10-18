.text
.globl _start
_start:
  LUI R2, 0x1          ; sp = 0x1000 (byte address)
  JAL R1, kernel
  RET
