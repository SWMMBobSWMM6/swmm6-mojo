#!/bin/bash
# run_crtcheck.sh [N] - compare the Mojo runtime's C library (mojo/rt) with the system's glibc, as
# zig/test/run_crtcheck.sh does for the Zig runtime: libm results bit for bit (N cases per function plus a grid of
# special values; tests/crtcheck/libm.c), printf output (printf.c, and pycheck/specs.c for every conversion spec the
# engine's format strings use), sscanf results (scanf.c), from_chars / strtol / strtod / atoi / ctime / ctype /
# get_nprocs (misc.cpp). The C and C++ programs use only the system's own libc, libm and libstdc++; everything is
# built in W (default /dev/shm/mojo6_crtcheck) and deleted at the end; tests/ is only read.
# Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see ../README.md.
set -e
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd); C=$ROOT/tests/crtcheck
W=${W:-/dev/shm/mojo6_crtcheck}; rm -rf "$W"; mkdir -p "$W"
for p in libm printf scanf; do gcc -O2 -ffp-contract=off -fno-builtin -o "$W/$p" "$C/$p.c" -lm; done
gcc -O2 -o "$W/specs" "$C/pycheck/specs.c"
g++ -O2 -std=c++20 -o "$W/misc" "$C/misc.cpp"
MOJO_HOME=${MOJO_HOME:-/dev/shm/mojo6_mojo}
PYTHONPATH=$MOJO_HOME MODULAR_TELEMETRY_ENABLED=false nice -n 10 "$MOJO_HOME/bin/mojo" build -O2 --fp-mode contract=off \
  --target-cpu x86-64 -I "$HERE/.." -Xlinker /usr/lib/x86_64-linux-gnu/libgc.so.1 -o "$W/crtcheck" "$HERE/crtcheck.mojo" \
  > "$W/build.log" 2>&1 || { grep -B2 -A8 'error:' "$W/build.log" | head -60; exit 1; }
R="$W/crtcheck"
N=${1:-300000}
"$W/libm" "$N" > "$W/libm.bin"; $R libm "$N" "$W/libm.bin"; rm "$W/libm.bin"
"$W/printf" > "$W/p.txt"; $R printf "$W/p.txt"
"$W/specs" > "$W/p.txt"; $R printf "$W/p.txt"
"$W/scanf" > "$W/p.txt"; $R scanf "$W/p.txt"
"$W/misc" > "$W/p.txt"; $R misc "$W/p.txt"
rm -rf "$W"
