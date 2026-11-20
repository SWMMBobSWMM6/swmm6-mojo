#!/bin/bash
# run_libm_tests.sh [N] [N2] - check the Mojo engine's math bit for bit against the system libm (glibc 2.39, the
# library the C++ SWMM6 engine calls), by the method of tools/libm/test/run_tests.sh (as zig/test/run_libm_tests.sh):
#   set 1: N random arguments per function over the ranges SWMM uses plus special values (tools/libm/test/mkvectors.c,
#     default 1,000,000) and 100,000 edge cases per function (mkedge.c): exp, log, log10, pow, sin, cos, tan, asin,
#     acos, atan;
#   set 2: N2 random arguments per function over wide ranges and every branch threshold, +-0, +-inf, subnormals and NaNs
#     of both signs with several payloads (mkvectors2.c, default 1,000,000): cbrt, hypot, atan2, cosh, sinh, tanh,
#     log2, expm1, log1p;
#   exact: sqrt, floor, ceil, trunc, fabs, round, copysign (ruby/test/mkexact.c, read only, N arguments each plus
#     special values).
# Every function is called as the generated engine calls it (Math, LibM of rt/core.mojo), built with the engine's flags.
# The vectors (about 0.5 GB) go to W (default /dev/shm/mojo6_libm_test) and are deleted at the end.
# Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see ../README.md.
set -e
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd)
N=${1:-1000000}; N2=${2:-1000000}; W=${W:-/dev/shm/mojo6_libm_test}; rm -rf "$W"; mkdir -p "$W"
T=$ROOT/tools/libm/test
gcc -O2 -o "$W/mkvectors" "$T/mkvectors.c" -lm
gcc -O2 -o "$W/mkedge" "$T/mkedge.c" -lm
gcc -O2 -fno-builtin -o "$W/mkvectors2" "$T/mkvectors2.c" -lm
gcc -O2 -fno-builtin -o "$W/mkexact" "$ROOT/ruby/test/mkexact.c" -lm
"$W/mkvectors" "$N" "$W/vectors.bin" > /dev/null 2>&1
"$W/mkedge" 100000 "$W/edge.bin" > /dev/null 2>&1
"$W/mkvectors2" "$N2" "$W/vectors2.bin" > /dev/null 2>&1
"$W/mkexact" "$N" "$W/exact.bin" > /dev/null 2>&1
MOJO_HOME=${MOJO_HOME:-/dev/shm/mojo6_mojo}
PYTHONPATH=$MOJO_HOME MODULAR_TELEMETRY_ENABLED=false nice -n 10 "$MOJO_HOME/bin/mojo" build -O2 --fp-mode contract=off --target-cpu x86-64 \
  -I "$HERE/.." -Xlinker /usr/lib/x86_64-linux-gnu/libgc.so.1 -o "$W/libm_check" "$HERE/libm_check.mojo" 2>&1 | grep -v -e Crashpad -e warning | grep error || true
PYTHONPATH=$MOJO_HOME "$MOJO_HOME/bin/mojo" --version 2>/dev/null | grep -v Crashpad || true
"$W/libm_check" "$W/vectors.bin" "$W/edge.bin" "$W/vectors2.bin" "$W/exact.bin"
objdump -T "$W/libm_check" | grep -E ' (exp|log|pow|sin|cos|tan|asin|acos|atan|log10|atan2|log2|sinh|tanh|expm1|log1p|cosh|cbrt|hypot|fmod|sqrt|floor|ceil|trunc|round)$' | awk '{print $NF, $(NF-1)}' | sort | tr '\n' ' '; echo
rm -rf "$W"
