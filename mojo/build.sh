#!/bin/sh
# build.sh - build the Mojo SWMM6 engine:  bin/openswmm <input.inp> <report.rpt> [output.out]
# Needs the Mojo 1.2.0 compiler, `Mojo 1.2.0 (2016d0cd)`, which is not kept on disk here. Install it into memory with
#   pip install --no-cache-dir --target /dev/shm/mojo6_mojo mojo-compiler==1.2.0 mojo-compiler-mojo-libs==1.2.0
# (about 260 MB); this script runs it as PYTHONPATH=$MOJO_HOME $MOJO_HOME/bin/mojo (MOJO_HOME, default
# /dev/shm/mojo6_mojo). Also needs glibc's libm and the Boehm collector (libgc.so.1, Ubuntu package libgc1).
#   --fp-mode contract=off   Mojo fuses a*b+c into a fused multiply-add by default (contract=fast); C# and the C++
#                            reference round the product and the sum separately
#   --target-cpu x86-64      the baseline x86-64: no FMA or AVX instruction can appear (objdump -d finds none)
#   -O2                      Mojo's default -O3 needs about three times the memory (more than this machine's
#                            6 GB for the whole engine; lessons/77); -O2 changes no floating-point result
#   -j 1, MALLOC_ARENA_MAX=1 one compiler thread and one malloc arena: the build then stays under 1.6 GB resident
#                            and 4.5 GB of address space (lessons/77); neither changes the code
#   CHECKED=1                (in the environment) the checked build: every C# array index is checked (rt/core.mojo
#                            CHECKED). Mojo's own "safe" assertions (List and Span indices in the runtime) are on in
#                            every build; -D ASSERT=all, which adds the rest, ran out of memory (README)
# The engine is regenerated from cs/gen with tools/cs2x/build_mojo.sh && dotnet tools/cs2x/bin/cs2mojo.dll cs mojo/gen
# (from the repository root), and rt/primes.mojo with make_primes.sh.
# Written by Claude (Anthropic) for the SWMM6 ports; see README.md and ../AI-USE.md.
set -e
cd "$(dirname "$0")"
MOJO_HOME=${MOJO_HOME:-/dev/shm/mojo6_mojo}
[ -x "$MOJO_HOME/bin/mojo" ] || { echo "build.sh: no Mojo compiler at $MOJO_HOME (see the pip command above)" >&2; exit 1; }
LIBGC=${LIBGC:-$(ls /usr/lib/x86_64-linux-gnu/libgc.so.1 /lib/x86_64-linux-gnu/libgc.so.1 2>/dev/null | head -1)}
[ -n "$LIBGC" ] || { echo "build.sh: libgc.so.1 (the Boehm collector) not found" >&2; exit 1; }
OUT=${OUT:-bin}
NAME=${NAME:-openswmm}
mkdir -p "$OUT"
SRC=.
XFLAGS=${XFLAGS:-}
if [ "${CHECKED:-0}" = 1 ]; then
  # the checked build: the same sources with the array bounds check of rt/core.mojo switched on
  SRC=${CHECK_DIR:-/dev/shm/mojo6_checked_src}
  rm -rf "$SRC"; mkdir -p "$SRC"
  cp -r rt gen main.mojo "$SRC"/
  sed -i 's/^comptime CHECKED = False/comptime CHECKED = True/' "$SRC/rt/core.mojo"
fi
export PYTHONPATH="$MOJO_HOME" MALLOC_ARENA_MAX=1 MODULAR_TELEMETRY_ENABLED=false MODULAR_CACHE_DIR=${MODULAR_CACHE_DIR:-/dev/shm/mojo6_cache}
nice -n 10 "$MOJO_HOME/bin/mojo" build -O2 -j 1 --fp-mode contract=off --target-cpu x86-64 $XFLAGS -I "$SRC" -Xlinker "$LIBGC" \
  -o "$OUT/$NAME" "$SRC/main.mojo" > "$OUT/build.log" 2>&1 || { grep -v -e Crashpad -e 'warning:' "$OUT/build.log" | grep -B2 -A6 'error' | head -80; exit 1; }
echo "built $OUT/$NAME with $("$MOJO_HOME/bin/mojo" --version 2>/dev/null | grep -v Crashpad) ($(grep -c 'warning:' "$OUT/build.log") compiler warnings in $OUT/build.log)"
