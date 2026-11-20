# libm_check.mojo - check the Mojo engine's math bit for bit against the system libm, on the vector files of
# tools/libm/test (mkvectors.c, mkedge.c, mkvectors2.c) and ruby/test/mkexact.c: records of name\0, n:u32, then
# n x (args..., result) as raw little-endian doubles. Each function is called the way the generated engine calls it
# (Math, LibM of rt/core.mojo), so the check covers the runtime's routing as well as the library. A NaN must match in
# sign and payload. fma, frexp and ldexp are skipped: the engine does not call them.
#   libm_check vectors.bin edge.bin vectors2.bin exact.bin
# Built by mojo/test/run_libm_tests.sh with the engine's flags. After zig/test/libm_check.zig.
# Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see ../README.md.
from std.sys import argv
from std.ffi import external_call
from rt.core import *
from rt.crt import *


def call(name: String, x: Float64, y: Float64) raises -> Float64:
    if name == "exp": return Math.Exp(x)
    if name == "log": return Math.Log(x)
    if name == "log10": return Math.Log10(x)
    if name == "pow": return Math.Pow(x, y)
    if name == "sin": return Math.Sin(x)
    if name == "cos": return Math.Cos(x)
    if name == "tan": return Math.Tan(x)
    if name == "asin": return Math.Asin(x)
    if name == "acos": return Math.Acos(x)
    if name == "atan": return Math.Atan(x)
    if name == "cbrt": return Math.Cbrt(x)
    if name == "hypot": return LibM.hypot(x, y)
    if name == "atan2": return Math.Atan2(x, y)
    if name == "cosh": return Math.Cosh(x)
    if name == "sinh": return Math.Sinh(x)
    if name == "tanh": return Math.Tanh(x)
    if name == "log2": return Math.Log2(x)
    if name == "expm1": return LibM.expm1(x)
    if name == "log1p": return LibM.log1p(x)
    if name == "sqrt": return Math.Sqrt(x)
    if name == "floor": return Math.Floor(x)
    if name == "ceil": return Math.Ceiling(x)
    if name == "trunc": return Math.Truncate(x)
    if name == "fabs": return Math.Abs(x)
    if name == "round": return LibM.round_(x)
    if name == "copysign": return Math.CopySign(x, y)
    raise Error("unknown function " + name)


def nargs(name: String) -> Int:
    if name == "pow" or name == "hypot" or name == "atan2" or name == "copysign":
        return 2
    if name == "fma":
        return -4
    if name == "frexp" or name == "ldexp":
        return -3
    return 1


def main() raises:
    rt_init()
    var args = argv()
    var total = 0
    var bad_all = 0
    for ai in range(1, len(args)):
        print("==", args[ai])
        var f = fopen(_cstr(String(args[ai])), rt_lit("rb").p)
        var size = Int(fsize_(f))
        var data = gc_atomic_bytes(size + 8).unsafe_bitcast[UInt8]()
        _ = fread(data.unsafe_bitcast[NoneType](), 1, UInt64(size), f)
        var p = 0
        while p < size:
            var name = String()
            while data[unsafe_offset=p] != 0:
                name += chr(Int(data[unsafe_offset=p]))
                p += 1
            p += 1
            var n = Int(P[UInt32](unsafe_from_address=Int(data) + p)[])
            p += 4
            var na = nargs(name)
            if na < 0:
                p += n * (-na) * 8
                print(name, "skipped (", n, "records; the engine does not call it)")
                continue
            var rec = na + 1
            var bad = 0
            var nan_sign = 0
            var nan_pay = 0
            for r in range(n):
                var o = Int(data) + p + r * rec * 8
                var x = P[Float64](unsafe_from_address=o)[]
                var y = P[Float64](unsafe_from_address=o + 8)[] if na > 1 else 0.0
                var wb = P[UInt64](unsafe_from_address=o + 8 * na)[]
                var gb = bits_of(call(name, x, y))
                if gb == wb:
                    continue
                var gv = f64_bits(gb)
                var wv = f64_bits(wb)
                if gv != gv and wv != wv:
                    if (gb >> 63) != (wb >> 63):
                        nan_sign += 1
                    else:
                        nan_pay += 1
                else:
                    bad += 1
                    if bad <= 4:
                        print("  ", name, hex(bits_of(x)), hex(bits_of(y)), "=", hex(gb), "libm", hex(wb))
            p += n * rec * 8
            total += n
            bad_all += bad + nan_sign + nan_pay
            print(name, bad, "of", n, "differ,", nan_sign, "NaN sign,", nan_pay, "NaN payload")
    print("records checked:", total)
    print("total mismatches:", bad_all)


def _cstr(s: String) -> P[Int8]:
    var b = s.as_bytes()
    var p = gc_atomic_bytes(len(b) + 1).unsafe_bitcast[Int8]()
    for k in range(len(b)):
        p[unsafe_offset=k] = Int8(b[k])
    return p
