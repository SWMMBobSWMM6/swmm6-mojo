#!/bin/bash
# snapshot.sh - the engine a gate chunk runs: copy mojo/bin/openswmm and the launchers to /dev/shm/mojo6_eng/<commit>/mojo
# and print the SAVE-file wrapper's path there (BIN_SUFFIX=_checked: the checked build, bin/openswmm_checked, to
# /dev/shm/mojo6_eng/<commit>_checked/mojo). The binary must be built from the committed sources (the script
# refuses when mojo/rt, mojo/gen, mojo/main.mojo or mojo/build.sh differ from HEAD, or the binary is older than them), so
# a chunk runs a fixed commit, and rebuilding the tree while a chunk is queued or running cannot change what it runs
# (lessons/12: never rewrite a file a running program maps).
# Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see AI-USE.md.
set -e
Z=$(cd "$(dirname "$0")/.." && pwd); ROOT=$(cd "$Z/.." && pwd)
git -C "$ROOT" diff --quiet HEAD -- mojo/rt mojo/gen mojo/main.mojo mojo/build.sh || { echo "snapshot.sh: uncommitted engine changes" >&2; exit 1; }
for f in "$Z"/rt/*.mojo "$Z"/gen/engine.mojo "$Z"/main.mojo; do [ "$Z/bin/openswmm${BIN_SUFFIX:-}" -nt "$f" ] || { echo "snapshot.sh: bin/openswmm${BIN_SUFFIX:-} is older than $f" >&2; exit 1; }; done
C=$(git -C "$ROOT" rev-parse --short=7 HEAD)
D=/dev/shm/mojo6_eng/$C${BIN_SUFFIX:-}/mojo
if [ ! -x "$D/bin/openswmm" ]; then
  mkdir -p "$D/bin"
  cp "$Z/bin/openswmm${BIN_SUFFIX:-}" "$D/bin/openswmm"
  cp "$Z/runswmm6" "$Z/runswmm6_saves.sh" "$D/"
fi
echo "$D/runswmm6_saves.sh"
