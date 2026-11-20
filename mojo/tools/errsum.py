#!/usr/bin/env python3
"""Summarize a Mojo build log: each distinct error message (with names normalised) and how often it occurs."""
import re, sys, collections
c = collections.Counter(); first = {}
for line in open(sys.argv[1], errors='replace'):
    m = re.match(r'(\S+?):(\d+):(\d+): error: (.*)', line)
    if not m:
        continue
    msg = re.sub(r"'[^']*'", "'X'", m.group(4))
    c[msg] += 1
    first.setdefault(msg, '%s:%s %s' % (m.group(1).split('/')[-1], m.group(2), m.group(4)[:200]))
for msg, n in c.most_common(int(sys.argv[2]) if len(sys.argv) > 2 else 40):
    print('%6d  %s\n        e.g. %s' % (n, msg[:150], first[msg]))
print('total', sum(c.values()))
