#!/bin/bash
# rerun_build.sh [COMMIT] [DIR] - the first half of the independent rerun: a clean copy of COMMIT (default HEAD) of
# this repository (git archive) in DIR (default /dev/shm/mojo6_v), where the translator is rebuilt, the engine is
# regenerated from cs/gen and compared byte for byte with the committed mojo/gen/engine.mojo (and the translator's two
# reports with the committed mojo/cs2mojo_*.txt), the one generated runtime file (mojo/rt/primes.mojo) is written again
# by mojo/make_primes.sh and compared, and the engine is built there by mojo/build.sh with an empty Mojo cache of its
# own (BUILD_WRAP, if set, is put before that one command: on this machine a watchdog on the build's memory). The gate
# then runs that copy's engine:
#   mojo/gate/run_chunk.sh mojo6_v1 corpus - DIR/mojo/runswmm6_saves.sh   (and mojo6_vx, extra)
# After zig/gate/rerun_build.sh. Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see ../README.md.
set -e
K=$(cd "$(dirname "$0")/.." && pwd); ROOT=$(cd "$K/.." && pwd)
C=${1:-HEAD}; R=${2:-/dev/shm/mojo6_v}
rm -rf "$R"; mkdir -p "$R"
git -C "$ROOT" archive "$C" | tar -x -C "$R"
echo "== clean copy of $(git -C "$ROOT" rev-parse --short "$C") in $R"
cd "$R"
echo "== the translator: tools/cs2x/build_mojo.sh"
OUT="$R/tools/cs2x/bin" nice -n 10 tools/cs2x/build_mojo.sh 2>&1 | grep -v 'warning CS' || true
echo "== the engine, regenerated from cs/gen into $R/regen and compared with mojo/gen/engine.mojo and mojo/cs2mojo_*.txt"
mkdir -p "$R/regen/gen" "$R/regen/mojo"
nice -n 10 dotnet tools/cs2x/bin/cs2mojo.dll cs "$R/regen/gen" > /dev/null
for f in gen/engine.mojo cs2mojo_runtime.txt cs2mojo_todo.txt; do
	if cmp -s "$R/regen/$f" "mojo/$f"; then echo "mojo/$f: $(wc -l < "mojo/$f") lines, byte-identical to the commit"; else echo "mojo/$f: DIFFERENT"; exit 1; fi
done
echo "== the generated runtime file, written again by mojo/make_primes.sh"
mojo/make_primes.sh "$R/regen/primes.mojo"
if cmp -s "$R/regen/primes.mojo" mojo/rt/primes.mojo; then echo "mojo/rt/primes.mojo: byte-identical to the commit"; else echo "primes.mojo: DIFFERENT"; exit 1; fi
rm -rf "$R/regen"
echo "== the engine, built with mojo/build.sh and an empty cache ($R/mojocache)"
rm -f mojo/bin/openswmm
MODULAR_CACHE_DIR="$R/mojocache" ${BUILD_WRAP:-} mojo/build.sh
rm -rf "$R/mojocache"
ls -l mojo/bin/openswmm
echo "fused multiply-add instructions in the binary: $(objdump -d mojo/bin/openswmm | grep -cE 'vfn?m(add|sub)' || true)"
