#!/bin/bash
# run_std_checks.sh - the Mojo runtime's libstdc++ behaviour against libstdc++ itself, on the cases of tests/stdcheck
# (as zig/test/run_std_checks.sh does for the Zig runtime):
#   sort    stdcheck.mojo sort I, D, P against sortcheck.cpp: the permutations std::sort, std::stable_sort and
#           std::partial_sort leave on keys with many ties, over int and double ids ordered through a key table (as
#           the engine sorts index arrays) and over objects ordered by a key field
#   hash    stdcheck.mojo hash against hashcheck.cpp: unordered_map / unordered_set bucket counts and iteration order
#           after inserts, operator[], erases, reserve and copies, and std::hash of strings
# (The iostream check of tests/stdcheck/run_stream.sh is not ported; the gate exercises the engine's stream use.)
# The C++ programs use only the system's libstdc++. Everything is built in W (default /dev/shm/mojo6_stdcheck) and
# deleted at the end; tests/ is only read.
# Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see ../README.md.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd); S=$ROOT/tests/stdcheck
W=${W:-/dev/shm/mojo6_stdcheck}; rm -rf "$W"; mkdir -p "$W"
fail=0
same() { if cmp -s "$1" "$2"; then echo "  $3: identical"; else echo "  $3: DIFFERENT"; diff "$1" "$2" | head -6 | cut -c1-300; fail=1; fi; }
g++ -O2 -std=c++20 -o "$W/sortcheck" "$S/sortcheck.cpp"
g++ -O2 -std=c++20 -o "$W/hashcheck" "$S/hashcheck.cpp"
MOJO_HOME=${MOJO_HOME:-/dev/shm/mojo6_mojo}
PYTHONPATH=$MOJO_HOME MODULAR_TELEMETRY_ENABLED=false nice -n 10 "$MOJO_HOME/bin/mojo" build -O2 --fp-mode contract=off \
  --target-cpu x86-64 -I "$HERE/.." -Xlinker /usr/lib/x86_64-linux-gnu/libgc.so.1 -o "$W/stdcheck" "$HERE/stdcheck.mojo" \
  > "$W/build.log" 2>&1 || { grep -B2 -A8 'error:' "$W/build.log" | head -60; exit 1; }
"$W/sortcheck" > "$W/sort_cpp.txt"; "$W/hashcheck" > "$W/hash_cpp.txt"
echo "sort cases: $(wc -l < "$W/sort_cpp.txt")"
for m in I D P; do "$W/stdcheck" sort $m > "$W/sort_mojo_$m.txt"; same "$W/sort_cpp.txt" "$W/sort_mojo_$m.txt" "sort, stable_sort, partial_sort ($m), libstdc++ and Mojo"; done
"$W/stdcheck" hash > "$W/hash_mojo.txt"
echo "hash lines: $(wc -l < "$W/hash_cpp.txt")"
same "$W/hash_cpp.txt" "$W/hash_mojo.txt" "unordered_map / unordered_set order and std::hash, libstdc++ and Mojo"
rm -rf "$W"
exit $fail
