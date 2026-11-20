# The OpenSWMM 6 1D engine in Mojo, byte for byte

A translation of the 1D engine of OpenSWMM 6 (HydroCouple/openswmm.engine, branch `swmm6_rel`, commit 88329d6) into
Mojo, held to the same output as the C++ engine: the same binary `.out` file and the same `.rpt` report, apart from
the three clock lines. It is a translation checked against SWMM6, not SWMM6 and not a HydroCouple or EPA release.

## Result

**480 of 480 models byte-identical** against the C++ reference engine built from the same commit and run on one
thread, on the 480-model gate set the SWMM5 ports were checked on, drawn from 1729-SWMM5-Models-2030: run `mojo6_c01`
(commit 2177bf9), 585 s of engine time in all, a median of 0.11 s per model, the slowest
`EPA/72_H&H_Elements(2).inp` (107 s) and `Hydrology/SCANLON.inp` (69 s). The C++ reference took 476 s for the same
480 models (`gate/ref_outputs/*/sec`).

**452 of 452 extra decks byte-identical**: SWMM6's own tests (the input files in the upstream repository's `tests`
folder at 88329d6) and the synthetic decks of swmm6-rust's gate. Run `mojo6_x01` (commit 2177bf9) passed 451, 620 s
of engine time, a median of 0.06 s per deck, the slowest `refactored_small.inp` (249 s) and `legacy_small.inp`
(247 s). The other deck, `et_SIGMA_dry.inp`, stopped 0.047 s after it started with "cannot map the runtime's state
block": Mojo's runtime reserves 1 GB of address space at a random place before `main` runs, and this once it covered
one of the two fixed addresses where the port keeps its static fields and its runtime state (`../lessons/79`). The
runtime now starts the program again when that happens (tested by taking the address on purpose), and the deck
passed in run `mojo6_x02` (commit fcdf3bf, 1 of 1).

**The checked build: 480 of 480 and 452 of 452.** The same sources built with `CHECKED=1 NAME=openswmm_checked
mojo/build.sh` (commit 8215ca3; runs `mojo6_k01`, 628 s of engine time, and `mojo6_kx01`, 704 s), in which every index
into a C# array (`Ary[T]` of `rt/core.mojo`, the arrays of the generated engine) is checked against the array's length
and a wrong one stops the run with "array index out of range" (a `std::vector`'s elements are reached through its
backing array, so an index into a vector is checked against its capacity, not its size). No run stopped. Both builds
keep Mojo's own "safe" assertions, which are on by default: the bounds of `List` and `Span` indices in the runtime (a
`List` index out of range stops the program with "Assert Error: index ... is out of bounds"). Neither checks a raw
pointer (C#'s `T*` and `ref`, the runtime's `CPtr`), the runtime stack's own bound aside. `-D ASSERT=all`, which turns
on the rest of Mojo's debug assertions, did not build within the memory limits of this machine (the compiler stopped
at a 4.5 GB address-space cap), and the checked build of the last commit (fcdf3bf) was stopped by the build's memory
watchdog at 1.8 GB resident; the checked runs are of commit 8215ca3, whose engine differs from the last commit's only
in the start-up fix of lesson 79.

**The independent rerun: 480 of 480 and 452 of 452.** A clean copy of commit fcdf3bf (`git archive`) in memory, where
the translator was rebuilt, the engine regenerated from `cs/gen` (`engine.mojo` and the translator's two reports
byte-identical to the committed ones), the one generated runtime file written again (`rt/primes.mojo`,
byte-identical) and the engine built by `mojo/build.sh` with an empty Mojo cache (no fused multiply-add instruction in
the binary; `results/mojo6_v_build.txt`, `gate/rerun_build.sh`). That copy was gated as it was, on all the models:
runs `mojo6_v1` (480 of 480, 553 s) and `mojo6_vx` (452 of 452, 610 s). Every status and every `.out` and `.rpt` hash
equals the first runs' (`gate/compare_rerun.py`, `results/mojo6_v_compare.txt`: 932 equal, 0 different).

**The main session's check: 48 of 48 and 12 of 12.** A clean `git clone` of commit 2403b2e (in memory), where the
translator was rebuilt and the engine and `rt/primes.mojo` regenerated (no file changed: `git status` empty), and the
engine built with `mojo/build.sh` and an empty Mojo cache of its own under a memory watchdog (4 min 28 s, 1,563 MiB
resident at most, against a limit of 1,800; `objdump -d` finds no fused multiply-add instruction), then gated: run
`mojo6_main` on 45 corpus models drawn at random (`random.Random(20261110)`) plus `Hydrology/save_rtk_long.inp`,
`one_sub_one_rdii_node.inp` and `Use_SeasonalRDIIn.inp`, the decks that SAVE and USE `cho.txt` (48 of 48; 29 s), and
run `mojo6_main_x` on 12 extra decks drawn the same way (12 of 12; 0.8 s); the same samples as the other ports'
checks. Ids in `gate/ids_main_check.txt` and `gate/ids_main_check_extra.txt`.

After all the runs `Hydrology/cho.txt` is 1,114,474 bytes, md5 5b0ca1fe78588202fa779dbfa417b089.

## How it was made

The C++ engine was translated to C# first (`cs/gen`, 480 of 480), and this engine is translated from that C#, not
from the C++, by a translator written for it: `tools/cs2x/Cs2Mojo.cs`, `MojoFn.cs` and `MojoExpr.cs` (2,572 lines),
which read the C# (`cs/gen`, and the engine's hand-written partial classes `cs/runtime/Hand_*.cs`) through Roslyn's
semantic model and print one Mojo module, `gen/engine.mojo` (169,407 lines: 13,621 functions and 1,035 structs). The
translator began as a copy of the Zig back end, so the analysis and the runtime names are the Zig port's. The mapping
is in `tools/cs2x/MOJO.md`; every runtime name the engine uses is listed in `cs2mojo_runtime.txt`, and the constructs
left untranslated in `cs2mojo_todo.txt` (none).

Mojo 1.2 has no classes, no global variables, no function values in struct fields, no `switch` or `goto`, and it
treats a `mut` argument as unaliased, so the translation stands on a few devices (MOJO.md): a class is a struct
reached through `Ref[T]`, a raw pointer, with its base as its first field and a type id for `is`, `as` and `catch`;
the static fields are one struct mapped at a fixed address; a delegate is a context pointer and a number, called
through a generated dispatcher for each signature; a C# `ref` is a raw pointer, and a local whose address is taken
lives on a stack the runtime keeps itself (`../lessons/74`); exceptions are Mojo's `raises`, carrying a C++ exception
object kept in the runtime. Objects are collected by the Boehm collector (`libgc.so.1`).

The runtime (`rt/`, 9,576 lines of Mojo) is the part of the C++ standard library and of the C library that the engine
calls: vectors, maps and sets with libstdc++'s hash-table node order and growth, strings, iterators, introsort step for
step, glibc's printf (every digit computed exactly, with glibc's `%#g` and `%a` behaviour) and sscanf (with glibc's
rules for EOF, `%n`, scan sets, and its reading of `nan`, `inf` and `0x`), strtod, stdio files, iostreams and the file
system as the C# port has them. `rt/crt.mojo` began as the SWMM5 Mojo port's runtime (swmm5-ports,
`mojo/swmm5/rt.mojo`).
Only `rt/primes.mojo` (libstdc++'s bucket counts) is written by a script (`make_primes.sh`). `main.mojo` is the
command line (`src/cli/main.cpp`, by way of the C# port's `Program.cs`). Nothing calls another port's engine or runtime.

The math is glibc's own: `rt/core.mojo` (343 lines of math) calls `exp`, `log`, `pow`, `log2`, `sin`, `cos`, `tan`,
`asin`, `acos`, `atan`, `atan2`, `log10`, `sinh`, `cosh`, `tanh`, `cbrt`, `expm1`, `log1p`, `hypot`, `fmod`,
`remainder`, `nextafter`, `floor`, `ceil`, `trunc`, `round` and `sqrt` through `external_call`, at the symbol versions
the C++ engine imports (`exp`, `log`, `pow` and `log2` at GLIBC_2.29, `hypot` at GLIBC_2.35, `fmod` at GLIBC_2.38, the
rest at GLIBC_2.2.5), each behind a function Mojo may not inline. The engine is built with `--fp-mode contract=off`
(Mojo fuses `a*b+c` by default) and `--target-cpu x86-64`; `objdump -d` finds no fused multiply-add instruction in the
binary.

Three things about the compiler shaped the build. A C++ `char buffer[1 << 16]{}`, which the C# keeps as an initializer
of 65,536 zeros, kept Mojo busy for hours as one variadic call; long zero initializers are now zeroed arrays
(`../lessons/75`). Mojo's default `-O3` needs about 2.7 times the memory of `-O2` for this code, more than the 6 GB the
machine allows; the engine is built at `-O2`, with one compiler thread and one malloc arena, and peaks at 1.55 GB
resident (`../lessons/77`). And reading a value's bytes through the address of a Mojo argument or local gives LLVM an
undefined value: the first whole build turned the engine's `open()` into one call of its "out of memory" exit
(`../lessons/78`).

Nothing in the generated engine is edited by hand: every fix went into the translator or the runtime.

## How it was checked

- **The math**: `test/run_libm_tests.sh` compares the functions as the engine calls them (`Math`, `LibM` of
  `rt/core.mojo`) with the system's glibc 2.39, bit for bit, by the method of `tools/libm/test`: a million arguments
  per function over the ranges SWMM uses plus special values and 200,000 to 700,000 edge cases each for exp, log,
  log10, pow, sin, cos, tan, asin, acos and atan; a million per function over wide ranges and every branch threshold,
  with signed zeros, infinities, subnormals and NaNs of both signs with several payloads, for cbrt, hypot, atan2,
  cosh, sinh, tanh, log2, expm1 and log1p; a million each for sqrt, floor, ceil, trunc, fabs, round and copysign.
  29,364,615 results, **0 differences**, NaN signs and payloads included (`results/libm_tests.txt`, with the symbol
  versions the test binary imports).
- **The C library**: `test/run_crtcheck.sh` runs the cases of `tests/crtcheck` (C programs using the system's own
  glibc) through the runtime (`test/crtcheck.mojo`): libm, 0 differences in 300,576 cases for each of 27 functions;
  printf through `R.snprintf`, 0 differences in 179,756 cases and in 101,800 more covering every conversion the
  engine's format strings use; sscanf through `R.sscanf`, 0 in 1,728; from_chars, strtol, strtod, atoi, atol, ctime,
  ctype and get_nprocs, 0 in 752 (`results/crtcheck.txt`). The unit checks of `zig/test/crtcheck.zig` are not ported.
  These cases found where the runtime inherited from the SWMM5 port differed from glibc, all now fixed: printf's
  `%a`, the `#` flag on `%o` and `%x`, `h` and `hh`, `%.3s` of a null string and the `%#g` carry; sscanf's `%n`, scan
  sets, the rule for returning EOF, unsigned overflow, and its reading of `nan(...)`, of `infinity` cut by a width, of
  `0x` and of `1e+`. The engine's own formats use `%a`, `%n` and scan sets.
- **libstdc++**: `test/run_std_checks.sh` runs the cases of `tests/stdcheck` through the runtime (`test/stdcheck.mojo`):
  the permutations std::sort, std::stable_sort and std::partial_sort leave on keys with many ties (6,447 cases, over
  int and double ids ordered through a key table and over objects), and the hash tables' iteration order, bucket
  counts and std::hash (167 lines), identical to libstdc++ (`results/std_checks.txt`). The stream check is not ported.
- **The engine**: the gate (above), run on the corpus and on the extra decks, the checked build, and the independent
  rerun.

## Build and run

Needs the Mojo 1.2.0 compiler (`Mojo 1.2.0 (2016d0cd)`), glibc on x86-64 and the Boehm collector (`libgc.so.1`,
Ubuntu package libgc1, 8.2.6 was used). The compiler is not kept in the repository; install it (about 260 MB) with

    pip install --no-cache-dir --target /dev/shm/mojo6_mojo mojo-compiler==1.2.0 mojo-compiler-mojo-libs==1.2.0

and build (about four minutes, 1.55 GB of memory at most; `MOJO_HOME` if the compiler is elsewhere):

    mojo/build.sh                      # bin/openswmm
    CHECKED=1 NAME=openswmm_checked mojo/build.sh   # the checked build

Run a model the way the C++ command line runs it:

    mojo/runswmm6 model.inp model.rpt model.out

The translator needs the .NET 8 SDK (8.0.132 was used). To regenerate the engine from `cs/gen`:
`tools/cs2x/build_mojo.sh && dotnet tools/cs2x/bin/cs2mojo.dll cs mojo/gen` (about a minute); `mojo/make_primes.sh`
writes `rt/primes.mojo` again.

The gate: `mojo/gate/run_chunk.sh NAME corpus|extra [IDS_FILE] [ENGINE]` runs `gate/gate.py` on this port with the
SAVE-file wrapper (`runswmm6_saves.sh`), inside the shared lock; `gate/snapshot.sh` makes the fixed copy of a built,
committed engine that a chunk runs; `gate/rerun_build.sh` makes the clean copy of a commit that the independent rerun
gates, and `gate/compare_rerun.py` compares the two runs.

**Memory.** Each object the engine allocates comes from the Boehm collector, which frees what nothing points to; the
runtime's own stack (8 MB) and the static fields are registered with it as roots. The corpus's three slowest models
(`72_H&H_Elements(2).inp`, `SCANLON.inp`, `Baisismodell_SI_Units.inp`), run on copies, peaked at 82 MB resident
each. The compiler needs up to 1.55 GB for the whole engine at `-O2` (lessons/77).

## What this does not show

- Agreement on models outside the 480 and the 452. A feature no gate model or deck uses is untested.
- The reference's parallel runs: every parallel loop runs on one thread, in order, as the C++ engine does when it
  is held to one thread.
- The 2D and other modules of OpenSWMM 6 beyond the 1D engine the command line runs.
- Every input to the math functions: they are glibc's own, and the tests check that each call reaches glibc with the
  right argument; another glibc would give that glibc's results.
- Mojo at `-O3`, its default: the engine was not built that way here (lessons/77).

## License and attribution

The engine is a translation of the OpenSWMM Engine, Copyright 2026 HydroCouple Developers, licensed under the
Apache License, Version 2.0 (https://github.com/HydroCouple/openswmm.engine, branch `swmm6_rel`, commit 88329d6).
Portions derive from the USEPA Storm Water Management Model, which is in the public domain; the USEPA does not
endorse this translation, and neither does HydroCouple. The math is the system's glibc, called at run time and not
copied; glibc is under the GNU Lesser General Public License 2.1 or later. The Boehm collector is linked at run time.

## AI use

The translator (`tools/cs2x/Cs2Mojo.cs`, `MojoFn.cs`, `MojoExpr.cs`), the runtime (`mojo/rt`), the port's scripts and
checks and these notes were written by Claude, Anthropic's AI model, for Robert Dickinson, who directed the work. The
engine is a mechanical translation of OpenSWMM 6 (Apache-2.0, HydroCouple Developers), itself derived in part from the
public-domain EPA SWMM; it was checked by running it against the C++ engine, not by reading it. It is a translation
checked against SWMM6, not SWMM6, and not a HydroCouple or EPA release. See `../AI-USE.md`.
