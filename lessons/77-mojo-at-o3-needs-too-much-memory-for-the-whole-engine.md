Mojo 1.2 at its default -O3 needs about 2.7 times the memory of -O2 for the generated engine, and the whole engine at -O3 does not fit in the 6 GB this machine gives all the agents' commands together; the Mojo port is built at -O2.

The first builds of the whole engine were killed by the kernel's out-of-memory killer, at 5.6 GB resident, about two
minutes in, and the killer then took another agent's running gate as well. Mojo's compilation cache was no help: it
holds 17 files of up to 12.5 MB keyed by the whole program, not one entry per function, so any change compiles
everything again. To measure, `mojo/tools/stage.py` stubbed out functions (Mojo compiles only the functions a program
can reach), and a small script polled the resident size of the compiler's processes every half second and killed
them above a limit (so no build could reach the shared cap again). One fixed subset of the engine, 871 functions and
11,432 lines, compiled from an empty cache:

    -O3 (the default)      1,378 MB peak, 47 s
    -O3 --emit llvm        1,372 MB        (no LLVM optimization or code generation: the memory is Mojo's own)
    -O2                      509 MB, 41 s
    -O1                      559 MB, 42 s
    -O0 (--no-optimization)  777 MB, 58 s

The compiler alone, with nothing of the engine reachable, takes about 320 MB. The cost of -O3 is in Mojo's own
passes before LLVM (the `--emit llvm` line), so it is Mojo's inlining and optimization at the MLIR level, not
LLVM's. The engine is about 100,000 reachable lines, so at -O3 it needs well over the 6 GB cap.

-O2 changes no result: the build keeps `--fp-mode contract=off` and `--target-cpu x86-64`, so no optimization level
may fuse or reassociate floating-point operations, and the gate compares every byte.

Lesson: measure a compiler's memory on a fixed slice of the program at each optimization level before assuming the
default is the only way to build; and on a machine shared with other jobs, put a watchdog on the build's resident size
rather than an address-space limit (`prlimit --as` stopped even builds that needed only 1.5 GB resident, because Mojo
reserves far more address space than it uses).
