lupa's Lua refers to the C math functions without symbol versions, so it gets glibc's oldest ones: the SVID wrappers of log, log2 and fmod, not the versions the C++ engine imports.

The Lua port runs Lua 5.4.8 inside lupa 2.8. Its extension module lists `exp`, `log`, `log2`, `log10`, `pow`, `fmod`,
`sin`, ... as undefined symbols with no version (`objdump -T lua54.cpython-313-x86_64-linux-gnu.so`: `*UND* Base`),
and it does not link libm itself; the symbols resolve against the libm Python has loaded. For a reference without a
version, glibc's dynamic linker takes the symbol at version index 2, the library's oldest (GLIBC_2.2.5), even when that
is a hidden compatibility symbol (`check_match` in `elf/dl-lookup.c`). So Lua's `math.log` is `log@GLIBC_2.2.5`, the
SVID wrapper `w_log_compat.c`, where the C++ engine (built against glibc 2.39) calls `log@GLIBC_2.29`, the routine
itself. They differ where the wrapper steps in:

```
log(-1)            C++ engine fff8000000000000 (-nan)   Lua math.log  7ff8000000000000 (nan, __kernel_standard)
log2(-1)           fff8000000000000                     math.log(x, 2) 7ff8000000000000
fmod(qNaN, sNaN)   x's NaN, quieted (fmod@GLIBC_2.38)   math.fmod     y's NaN, quieted (fmod@GLIBC_2.2.5)
```

`log10` has only the old version, so there the two agree, and a first version of the runtime that "corrected" log10 of
a negative number to -nan was wrong: 4,990 of 20,016 test vectors differed in the NaN's sign. The fix is in
`lua/rt/crt.lua`: `Math_Log_d` and `Math_Log2_d` return -nan for a negative argument themselves, `LibM_fmod` returns
the NaN glibc 2.38's fmod returns before calling `math.fmod`, and `Math_Log10_d` calls `math.log(x, 10)` as it is.
`lua/test/run_libm_tests.sh` checks every function as the engine calls it against vectors from C programs linked
normally (so at the C++ engine's versions): 43,370,324 records, 0 differences.

The check to make for any interpreter that calls libm: which symbol version does the interpreter's binary or extension
import (`objdump -T`), and if none, which one does the dynamic linker pick. Perl's `perl` and `POSIX.so` import
versioned symbols (lesson 56's port), so the question did not come up there.
