# rlib.mojo - the C# runtime's static class R (the C library as the engine calls it: stdio files, printf and
# sscanf, C strings, buffers, time, the environment), CFile, std::from_chars and the rest of Std.
# After cs/runtime/CRuntime.cs, Fs.cs and Misc.cs, over the C library of crt.mojo.
# Written by Claude (Anthropic) for the SWMM6 ports; see ../README.md and ../../AI-USE.md.

from std.ffi import external_call
from std.sys import size_of
from rt.core import *
from rt.crt import *
from rt.str import *
from rt.cont import *


struct CFile(EStruct):
    """a C FILE*: the stdio stream of crt.mojo, and its place in the list of open files (exit flushes them)"""
    var f: P[FILE]
    var next: Ref[CFile]
    var dir: Bool

    def write_raw(mut self, p: P[UInt8], n: Int, size: UInt64, count: UInt64) raises -> UInt64:
        if n != 0:
            _ = fwrite(p.unsafe_bitcast[NoneType](), UInt64(1), UInt64(n), self.f)
        return count

    def read_raw(mut self, p: P[UInt8], size: UInt64, count: UInt64) raises -> UInt64:
        if size * count == 0:
            return 0
        return fread(p.unsafe_bitcast[NoneType](), size, count, self.f)


def _std_file(fd: Int32) -> Ref[CFile]:
    var c = Ref[CFile](gc_new[CFile]())
    var f = calloc(1, UInt64(size_of[FILE]())).unsafe_bitcast[FILE]()
    f[].fd = fd
    f[].std = 1
    c[].f = f
    return c


def rlib_init():
    var s = rts()
    s[].stdout_ = _std_file(1).vp()
    s[].stderr_ = _std_file(2).vp()
    s[].stdin_ = _std_file(0).vp()
    crt_state()[].stdout = Ref[CFile](P[CFile](unsafe_from_address=Int(s[].stdout_)))[].f


def r_stdout() -> Ref[CFile]:
    return Ref[CFile](P[CFile](unsafe_from_address=Int(rts()[].stdout_)))


def r_stderr() -> Ref[CFile]:
    return Ref[CFile](P[CFile](unsafe_from_address=Int(rts()[].stderr_)))


def flush_all():
    """what C's exit() does to open streams: flush every one (stdout and stderr too)"""
    var c = Ref[CFile](P[CFile](unsafe_from_address=rts()[].open_files))
    while not c.isnull():
        _ = fflush(c[].f)
        c = c[].next
    _ = fflush(r_stdout()[].f)
    _ = fflush(r_stderr()[].f)


def _cstr_eq(a: CPtr, s: StaticString) -> Bool:
    var b = s.unsafe_ptr()
    for i in range(s.byte_length()):
        if a.p[unsafe_offset=i] != Int8(b[i]):
            return False
    return a.p[unsafe_offset=s.byte_length()] == 0


struct R:
    # ---------------------------------------------------------------- standard streams
    @staticmethod
    def s_stdout_() -> Ref[CFile]:
        return r_stdout()

    @staticmethod
    def s_stderr_() -> Ref[CFile]:
        return r_stderr()

    # ---------------------------------------------------------------- buffers
    @staticmethod
    def Buf(n: Int32) raises -> CPtr:
        return CPtr(gc_atomic_bytes(max(Int(n), 1)).unsafe_bitcast[Int8]())

    @staticmethod
    def Buf(n: Int64) raises -> CPtr:
        return R.Buf(Int32(Int(n)))

    @staticmethod
    def Buf(n: UInt64) raises -> CPtr:
        return R.Buf(Int32(Int(n)))

    @staticmethod
    def Bufs(n: Int32, m: Int32) raises -> Ary[CPtr]:
        var r = Ary[CPtr].make(Int(n))
        for i in range(Int(n)):
            r[i] = R.Buf(m)
        return r

    @staticmethod
    def BufOf(n: Int32, vals: Ary[Int32]) raises -> CPtr:
        var m = max(Int(n), 1)
        var b = gc_atomic_bytes(m).unsafe_bitcast[Int8]()
        for i in range(min(vals.n, m)):
            b[unsafe_offset=i] = vals[i].cast[DType.int8]()
        return CPtr(b)

    @staticmethod
    def CopyBuf(p: CPtr) raises -> CPtr:
        """a copy of a buffer the runtime made (its length is in the collector's block)"""
        if p.isnull():
            return p
        var n = external_call["GC_size", Int](p.p.unsafe_bitcast[NoneType]())
        var base = external_call["GC_base", Int](p.p.unsafe_bitcast[NoneType]())
        var off = Int(p.p) - base
        var b = gc_atomic_bytes(n)
        _ = external_call["memcpy", VP](b, VP(unsafe_from_address=base), n)
        return CPtr(P[Int8](unsafe_from_address=Int(b) + off))

    @staticmethod
    def memcpyBuf(d: CPtr, s: CPtr) raises:
        var dn = external_call["GC_size", Int](d.p.unsafe_bitcast[NoneType]()) - (Int(d.p) - external_call["GC_base", Int](d.p.unsafe_bitcast[NoneType]()))
        var sn = external_call["GC_size", Int](s.p.unsafe_bitcast[NoneType]()) - (Int(s.p) - external_call["GC_base", Int](s.p.unsafe_bitcast[NoneType]()))
        _ = external_call["memmove", VP](d.p.unsafe_bitcast[NoneType](), s.p.unsafe_bitcast[NoneType](), min(dn, sn))

    # ---------------------------------------------------------------- printf and scanf
    @staticmethod
    def fprintf(f: Ref[CFile], fmt: CPtr, *args: Arg) raises -> Int32:
        var o = List[UInt8]()
        format(o, fmt.p, args)
        fwrite_bytes(f[].f, o)
        return Int32(len(o))

    @staticmethod
    def snprintf(buf: CPtr, n: UInt64, fmt: CPtr, *args: Arg) raises -> Int32:
        var o = List[UInt8]()
        format(o, fmt.p, args)
        if n > 0:
            var m = min(Int(n) - 1, len(o))
            for i in range(m):
                buf.p[unsafe_offset=i] = Int8(o[i])
            buf.p[unsafe_offset=m] = 0
        return Int32(len(o))

    @staticmethod
    def snprintf(buf: CPtr, n: Int64, fmt: CPtr, *args: Arg) raises -> Int32:
        var o = List[UInt8]()
        format(o, fmt.p, args)
        if n > 0:
            var m = min(Int(n) - 1, len(o))
            for i in range(m):
                buf.p[unsafe_offset=i] = Int8(o[i])
            buf.p[unsafe_offset=m] = 0
        return Int32(len(o))

    @staticmethod
    def snprintf(buf: CPtr, n: Int32, fmt: CPtr, *args: Arg) raises -> Int32:
        var o = List[UInt8]()
        format(o, fmt.p, args)
        if n > 0:
            var m = min(Int(n) - 1, len(o))
            for i in range(m):
                buf.p[unsafe_offset=i] = Int8(o[i])
            buf.p[unsafe_offset=m] = 0
        return Int32(len(o))

    @staticmethod
    def sscanf(s: CPtr, fmt: CPtr, *args: Arg) raises -> Int32:
        return sscanf_list(s.p, fmt.p, args)

    # ---------------------------------------------------------------- files
    @staticmethod
    def fopen(name: CPtr, mode: CPtr) raises -> Ref[CFile]:
        var f = fopen(name.p, mode.p)
        if isnull(f):
            return Ref[CFile]()
        var c = Ref[CFile](gc_new[CFile]())
        c[].f = f
        c[].next = Ref[CFile](P[CFile](unsafe_from_address=rts()[].open_files))
        rts()[].open_files = Int(c.p)
        return c

    @staticmethod
    def fclose(f: Ref[CFile]) raises -> Int32:
        if f.isnull():
            return -1
        if f[].f[].std != 0:
            _ = fflush(f[].f)
            return 0
        # off the list of open files
        var prev = Ref[CFile]()
        var c = Ref[CFile](P[CFile](unsafe_from_address=rts()[].open_files))
        while not c.isnull():
            if c == f:
                if prev.isnull():
                    rts()[].open_files = Int(c[].next.p)
                else:
                    prev[].next = c[].next
                break
            prev = c
            c = c[].next
        return fclose(f[].f)

    @staticmethod
    def fflush(f: Ref[CFile]) raises -> Int32:
        if not f.isnull():
            _ = fflush(f[].f)
        return 0

    @staticmethod
    def feof(f: Ref[CFile]) raises -> Int32:
        return Int32(1) if f[].f[].eof != 0 else Int32(0)

    @staticmethod
    def ferror(f: Ref[CFile]) raises -> Int32:
        return Int32(1) if (not f.isnull() and f[].f[].err != 0) else Int32(0)

    @staticmethod
    def rewind(f: Ref[CFile]) raises:
        rewind(f[].f)

    @staticmethod
    def fseek(f: Ref[CFile], off: Int64, whence: Int32) raises -> Int32:
        return fseek(f[].f, off, whence)

    @staticmethod
    def fseek(f: Ref[CFile], off: Int32, whence: Int32) raises -> Int32:
        return fseek(f[].f, Int64(off), whence)

    @staticmethod
    def ftell(f: Ref[CFile]) raises -> Int64:
        return ftell(f[].f)

    @staticmethod
    def fgets(buf: CPtr, n: Int32, f: Ref[CFile]) raises -> CPtr:
        return CPtr(fgets(buf.p, n, f[].f))

    @staticmethod
    def fgetc(f: Ref[CFile]) raises -> Int32:
        var c = getc_(f[].f)
        if c < 0:
            if f[].f[].err == 0:
                f[].f[].eof = 1
        return Int32(c)

    @staticmethod
    def fileno(f: Ref[CFile]) raises -> Int32:
        return 3

    @staticmethod
    def setvbuf(f: Ref[CFile], b: CPtr, mode: Int32, size: UInt64) raises -> Int32:
        return 0

    @staticmethod
    def fwriteF1(v: Float32, f: Ref[CFile]) raises -> UInt64:
        # through a slot on the runtime's stack: a Mojo local whose address goes to a Mojo function may never be
        # written (swmm5-ports lessons/42; lessons/78)
        var sp = rt_sp()
        var b = rt_salloc[Float32]()
        b[] = v
        _ = fwrite(b.unsafe_bitcast[NoneType](), 4, 1, f[].f)
        rt_set_sp(sp)
        return 1

    @staticmethod
    def fwriteD1(v: Float64, f: Ref[CFile]) raises -> UInt64:
        # through a slot on the runtime's stack: a Mojo local whose address goes to a Mojo function may never be
        # written (swmm5-ports lessons/42; lessons/78)
        var sp = rt_sp()
        var b = rt_salloc[Float64]()
        b[] = v
        _ = fwrite(b.unsafe_bitcast[NoneType](), 8, 1, f[].f)
        rt_set_sp(sp)
        return 1

    @staticmethod
    def fwriteI1(v: Int32, f: Ref[CFile]) raises -> UInt64:
        # through a slot on the runtime's stack: a Mojo local whose address goes to a Mojo function may never be
        # written (swmm5-ports lessons/42; lessons/78)
        var sp = rt_sp()
        var b = rt_salloc[Int32]()
        b[] = v
        _ = fwrite(b.unsafe_bitcast[NoneType](), 4, 1, f[].f)
        rt_set_sp(sp)
        return 1

    @staticmethod
    def freadF1(v: P[Float32], f: Ref[CFile]) raises -> UInt64:
        var t = gc_atomic_bytes(8)
        if fread(t, 1, 4, f[].f) != 4:
            return 0
        v[] = t.unsafe_bitcast[Float32]()[]
        return 1

    @staticmethod
    def freadD1(v: P[Float64], f: Ref[CFile]) raises -> UInt64:
        var t = gc_atomic_bytes(8)
        if fread(t, 1, 8, f[].f) != 8:
            return 0
        v[] = t.unsafe_bitcast[Float64]()[]
        return 1

    @staticmethod
    def freadI1(v: P[Int32], f: Ref[CFile]) raises -> UInt64:
        var t = gc_atomic_bytes(8)
        if fread(t, 1, 4, f[].f) != 4:
            return 0
        v[] = t.unsafe_bitcast[Int32]()[]
        return 1

    # ---------------------------------------------------------------- C strings
    @staticmethod
    def strlen(p: CPtr) raises -> UInt64:
        return UInt64(cslen(p))

    @staticmethod
    def strcmp(a: CPtr, b: CPtr) raises -> Int32:
        return strcmp(a.p, b.p)

    @staticmethod
    def strncmp(a: CPtr, b: CPtr, n: UInt64) raises -> Int32:
        for i in range(Int(n)):
            var x = Int32(a.u8()[unsafe_offset=i])
            var y = Int32(b.u8()[unsafe_offset=i])
            if x != y:
                return x - y
            if x == 0:
                return 0
        return 0

    @staticmethod
    def memcmp(a: CPtr, b: CPtr, n: UInt64) raises -> Int32:
        for i in range(Int(n)):
            var x = Int32(a.u8()[unsafe_offset=i])
            var y = Int32(b.u8()[unsafe_offset=i])
            if x != y:
                return x - y
        return 0

    @staticmethod
    def strncpy(d: CPtr, s: CPtr, n: UInt64) raises -> CPtr:
        var i = 0
        while i < Int(n) and s.p[unsafe_offset=i] != 0:
            d.p[unsafe_offset=i] = s.p[unsafe_offset=i]
            i += 1
        while i < Int(n):
            d.p[unsafe_offset=i] = 0
            i += 1
        return d

    @staticmethod
    def strchr(p: CPtr, c: Int32) raises -> CPtr:
        return CPtr(strchr(p.p, c))

    @staticmethod
    def strrchr(p: CPtr, c: Int32) raises -> CPtr:
        return CPtr(strrchr(p.p, c))

    @staticmethod
    def strstr(h: CPtr, n: CPtr) raises -> CPtr:
        return CPtr(strstr(h.p, n.p))

    @staticmethod
    def strtok(p: CPtr, d: CPtr) raises -> CPtr:
        return CPtr(strtok(p.p, d.p))

    @staticmethod
    def strtod(s: CPtr) raises -> Float64:
        var e = gc_new[P[Int8]]()
        return strtod(s.p, e)

    @staticmethod
    def strtod(s: CPtr, end: P[CPtr]) raises -> Float64:
        var e = gc_new[P[Int8]]()
        var v = strtod(s.p, e)
        end[] = CPtr(e[])
        return v

    @staticmethod
    def atof(s: CPtr) raises -> Float64:
        return R.strtod(s)

    @staticmethod
    def strtol(s: CPtr, end: P[CPtr], b: Int32) raises -> Int64:
        """base 10, saturating at the long range, as the C# runtime's"""
        var i = 0
        var u = s.u8()
        while u[unsafe_offset=i] == 32 or (u[unsafe_offset=i] >= 9 and u[unsafe_offset=i] <= 13):
            i += 1
        var neg = False
        if u[unsafe_offset=i] == 43 or u[unsafe_offset=i] == 45:
            neg = u[unsafe_offset=i] == 45
            i += 1
        var st = i
        var v: UInt64 = 0
        var over = False
        while u[unsafe_offset=i] >= 48 and u[unsafe_offset=i] <= 57:
            var d = UInt64(Int(u[unsafe_offset=i]) - 48)
            if v > (UInt64(0xFFFFFFFFFFFFFFFF) - d) // 10:
                over = True
            else:
                v = v * 10 + d
            i += 1
        if i == st:
            end[] = s
            return 0
        end[] = s.add(i)
        if neg:
            if over or v > UInt64(0x8000000000000000):
                return Int64(-9223372036854775807) - 1
            return -(v.cast[DType.int64]())
        if over or v > UInt64(0x7FFFFFFFFFFFFFFF):
            return Int64(9223372036854775807)
        return v.cast[DType.int64]()

    @staticmethod
    def strtol0(s: CPtr, b: Int32) raises -> Int64:
        var e = gc_new[CPtr]()
        return R.strtol(s, e, b)

    @staticmethod
    def atol(s: CPtr) raises -> Int64:
        return R.strtol0(s, 10)

    @staticmethod
    def atoi(s: CPtr) raises -> Int32:
        return R.strtol0(s, 10).cast[DType.int32]()

    @staticmethod
    def isdigit(c: Int32) raises -> Int32:
        return Int32(1) if (c >= 48 and c <= 57) else Int32(0)

    @staticmethod
    def isalpha(c: Int32) raises -> Int32:
        return Int32(1) if ((c >= 97 and c <= 122) or (c >= 65 and c <= 90)) else Int32(0)

    @staticmethod
    def isalnum(c: Int32) raises -> Int32:
        return Int32(1) if (R.isdigit(c) != 0 or R.isalpha(c) != 0) else Int32(0)

    @staticmethod
    def isspace(c: Int32) raises -> Int32:
        return Int32(1) if (c == 32 or (c >= 9 and c <= 13)) else Int32(0)

    @staticmethod
    def toupper(c: Int32) raises -> Int32:
        return c - 32 if (c >= 97 and c <= 122) else c

    @staticmethod
    def tolower(c: Int32) raises -> Int32:
        return c + 32 if (c >= 65 and c <= 90) else c

    @staticmethod
    def getenv(name: CPtr) raises -> CPtr:
        return CPtr(external_call["getenv", P[Int8]](name.p))

    # ---------------------------------------------------------------- time
    @staticmethod
    def time(p: Ptr[Int64]) raises -> Int64:
        var t = Int64(external_call["time", Int](Int(0)))
        if not p.isnull():
            p.p[] = t
        return t

    @staticmethod
    def difftime(a: Int64, b: Int64) raises -> Float64:
        return Float64(a - b)

    @staticmethod
    def ctime(p: Ptr[Int64]) raises -> CPtr:
        """glibc's ctime in the local time zone (localtime_r and asctime's layout)"""
        var tm = gc_atomic_bytes(64).unsafe_bitcast[Int32]()
        _ = external_call["localtime_r", VP](p.p.unsafe_bitcast[NoneType](), tm.unsafe_bitcast[NoneType]())
        var buf = gc_atomic_bytes(64).unsafe_bitcast[Int8]()
        _ = external_call["asctime_r", VP](tm.unsafe_bitcast[NoneType](), buf.unsafe_bitcast[NoneType]())
        return CPtr(buf)


struct FromCharsResult(ImplicitlyCopyable):
    var ptr: CPtr
    var ec: Int32

    def __init__(out self):
        self.ptr = CPtr()
        self.ec = 0

    def __init__(out self, ptr: CPtr, ec: Int32):
        self.ptr = ptr
        self.ec = ec


def _int_chars(first: CPtr, last: CPtr, signed: Bool, mut r: Int64, mut ur: UInt64, mut neg: Bool, mut over: Bool) -> FromCharsResult:
    var i = 0
    var n = Int(last.p) - Int(first.p)
    var u = first.u8()
    if signed and i < n and u[unsafe_offset=i] == 45:
        neg = True
        i += 1
    var start = i
    while i < n and u[unsafe_offset=i] >= 48 and u[unsafe_offset=i] <= 57:
        var d = UInt64(Int(u[unsafe_offset=i]) - 48)
        if ur > (UInt64(0xFFFFFFFFFFFFFFFF) - d) // 10:
            over = True
        else:
            ur = ur * 10 + d
        i += 1
    if i == start:
        return FromCharsResult(first, 22)
    return FromCharsResult(first.add(i), 0)


struct Std:
    @staticmethod
    def s_QNaN() -> Float64:
        return f64_bits(0x7FF8000000000000)

    @staticmethod
    def Rethrow(e: Ref[CppException]) raises:
        raise rt_throw(e)

    @staticmethod
    def call_once[call: def(Dlg) raises thin](flag: Ref[OnceFlag], f: Dlg) raises:
        if flag[].done:
            return
        call(f)
        flag[].done = True

    @staticmethod
    def get0[A: Elem, B: Elem](p: Ref[Pair[A, B]]) raises -> P[A]:
        return rt_addr(p[].first)

    @staticmethod
    def get1[A: Elem, B: Elem](p: Ref[Pair[A, B]]) raises -> P[B]:
        return rt_addr(p[].second)

    @staticmethod
    def swap_[T: Elem](a: P[T], b: P[T]) raises:
        var t = a[]
        a[] = b[]
        b[] = t

    @staticmethod
    def from_chars(first: CPtr, last: CPtr, v: P[Float64]) raises -> FromCharsResult:
        """std::from_chars for double as libstdc++ has it (Misc.cs): no leading space or '+', no hexadecimal prefix,
        and an overflow or a nonzero number read as zero is result_out_of_range (34) with v unchanged"""
        var n = Int(last.p) - Int(first.p)
        var tmp = gc_atomic_bytes(n + 2).unsafe_bitcast[Int8]()
        for i in range(n):
            tmp[unsafe_offset=i] = first.p[unsafe_offset=i]
        var k = 1 if tmp[] == 45 else 0
        var c = Int(tmp[unsafe_offset=k])
        var lc = c + 32 if (c >= 65 and c <= 90) else c
        if not ((c >= 48 and c <= 57) or c == 46 or lc == 105 or lc == 110):
            return FromCharsResult(first, 22)
        if c == 48 and (tmp[unsafe_offset=k + 1] == 120 or tmp[unsafe_offset=k + 1] == 88):
            tmp[unsafe_offset=k + 1] = 0
        var e = gc_new[P[Int8]]()
        e[] = tmp
        var r = strtod(tmp, e)
        var used = Int(e[]) - Int(tmp)
        if used == 0:
            return FromCharsResult(first, 22)
        var res = FromCharsResult(first.add(used), 0)
        if Dbl.IsInfinity(r) and lc != 105:
            return FromCharsResult(res.ptr, 34)
        if r == 0.0:
            for j in range(k, used):
                var d = Int(tmp[unsafe_offset=j])
                if d == 101 or d == 69:
                    break
                if d >= 49 and d <= 57:
                    return FromCharsResult(res.ptr, 34)
        v[] = r
        return res

    @staticmethod
    def from_chars(first: CPtr, last: CPtr, v: P[Int32]) raises -> FromCharsResult:
        var r: Int64 = 0
        var ur: UInt64 = 0
        var neg = False
        var over = False
        var res = _int_chars(first, last, True, r, ur, neg, over)
        if res.ec != 0:
            return res
        if over or (not neg and ur > 2147483647) or (neg and ur > 2147483648):
            return FromCharsResult(res.ptr, 34)
        v[] = (-(ur.cast[DType.int64]())).cast[DType.int32]() if neg else ur.cast[DType.int32]()
        return res

    @staticmethod
    def from_chars(first: CPtr, last: CPtr, v: P[Int64]) raises -> FromCharsResult:
        var r: Int64 = 0
        var ur: UInt64 = 0
        var neg = False
        var over = False
        var res = _int_chars(first, last, True, r, ur, neg, over)
        if res.ec != 0:
            return res
        if over or (not neg and ur > UInt64(0x7FFFFFFFFFFFFFFF)) or (neg and ur > UInt64(0x8000000000000000)):
            return FromCharsResult(res.ptr, 34)
        v[] = (UInt64(0) - ur).cast[DType.int64]() if neg else ur.cast[DType.int64]()
        return res

    @staticmethod
    def from_chars(first: CPtr, last: CPtr, v: P[UInt32]) raises -> FromCharsResult:
        var r: Int64 = 0
        var ur: UInt64 = 0
        var neg = False
        var over = False
        var res = _int_chars(first, last, False, r, ur, neg, over)
        if res.ec != 0:
            return res
        if over or ur > 4294967295:
            return FromCharsResult(res.ptr, 34)
        v[] = ur.cast[DType.uint32]()
        return res

    @staticmethod
    def from_chars(first: CPtr, last: CPtr, v: P[UInt64]) raises -> FromCharsResult:
        var r: Int64 = 0
        var ur: UInt64 = 0
        var neg = False
        var over = False
        var res = _int_chars(first, last, False, r, ur, neg, over)
        if res.ec != 0:
            return res
        if over:
            return FromCharsResult(res.ptr, 34)
        v[] = ur
        return res


struct Mem:
    @staticmethod
    def Diff[T: Elem](obj: T, p: Ptr[T]) raises -> Int64:
        """&obj - p: the index of an object in an array of objects (pointers to objects are references)"""
        var i = 0
        while not elem_eq(p.p[unsafe_offset=i], obj):
            i += 1
        return Int64(i)

    @staticmethod
    def Calloc[T: Elem](n: UInt64, size: UInt64) raises -> Ptr[T]:
        return Ptr[T](gc_array[T](Int(n * size) // size_of[T]()))

    @staticmethod
    def Free(p: Obj) raises:
        pass

    @staticmethod
    def Free[T: Elem](p: T) raises:
        pass

    @staticmethod
    def memcpy[T: Elem, U: Elem](d: Ptr[T], s: Ptr[U], n: UInt64) raises -> Ptr[T]:
        if n != 0:
            _ = external_call["memcpy", VP](d.p.unsafe_bitcast[NoneType](), s.p.unsafe_bitcast[NoneType](), Int(n))
        return d

    @staticmethod
    def memcpy[T: Elem](d: Ptr[T], s: CPtr, n: UInt64) raises -> Ptr[T]:
        if n != 0:
            _ = external_call["memcpy", VP](d.p.unsafe_bitcast[NoneType](), s.p.unsafe_bitcast[NoneType](), Int(n))
        return d

    @staticmethod
    def fwrite[T: Elem](p: Ptr[T], size: UInt64, count: UInt64, f: Ref[CFile]) raises -> UInt64:
        return f[].write_raw(p.p.unsafe_bitcast[UInt8](), Int(size * count), size, count)

    @staticmethod
    def fwrite(p: CPtr, size: UInt64, count: UInt64, f: Ref[CFile]) raises -> UInt64:
        return f[].write_raw(p.u8(), Int(size * count), size, count)

    @staticmethod
    def fread[T: Elem](p: Ptr[T], size: UInt64, count: UInt64, f: Ref[CFile]) raises -> UInt64:
        return f[].read_raw(p.p.unsafe_bitcast[UInt8](), size, count)

    @staticmethod
    def fread(p: CPtr, size: UInt64, count: UInt64, f: Ref[CFile]) raises -> UInt64:
        return f[].read_raw(p.u8(), size, count)


