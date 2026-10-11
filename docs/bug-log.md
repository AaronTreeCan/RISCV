# Bug log

Log every bug that took more than 15 minutes. When an interviewer asks "tell me about a hard bug",
this is where the answer comes from, with real signal names and cycle numbers.

| Date | Block | Symptom | How I found it | Root cause | Fix | Lesson |
| --- | --- | --- | --- | --- | --- | --- |
| | | | | | | |

<!-- Example of the detail level that makes a good entry:
| 2026-10-20 | alu | SLT returned 0 for -1 < 1 | Waveform: a_i = 0xFFFFFFFF, b_i = 0x1, result 0 | Compared as unsigned; operands not declared signed | Used $signed() in the SLT case | Signedness is per-expression in SV; test SLT and SLTU with 0x80000000 |
-->
