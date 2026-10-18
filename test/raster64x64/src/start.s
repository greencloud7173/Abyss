.text
.globl _start
_start:
  LUI R2, 0x1000       ; sp = 16 MiB, above every framebuffer
  JAL R1, kernel
  RET
