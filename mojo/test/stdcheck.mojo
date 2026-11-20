# stdcheck.mojo - the cases of tests/stdcheck through the Mojo runtime (mojo/rt/cont.mojo):
#   stdcheck hash        the operations of hashcheck.cpp on UMap / USet (a port of libstdc++'s _Hashtable with its
#                        prime rehash policy) and std::hash of strings
#   stdcheck sort I|D|P  the permutations of sortcheck.cpp: StdAlgo.Sort, StableSort and PartialSort (libstdc++'s
#                        introsort, merge sort and heap sort) over int and double ids ordered through a key table (as
#                        the engine sorts index arrays) and over objects ordered by a key field
# Output must equal the C++ programs' byte for byte. After zig/test/hashcheck.zig and sortcheck.zig. (Mode O of
# sortcheck.zig, value structs, is not ported: the engine sorts no struct values.)
# Built by mojo/test/run_std_checks.sh with the engine's flags.
# Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see ../README.md.
from std.sys import argv
from rt.core import *
from rt.crt import *
from rt.str import *
from rt.cont import *
from rt.rlib import *


struct Rng(Movable):
    var s: UInt64

    def __init__(out self, s: UInt64):
        self.s = s

    def next(mut self) -> UInt64:
        self.s ^= self.s << 13
        self.s ^= self.s >> 7
        self.s ^= self.s << 17
        return self.s


def name(r: UInt64) raises -> Ref[Str]:
    var pre = ["J", "C", "N", "OF", "P", "RG", "SUB_", "Link-", "node.", "W"]
    var x = String(pre[Int(r % 10)]) + String((r >> 8) % 5000)
    if (r >> 20) % 3 == 0:
        x += "_" + String((r >> 24) % 97)
    var b = x.as_bytes()
    return Str.of_bytes(P[UInt8](unsafe_from_address=Int(b.unsafe_ptr())), len(b))


def text(s: Ref[Str]) -> String:
    var o = List[UInt8]()
    for i in range(Int(s[].n)):
        o.append(s[].b[i])
    return String(unsafe_from_utf8=o)


def hash_mode() raises:
    var rng = Rng(52024)
    var out = String("")
    for round in range(40):
        var m = UMap[Ref[Str], Int32].new_()
        var mi = UMap[Int32, Int32].new_()
        var st = USet[Ref[Str]].new_()
        var n = 1 + Int(rng.next() % (UInt64(60) if round < 20 else UInt64(3000)))
        if round % 7 == 3:
            m[].reserve(UInt64(n))
        for i in range(n):
            var r = rng.next()
            var k = name(r)
            if r % 5 == 0:
                var v = m[].Index(k)
                v[] += Int32(i)
            else:
                _ = m[].emplace(k, Int32(i))
            _ = mi[].emplace(Int32(Int(r % 20000)) - 10000, Int32(i))
            _ = st[].insert(k)
            if r % 11 == 0 and not m[].empty():
                _ = m[].erase(name(rng.next()))
            if r % 13 == 0:
                _ = mi[].erase(Int32(Int(rng.next() % 20000)) - 10000)
            if r % 17 == 0 and not m[].empty():
                _ = m[].erase(m[].begin())
        var c = m[].Clone()
        out += "map " + String(round) + ": " + String(m[].bucket_count()) + " buckets " + String(m[].size()) + ":"
        var it = m[].Items()
        while it.next():
            var kv = it.cur()
            out += " " + text(kv[].first) + "=" + String(kv[].second)
        out += "\ncopy:"
        var ic = c[].Items()
        while ic.next():
            out += " " + text(ic.cur()[].first)
        out += "\nimap " + String(mi[].bucket_count()) + " " + String(mi[].size()) + ":"
        var ii = mi[].Items()
        while ii.next():
            var kv = ii.cur()
            out += " " + String(kv[].first) + "=" + String(kv[].second)
        out += "\nset " + String(st[].bucket_count()) + ":"
        var iset = st[].Items()
        while iset.next():
            out += " " + text(iset.cur())
        out += "\n"
    var ws = ["", "a", "abcdefg", "abcdefgh", "abcdefghi", "Junction_17", "OUTFALL-1"]
    for w in ws:
        var b = String(w).as_bytes()
        var s = Str.of_bytes(P[UInt8](unsafe_from_address=Int(b.unsafe_ptr())), len(b))
        out += "hash " + String(w) + " " + String(elem_hash[Ref[Str]](s)) + "\n"
    print(out, end="")


def lt_i(d: Dlg, a: Int32, b: Int32) raises -> Bool:
    var k = d.ctx.unsafe_bitcast[Int32]()
    return k[Int(a)] < k[Int(b)]


def lt_d(d: Dlg, a: Float64, b: Float64) raises -> Bool:
    var k = d.ctx.unsafe_bitcast[Int32]()
    return k[Int(a)] < k[Int(b)]


def lt_p(d: Dlg, a: Ref[Pair[Int32, Int32]], b: Ref[Pair[Int32, Int32]]) raises -> Bool:
    return a[].first < b[].first


def sort_mode(mode: String) raises:
    var rng = Rng(1729)
    var ns = List[Int]()
    for n in range(301):
        ns.append(n)
    for n in [511, 512, 513, 1000, 4096, 10007]:
        ns.append(n)
    var out = String("")
    var tags = ["sort", "stable", "heap"]
    for n in ns:
        for pat in range(7):
            var keys = gc_atomic_bytes(4 * max(n, 1)).unsafe_bitcast[Int32]()
            for i in range(n):
                var v: Int
                if pat == 0: v = Int(rng.next() % 5)
                elif pat == 1: v = Int(rng.next() % 1000000)
                elif pat == 2: v = i // 3
                elif pat == 3: v = (n - i) // 2
                elif pat == 4: v = 7
                elif pat == 5: v = i if i < n // 2 else n - i
                else: v = (i * 7919) % 31
                keys[i] = Int32(v)
            var cmp = Dlg(keys.unsafe_bitcast[NoneType](), 0)
            for which in range(3):
                out += String(tags[which]) + " " + String(n) + " " + String(pat) + ":"
                var ln = Int64(n)
                if mode == "I":
                    var a = Ary[Int32].make(n)
                    for i in range(n):
                        a[i] = Int32(i)
                    if which == 0: StdAlgo.Sort[Int32, lt_i](a, 0, ln, cmp)
                    elif which == 1: StdAlgo.StableSort[Int32, lt_i](a, 0, ln, cmp)
                    else: StdAlgo.PartialSort[Int32, lt_i](a, 0, ln, ln, cmp)
                    for i in range(n):
                        out += " " + String(a[i])
                elif mode == "D":
                    var a = Ary[Float64].make(n)
                    for i in range(n):
                        a[i] = Float64(i)
                    if which == 0: StdAlgo.Sort[Float64, lt_d](a, 0, ln, cmp)
                    elif which == 1: StdAlgo.StableSort[Float64, lt_d](a, 0, ln, cmp)
                    else: StdAlgo.PartialSort[Float64, lt_d](a, 0, ln, ln, cmp)
                    for i in range(n):
                        out += " " + String(Int(a[i]))
                else:
                    var a = Ary[Ref[Pair[Int32, Int32]]].make(n)
                    for i in range(n):
                        a[i] = Pair[Int32, Int32].new_(keys[i], Int32(i))
                    if which == 0: StdAlgo.Sort[Ref[Pair[Int32, Int32]], lt_p](a, 0, ln, cmp)
                    elif which == 1: StdAlgo.StableSort[Ref[Pair[Int32, Int32]], lt_p](a, 0, ln, cmp)
                    else: StdAlgo.PartialSort[Ref[Pair[Int32, Int32]], lt_p](a, 0, ln, ln, cmp)
                    for i in range(n):
                        out += " " + String(a[i][].second)
                out += "\n"
    print(out, end="")


def main() raises:
    rt_init()
    crt_init()
    rlib_init()
    var a = argv()
    if String(a[1]) == "hash":
        hash_mode()
    else:
        sort_mode(String(a[2]))
