#!/usr/bin/env python3
"""stage.py SRC OUT HI: a copy of the generated engine with the bodies of its functions from number HI on replaced by
`raise rt_unreachable()` (functions counted in file order). Mojo compiles only the functions a program can reach, so
building such copies for several HI finds the function that makes the compiler slow or large (lessons/75, 77)."""
import sys
src, out, hi = sys.argv[1], sys.argv[2], int(sys.argv[3])
lines = open(src).read().split('\n')
res = []; i = 0; k = -1
while i < len(lines):
    l = lines[i]
    if l.startswith('def ') or (l.startswith('@no_inline') and i + 1 < len(lines) and lines[i + 1].startswith('def ')):
        if l.startswith('@'):
            res.append(l); i += 1; l = lines[i]
        k += 1
        res.append(l)
        keep = k < hi or l.startswith('def gs(') or 'static_init' in l
        j = i + 1
        if not keep:
            while j < len(lines) and (lines[j].startswith(' ') or lines[j] == ''):
                j += 1
            res.append('    raise rt_unreachable()')
            res.append('')
            i = j
            continue
        i += 1
        continue
    res.append(l); i += 1
open(out, 'w').write('\n'.join(res))
