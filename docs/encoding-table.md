# RV32I encoding and control table

Your spec for the decoder and control unit (Week 4). Fill the encoding columns from the RISC-V
unprivileged spec (Chapter 2 and the RV32I opcode table). Fill the control columns with your own design:
rename, add or remove signals to match `rtl/control.sv`. A test that checks every row against your RTL
is the Week 4 checkpoint.

| Instr | Format | opcode | funct3 | funct7 | RegWrite | ALUSrc | ALUControl | ImmSrc | MemWrite | ResultSrc | Branch | Jump |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| LUI | U | | — | — | | | | | | | | |
| AUIPC | U | | — | — | | | | | | | | |
| JAL | J | | — | — | | | | | | | | |
| JALR | I | | | — | | | | | | | | |
| BEQ | B | | | — | | | | | | | | |
| BNE | B | | | — | | | | | | | | |
| BLT | B | | | — | | | | | | | | |
| BGE | B | | | — | | | | | | | | |
| BLTU | B | | | — | | | | | | | | |
| BGEU | B | | | — | | | | | | | | |
| LB | I | | | — | | | | | | | | |
| LH | I | | | — | | | | | | | | |
| LW | I | | | — | | | | | | | | |
| LBU | I | | | — | | | | | | | | |
| LHU | I | | | — | | | | | | | | |
| SB | S | | | — | | | | | | | | |
| SH | S | | | — | | | | | | | | |
| SW | S | | | — | | | | | | | | |
| ADDI | I | | | — | | | | | | | | |
| SLTI | I | | | — | | | | | | | | |
| SLTIU | I | | | — | | | | | | | | |
| XORI | I | | | — | | | | | | | | |
| ORI | I | | | — | | | | | | | | |
| ANDI | I | | | — | | | | | | | | |
| SLLI | I | | | | | | | | | | | |
| SRLI | I | | | | | | | | | | | |
| SRAI | I | | | | | | | | | | | |
| ADD | R | | | | | | | | | | | |
| SUB | R | | | | | | | | | | | |
| SLL | R | | | | | | | | | | | |
| SLT | R | | | | | | | | | | | |
| SLTU | R | | | | | | | | | | | |
| XOR | R | | | | | | | | | | | |
| SRL | R | | | | | | | | | | | |
| SRA | R | | | | | | | | | | | |
| OR | R | | | | | | | | | | | |
| AND | R | | | | | | | | | | | |
| FENCE | I | | | — | | | | | | | | |
| ECALL | I | | | — | | | | | | | | |
| EBREAK | I | | | — | | | | | | | | |
