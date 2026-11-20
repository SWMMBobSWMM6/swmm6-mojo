Mojo's own runtime reserves 1 GB regions of address space at random addresses before `main` runs, so a block mapped at a fixed address can find its place taken; the Mojo port starts itself again when that happens.

Mojo 1.2 has no global variables, so the Mojo port keeps the engine's static fields and the runtime's state in two
blocks at fixed addresses, `0x6f0000000000` and `0x6f0100000000`, mapped at start-up with
`mmap(MAP_FIXED_NOREPLACE)` (lessons/74 has the rest of that design). In the first gate runs, 931 of the 932 starts
worked; one deck of the extra set (`et_SIGMA_dry.inp`, run `mojo6_x01`) stopped after 0.047 s with "cannot map the
runtime's state block", and passed three times out of three when run again. The memory map of a running engine
(gdb, `info proc mappings`) shows why:

    0x1332c0000000 0x1332ffc00000 0x3fc00000 ---p
    0x1332ffc00000 0x133300000000   0x400000 rw-p
    0x4feec0000000 0x4feeffe00000 0x3fe00000 ---p
    0x4feeffe00000 0x4fef00000000   0x200000 rw-p
    0x6f0000000000 0x6f0000100000   0x100000 rw-p     the runtime's state (ours)
    0x6f0100000000 0x6f0100002000     0x2000 rw-p     the static fields (ours)

The two 1 GB reservations, at 1 GB-aligned addresses, are made before `main` runs (by Mojo's runtime libraries;
the engine's own code makes no such mapping). They move on every start: four ordinary runs put them at
0x6eb600000000 and 0x728e00000000, 0x4da340000000 and 0x5198c0000000, 0x0e3f40000000 and 0x70c900000000,
0x2dabc0000000 and 0x32b5c0000000. Under gdb, which turns off the kernel's address randomization, they stay at the
two addresses above, so it is the kernel's randomization that places them. Were the addresses uniform over the
131,072 1-GB slots of user address space, two regions would cover one of our two slots about once in 33,000 starts;
the gate saw it once in 932, so they are not uniform (the first run above came within 10 GB of our blocks).

The runtime cannot choose another address, because the generated code reaches both blocks through constants. So
`rt_init` now maps both blocks first thing (the static block with 16 MB reserved, `MAP_NORESERVE`, so it no longer
waits for the static initializer to know its size), and if either address is taken it starts the program again with
`execv("/proc/self/exe", argv)`, before anything has been read or written: the new process gets new random regions.
The environment variable `OPENSWMM_MOJO_REMAP` counts the attempts and stops at eight.

Lesson: a fixed address is only safe if nothing else in the process can take it first, and a language runtime that
loads before `main` is something else. Map fixed blocks at the very start, test for failure, and have a way out that
does not depend on the address being free.
