# crtcheck.mojo - the Mojo side of tests/crtcheck (as zig/test/crtcheck.zig is the Zig side):
#   crtcheck libm N FILE | printf FILE | scanf FILE | misc FILE
# reads what the C program of the same name (tests/crtcheck: libm.c, printf.c, scanf.c, misc.cpp, and
# tests/crtcheck/pycheck/specs.c for every printf conversion the engine's format strings use) wrote, and reports where
# the Mojo runtime (mojo/rt) differs from glibc. printf and sscanf go through R.snprintf and R.sscanf, the calls the
# engine makes; libm goes through Math and LibM as the engine calls them. The units of crtcheck.zig are not ported.
# Built by mojo/test/run_crtcheck.sh with the engine's flags.
# Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see ../README.md.
from std.sys import argv
from rt.core import *
from rt.crt import *
from rt.str import *
from rt.cont import *
from rt.rlib import *


def hv(c: UInt8) -> Int:
    var x = Int(c)
    return x - 48 if x <= 57 else (x - 87 if x >= 97 else x - 55)


def unhex(s: String) raises -> CPtr:
    """a NUL-terminated collected copy of the bytes written as hexadecimal ("-" is empty)"""
    var b = s.as_bytes()
    var n = 0 if s == "-" else len(b) // 2
    var p = gc_atomic_bytes(n + 1).unsafe_bitcast[Int8]()
    for i in range(n):
        p[unsafe_offset=i] = Int8(hv(b[2 * i]) * 16 + hv(b[2 * i + 1]))
    p[unsafe_offset=n] = 0
    return CPtr(p)


def hexu(s: String) -> UInt64:
    var v: UInt64 = 0
    for c in s.as_bytes():
        v = v * 16 + UInt64(hv(c))
    return v


def hexof(p: CPtr, n: Int) -> String:
    if n == 0:
        return "-"
    var d = "0123456789abcdef".as_bytes()
    var o = List[UInt8]()
    for i in range(n):
        var c = Int(UInt8(p.p[unsafe_offset=i]))
        o.append(d[c >> 4])
        o.append(d[c & 15])
    return String(unsafe_from_utf8=o)


def clen(p: CPtr) -> Int:
    var n = 0
    while p.p[unsafe_offset=n] != 0:
        n += 1
    return n


def cs(p: CPtr) -> String:
    var o = List[UInt8]()
    for i in range(clen(p)):
        o.append(UInt8(p.p[unsafe_offset=i]))
    return String(unsafe_from_utf8=o)


def hex16(v: UInt64) -> String:
    var d = "0123456789abcdef".as_bytes()
    var o = List[UInt8]()
    for i in range(16):
        o.append(d[Int((v >> UInt64(60 - 4 * i)) & 15)])
    return String(unsafe_from_utf8=o)


def hex8(v: UInt32) -> String:
    var d = "0123456789abcdef".as_bytes()
    var o = List[UInt8]()
    for i in range(8):
        o.append(d[Int((v >> UInt32(28 - 4 * i)) & 15)])
    return String(unsafe_from_utf8=o)


def fields(l: String) raises -> List[String]:
    var r = List[String]()
    for x in l.split("\t"):
        r.append(String(x))
    while len(r) < 8:
        r.append("")
    return r^


comptime ALL = False   # True prints every mismatch (for a tally by format)


def report(what: String, n: Int, bad: Int):
    print(what, "cases:", n, ", mismatches:", bad)


# ------------------------------------------------------------------------------------------------ printf
def parg(c: String, v: String) raises -> Arg:
    if c == "d": return A(f64_bits(hexu(v)))
    if c == "i": return A(Int32(Int64(hexu(v) & 0xFFFFFFFF).cast[DType.uint32]().cast[DType.int32]()))
    if c == "l": return A(Int64(hexu(v).cast[DType.int64]()))
    if c == "s": return A(unhex(v))
    if c == "S": return A_null()
    raise Error("printf kind " + c)


def printf_file(path: String) raises:
    var n = 0
    var bad = 0
    for line in open(path, "r").read().split("\n"):
        if line.byte_length() == 0:
            continue
        var f = fields(String(line))
        n += 1
        var fmt = unhex(f[0])
        var vals = f[2].split(",")
        var types = f[1]
        var size = UInt64(Int(f[3]))
        var buf = R.Buf(Int32(1024))
        for i in range(1024):
            buf.p[unsafe_offset=i] = 0x55
        buf.p[unsafe_offset=0] = 0
        var r: Int32 = 0
        var k = types.byte_length()
        if k == 1:
            r = R.snprintf(buf, size, fmt, parg(types, String(vals[0])))
        elif k == 2:
            r = R.snprintf(buf, size, fmt, parg(String(types[byte=0]), String(vals[0])), parg(String(types[byte=1]), String(vals[1])))
        elif k == 3:
            r = R.snprintf(buf, size, fmt, parg(String(types[byte=0]), String(vals[0])), parg(String(types[byte=1]), String(vals[1])),
                           parg(String(types[byte=2]), String(vals[2])))
        else:
            raise Error("printf argument kinds " + types)
        var o = String("-")
        if size > 0:
            o = hexof(buf, clen(buf))
        var want = f[4] + "\t" + f[5]
        var got = String(r) + "\t" + o
        if want != got:
            bad += 1
            if bad <= 15 or ALL:
                print("MISMATCH", f[0], "(" + f[1] + ")\n  glibc: ", want, "\n  Mojo:  ", got)
    report("printf", n, bad)


# ------------------------------------------------------------------------------------------------ scanf
def scanf_file(path: String) raises:
    var n = 0
    var bad = 0
    var slots = gc_atomic_bytes(8 * 64).unsafe_bitcast[Int8]()
    for line in open(path, "r").read().split("\n"):
        if line.byte_length() == 0:
            continue
        var f = fields(String(line))
        n += 1
        var fmt = unhex(f[0])
        var inp = unhex(f[1])
        var types = f[2].as_bytes()
        var m = len(types)
        for i in range(8 * 64):
            slots[unsafe_offset=i] = 0x55
        var a = List[Arg]()
        for k in range(m):
            var p = slots + 64 * k
            var t = Int(types[k])
            if t == ord("i") or t == ord("n"):
                a.append(A(p.bitcast[Int32]()))
            elif t == ord("u"):
                a.append(A(p.bitcast[UInt32]()))
            elif t == ord("l"):
                a.append(A(p.bitcast[Int64]()))
            elif t == ord("f"):
                a.append(A(p.bitcast[Float32]()))
            elif t == ord("d"):
                a.append(A(p.bitcast[Float64]()))
            else:
                a.append(A(p))
        var r: Int32
        var s = inp
        if m == 0: r = R.sscanf(s, fmt)
        elif m == 1: r = R.sscanf(s, fmt, a[0].copy())
        elif m == 2: r = R.sscanf(s, fmt, a[0].copy(), a[1].copy())
        elif m == 3: r = R.sscanf(s, fmt, a[0].copy(), a[1].copy(), a[2].copy())
        elif m == 4: r = R.sscanf(s, fmt, a[0].copy(), a[1].copy(), a[2].copy(), a[3].copy())
        elif m == 5: r = R.sscanf(s, fmt, a[0].copy(), a[1].copy(), a[2].copy(), a[3].copy(), a[4].copy())
        elif m == 6: r = R.sscanf(s, fmt, a[0].copy(), a[1].copy(), a[2].copy(), a[3].copy(), a[4].copy(), a[5].copy())
        elif m == 7: r = R.sscanf(s, fmt, a[0].copy(), a[1].copy(), a[2].copy(), a[3].copy(), a[4].copy(), a[5].copy(), a[6].copy())
        else: r = R.sscanf(s, fmt, a[0].copy(), a[1].copy(), a[2].copy(), a[3].copy(), a[4].copy(), a[5].copy(), a[6].copy(), a[7].copy())
        var got = String(r) + "\t"
        for k in range(m):
            var p = slots + 64 * k
            var t = Int(types[k])
            if t == ord("i") or t == ord("n"):
                got += String(p.bitcast[Int32]()[])
            elif t == ord("u"):
                got += String(p.bitcast[UInt32]()[].cast[DType.int32]())
            elif t == ord("l"):
                got += String(p.bitcast[Int64]()[])
            elif t == ord("f"):
                got += hex8(p.bitcast[UInt32]()[])
            elif t == ord("d"):
                got += hex16(p.bitcast[UInt64]()[])
            elif t == ord("k"):
                got += String(Int(p[]))
            else:
                got += hexof(CPtr(p), 12)
            got += " "
        var want = f[3] + "\t" + f[4]
        if want != got:
            bad += 1
            if bad <= 15 or ALL:
                print("MISMATCH", f[0], "(" + f[1] + ")\n  glibc: ", want, "\n  Mojo:  ", got)
    report("scanf", n, bad)


# ------------------------------------------------------------------------------------------------ misc
def misc_file(path: String) raises:
    var n = 0
    var bad = 0
    for line in open(path, "r").read().split("\n"):
        if line.byte_length() == 0:
            continue
        var f = fields(String(line))
        n += 1
        var k = f[0]
        var s = unhex(f[1])
        var e = s.add(clen(s))
        var got = String("")
        var want = f[2]
        if k == "fci":
            var v = gc_atomic_bytes(8).unsafe_bitcast[Int32]()
            v[] = 0x55555555
            var r = Std.from_chars(s, e, v)
            got = String(r.ec) + " " + String(r.ptr.diff(s)) + " " + String(v[])
        elif k == "fcu":
            var v = gc_atomic_bytes(8).unsafe_bitcast[UInt32]()
            v[] = 0x55555555
            var r = Std.from_chars(s, e, v)
            got = String(r.ec) + " " + String(r.ptr.diff(s)) + " " + String(v[])
        elif k == "fcl":
            var v = gc_atomic_bytes(8).unsafe_bitcast[Int64]()
            v[] = 0x5555555555555555
            var r = Std.from_chars(s, e, v)
            got = String(r.ec) + " " + String(r.ptr.diff(s)) + " " + String(v[])
        elif k == "fcd":
            var v = gc_atomic_bytes(8).unsafe_bitcast[Float64]()
            v[] = 0.25
            var r = Std.from_chars(s, e, v)
            got = String(r.ec) + " " + String(r.ptr.diff(s)) + " " + hex16(v.bitcast[UInt64]()[])
        elif k == "strtol":
            var en = gc_atomic_bytes(8).unsafe_bitcast[CPtr]()
            en[] = s
            var v = R.strtol(s, en, Int32(10))
            got = String(v) + " " + String(en[].diff(s))
        elif k == "atoi":
            got = String(R.atoi(s))
        elif k == "atol":
            got = String(R.atol(s))
        elif k == "strtod":
            var en = gc_atomic_bytes(8).unsafe_bitcast[CPtr]()
            en[] = s
            var v = R.strtod(s, en)
            got = hex16(bits_of(v)) + " " + String(en[].diff(s))
        elif k == "ctime":
            var t = Ary[Int64].make(1)
            t[0] = Int64(Int(cs(s)))
            var p = R.ctime(Ptr[Int64](t, 0))
            got = hexof(p, clen(p))
        elif k == "nprocs":
            got = String(Sys.hardware_concurrency())
        elif k == "ctype":
            # the runtime has the functions the engine calls: isdigit, isalpha, isalnum, isspace, toupper, tolower;
            # isupper, islower, ispunct, isprint and isxdigit are glibc's own in the comparison
            var c = Int32(Int(cs(s)))
            var w = want.as_bytes()
            got = String(Int(R.isdigit(c) != 0)) + String(Int(R.isalpha(c) != 0)) + String(Int(R.isalnum(c) != 0)) + String(Int(R.isspace(c) != 0))
            got += String(want[byte=4:9])
            got += " " + String(R.toupper(c)) + " " + String(R.tolower(c))
            _ = w
        else:
            raise Error("misc kind " + k)
        if got != want:
            bad += 1
            if bad <= 15 or ALL:
                print("MISMATCH", k, f[1], "\n  glibc: ", want, "\n  Mojo:  ", got)
    report("misc", n, bad)


# ------------------------------------------------------------------------------------------------ libm
def libm_call(fi: Int, x: Float64, y: Float64) raises -> Float64:
    if fi == 0: return Math.Atan2(x, y)
    if fi == 1: return Math.Cbrt(x)
    if fi == 2: return Math.Cosh(x)
    if fi == 3: return Math.Sinh(x)
    if fi == 4: return Math.Tanh(x)
    if fi == 5: return Math.Log2(x)
    if fi == 6: return LibM.expm1(x)
    if fi == 7: return LibM.log1p(x)
    if fi == 8: return LibM.hypot(x, y)
    if fi == 9: return LibM.fmod(x, y)
    if fi == 10: return LibM.remainder(x, y)
    if fi == 11: return LibM.round_(x)
    if fi == 12: return LibM.nextafter(x, y)
    if fi == 13: return Math.Exp(x)
    if fi == 14: return Math.Log(x)
    if fi == 15: return Math.Pow(x, y)
    if fi == 16: return Math.Sin(x)
    if fi == 17: return Math.Cos(x)
    if fi == 18: return Math.Tan(x)
    if fi == 19: return Math.Asin(x)
    if fi == 20: return Math.Acos(x)
    if fi == 21: return Math.Atan(x)
    if fi == 22: return Math.Log10(x)
    if fi == 23: return Math.Floor(x)
    if fi == 24: return Math.Ceiling(x)
    if fi == 25: return Math.Truncate(x)
    return Math.Sqrt(x)


def libm_file(n: Int, path: String) raises:
    var names = ["atan2", "cbrt", "cosh", "sinh", "tanh", "log2", "expm1", "log1p", "hypot", "fmod", "remainder", "round",
                 "nextafter", "exp", "log", "pow", "sin", "cos", "tan", "asin", "acos", "atan", "log10", "floor", "ceil",
                 "trunc", "sqrt"]
    var per = n + 24 * 24
    var data = open(path, "r").read_bytes()
    if len(data) < per * 24 * 27:
        raise Error("short input")
    var d = data.unsafe_ptr().bitcast[UInt64]()
    var total = 0
    for fi in range(27):
        var bad = 0
        var sbad = 0
        var nan_sign = 0
        var first = String("")
        for k in range(per):
            var o = 3 * (fi * per + k)
            var x = f64_bits(d[o])
            var y = f64_bits(d[o + 1])
            var w = d[o + 2]
            var g = libm_call(fi, x, y)
            if bits_of(g) == w:
                continue
            bad += 1
            if k >= n:
                sbad += 1
            if g != g and f64_bits(w) != f64_bits(w):
                nan_sign += 1
            if first.byte_length() == 0:
                first = hex16(d[o]) + ", " + hex16(d[o + 1]) + ": " + hex16(w) + " vs " + hex16(bits_of(g))
        total += bad
        print(names[fi], per, "cases,", bad, "mismatches (", nan_sign, "NaN payload/sign,", sbad, "special)", first)
    print("libm cases:", 27 * per, ", mismatches:", total)


def main() raises:
    rt_init()
    crt_init()
    rlib_init()
    var a = argv()
    var mode = String(a[1])
    if mode == "libm":
        libm_file(Int(String(a[2])), String(a[3]))
    elif mode == "printf":
        printf_file(String(a[2]))
    elif mode == "scanf":
        scanf_file(String(a[2]))
    elif mode == "misc":
        misc_file(String(a[2]))
    else:
        raise Error("mode")
