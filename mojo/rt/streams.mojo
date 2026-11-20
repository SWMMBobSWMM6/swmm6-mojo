# streams.mojo - the C++ iostreams the engine uses: input streams over a file read whole at open or over a string
# (num_get's rules for numbers, lessons/23), output streams to a file or into memory, with libstdc++'s formatting of
# numbers (printf's %g, %f, %e at the stream's precision). After zig/rt/streams.zig and cs/runtime/Streams.cs.
# Written by Claude (Anthropic) for the SWMM6 ports; see ../README.md and ../../AI-USE.md.

from std.ffi import external_call
from rt.core import *
from rt.crt import *
from rt.str import *
from rt.cont import *
from rt.rlib import *
from rt.fs import *

comptime IOS_APP = Int32(1)
comptime IOS_BOOLALPHA = Int32(1)
comptime IOS_FIXED = Int32(4)
comptime IOS_LEFT = Int32(32)
comptime IOS_SCIENTIFIC = Int32(256)
comptime IOS_SHOWPOINT = Int32(1024)


@always_inline
def is_ws(c: UInt8) -> Bool:
    return c == 32 or c == 9 or c == 10 or c == 13 or c == 11 or c == 12


struct IStream(EStruct):
    var failbit: Bool
    var eofbit: Bool
    var badbit: Bool
    var prec: Int64
    var buf: P[UInt8]
    var len: Int
    var pos: Int
    var gcountv: Int64
    var is_file: Bool
    var opened: Bool
    var dir: Bool

    @staticmethod
    def make() -> Ref[IStream]:
        var s = Ref[IStream](gc_new[IStream]())
        s[].prec = 6
        s[].buf = gc_atomic_bytes(1).unsafe_bitcast[UInt8]()
        return s

    # the constructors of std::istringstream and std::ifstream
    @staticmethod
    def new_IStringStream(s: Ref[Str]) raises -> Ref[IStream]:
        var x = IStream.make()
        x[].str_(s)
        return x

    @staticmethod
    def new_IStringStream(s: Ref[Str], mode: Int32) raises -> Ref[IStream]:
        return IStream.new_IStringStream(s)

    @staticmethod
    def new_IStringStream() raises -> Ref[IStream]:
        return IStream.make()

    @staticmethod
    def new_IFStream() raises -> Ref[IStream]:
        var x = IStream.make()
        x[].is_file = True
        return x

    @staticmethod
    def new_IFStream(path: Ref[Str], mode: Int32) raises -> Ref[IStream]:
        var x = IStream.new_IFStream()
        x[].open(path, mode)
        return x

    @staticmethod
    def new_IFStream(path: CPtr, mode: Int32) raises -> Ref[IStream]:
        return IStream.new_IFStream(Str.new_(path), mode)

    @staticmethod
    def new_IFStream(path: Ref[FsPath], mode: Int32) raises -> Ref[IStream]:
        return IStream.new_IFStream(path[].p, mode)

    @staticmethod
    def __dispose(x: Ref[IStream]) raises:
        if x[].is_file:
            x[].close()

    def good(self) raises -> Bool:
        return not self.failbit and not self.eofbit and not self.badbit

    def fail(self) raises -> Bool:
        return self.failbit or self.badbit

    def bad(self) raises -> Bool:
        return self.badbit

    def eof(self) raises -> Bool:
        return self.eofbit

    def ok(self) raises -> Bool:
        return not (self.failbit or self.badbit)

    def notok(self) raises -> Bool:
        return self.failbit or self.badbit

    def clear(mut self, s: Int32) raises:
        self.failbit = False
        self.eofbit = False
        self.badbit = False

    def imbue[T: Elem](mut self, l: T) raises:
        pass

    def fill(mut self) -> Bool:
        if self.pos < self.len:
            return True
        if self.dir:
            self.badbit = True
            self.failbit = True
        return False

    def at_end(mut self):
        if not self.dir:
            self.eofbit = True

    def peek(mut self) raises -> Int32:
        if not self.fill():
            self.at_end()
            return -1
        return Int32(self.buf[unsafe_offset=self.pos])

    def get(mut self) raises -> Int32:
        if not self.fill():
            self.at_end()
            self.failbit = True
            return -1
        self.gcountv = 1
        self.pos += 1
        return Int32(self.buf[unsafe_offset=self.pos - 1])

    def gcount(self) raises -> Int64:
        return self.gcountv

    def me(mut self) -> Ref[IStream]:
        return Ref[IStream](rt_addr(self))

    def read_(mut self, p: CPtr, n: Int64) raises -> Ref[IStream]:
        var avail = self.len - min(self.pos, self.len)
        var k = min(Int(n), avail)
        for i in range(k):
            p.u8()[unsafe_offset=i] = self.buf[unsafe_offset=self.pos + i]
        self.pos += k
        self.gcountv = Int64(k)
        if k < Int(n):
            if self.dir:
                self.badbit = True
            self.at_end()
            self.failbit = True
        return self.me()

    def read_[T: Elem](mut self, p: Ptr[T], n: Int64) raises -> Ref[IStream]:
        return self.read_(CPtr(p.p.unsafe_bitcast[Int8]()), n)

    def read_line(mut self, s: Ref[Str], delim: UInt8) raises -> Bool:
        s[].clear()
        var any = False
        while True:
            if not self.fill():
                self.at_end()
                if not any:
                    self.failbit = True
                return any
            var c = self.buf[unsafe_offset=self.pos]
            self.pos += 1
            any = True
            if c == delim:
                return True
            s[].push_back(Int32(c))

    def skip_ws(mut self):
        while self.fill() and is_ws(self.buf[unsafe_offset=self.pos]):
            self.pos += 1

    def token(mut self) raises -> Ref[Str]:
        self.skip_ws()
        var t = Str.new_()
        while self.fill() and not is_ws(self.buf[unsafe_offset=self.pos]):
            t[].push_back(Int32(self.buf[unsafe_offset=self.pos]))
            self.pos += 1
        if t[].n == 0:
            self.failbit = True
            if not self.fill():
                self.at_end()
        elif not self.fill():
            self.at_end()
        return t

    def Get(mut self, s: Ref[Str]) raises -> Ref[IStream]:
        var t = self.token()
        if t[].n > 0:
            s[].Assign(t)
        return self.me()

    def Manip_ws(mut self) raises -> Ref[IStream]:
        while True:
            if not self.fill():
                self.at_end()
                break
            var c = self.buf[unsafe_offset=self.pos]
            if c == 32 or (c >= 9 and c <= 13):
                self.pos += 1
            else:
                break
        return self.me()

    def next_c(mut self, mut more: Bool, mut ch: Int):
        self.pos += 1
        more = self.fill()
        ch = Int(self.buf[unsafe_offset=self.pos]) if more else -1

    def Get(mut self, v: P[Float64]) raises -> Ref[IStream]:
        """num_get for a double: the characters a number can have, then strtod (an overflow is a failure that
        stores the largest double, lessons/23)"""
        if not self.good():
            self.failbit = True
            return self.me()
        self.skip_ws()
        if not self.fill():
            self.at_end()
            self.failbit = True
            return self.me()
        var acc = List[UInt8]()
        var more = True
        var c = Int(self.buf[unsafe_offset=self.pos])
        if c == 43 or c == 45:
            acc.append(UInt8(c))
            self.next_c(more, c)
        var mantissa = False
        var dec = False
        var sci = False
        while more and c == 48:
            if not mantissa:
                acc.append(48)
                mantissa = True
            self.next_c(more, c)
        while more:
            if c >= 48 and c <= 57:
                acc.append(UInt8(c))
                mantissa = True
            elif c == 46 and not dec and not sci:
                acc.append(46)
                dec = True
            elif (c == 101 or c == 69) and not sci and mantissa:
                acc.append(101)
                sci = True
                self.next_c(more, c)
                if not more:
                    break
                if c == 43 or c == 45:
                    acc.append(UInt8(c))
                else:
                    continue
            else:
                break
            self.next_c(more, c)
        if not more:
            self.at_end()
        acc.append(0)
        var b = gc_atomic_bytes(len(acc)).unsafe_bitcast[Int8]()
        for i in range(len(acc)):
            b[unsafe_offset=i] = Int8(acc[i])
        var e = gc_new[P[Int8]]()
        e[] = b
        var r = strtod(b, e)
        var used = Int(e[]) - Int(b)
        if used == 0 or acc[used] != 0:
            v[] = 0.0
            self.failbit = True
        elif r == Float64(1.0) / Float64(0.0):
            v[] = 1.7976931348623157e308
            self.failbit = True
        elif r == -Float64(1.0) / Float64(0.0):
            v[] = -1.7976931348623157e308
            self.failbit = True
        else:
            v[] = r
        return self.me()

    def Get(mut self, v: P[Float32]) raises -> Ref[IStream]:
        var d = gc_new[Float64]()
        _ = self.Get(d)
        v[] = d[].cast[DType.float32]()
        return self.me()

    def get_long(mut self, mut ok: Bool) raises -> Int64:
        var t = self.token()
        ok = False
        if t[].n == 0:
            return 0
        var p = t[].cstr()
        var e = gc_new[CPtr]()
        var r = R.strtol(p, e, 10)
        ok = Int(e[].p) - Int(p.p) == Int(t[].n)
        return r

    def Get(mut self, v: P[Int32]) raises -> Ref[IStream]:
        var t = self.token()
        if t[].n == 0:
            v[] = 0
            return self.me()
        var p = t[].cstr()
        var e = gc_new[CPtr]()
        var r = R.strtol(p, e, 10)
        if Int(e[].p) - Int(p.p) != Int(t[].n) or r < -2147483648 or r > 2147483647:
            self.failbit = True
            v[] = Int32(-2147483648) if r < -2147483648 else (Int32(2147483647) if r > 2147483647 else Int32(0))
            return self.me()
        v[] = r.cast[DType.int32]()
        return self.me()

    def Get(mut self, v: P[Int64]) raises -> Ref[IStream]:
        var t = self.token()
        if t[].n == 0:
            v[] = 0
            return self.me()
        var p = t[].cstr()
        var e = gc_new[CPtr]()
        var r = R.strtol(p, e, 10)
        if Int(e[].p) - Int(p.p) != Int(t[].n):
            self.failbit = True
            v[] = 0
            return self.me()
        v[] = r
        return self.me()

    def Get(mut self, v: P[UInt64]) raises -> Ref[IStream]:
        var x = gc_new[Int64]()
        _ = self.Get(x)
        v[] = x[].cast[DType.uint64]()
        return self.me()

    def Get(mut self, v: P[UInt32]) raises -> Ref[IStream]:
        var x = gc_new[Int64]()
        _ = self.Get(x)
        v[] = x[].cast[DType.uint32]()
        return self.me()

    def tellg(self) raises -> Int64:
        return Int64(self.pos)

    def seekg(mut self, off: Int64, dir: Int32) raises -> Ref[IStream]:
        self.eofbit = False
        var base = 0 if dir == 0 else (self.pos if dir == 1 else self.len)
        var np = base + Int(off)
        if np < 0:
            self.failbit = True
            return self.me()
        self.pos = np
        return self.me()

    def str_(mut self) raises -> Ref[Str]:
        return Str.of_bytes(self.buf, self.len)

    def str_(mut self, s: Ref[Str]) raises:
        var c = Str.__clone(s)
        self.buf = c[].b.p
        self.len = Int(c[].n)
        self.pos = 0
        self.failbit = False
        self.eofbit = False

    def open(mut self, path: Ref[Str], mode: Int32) raises:
        """read the whole file at open; a directory opens, and its first read fails (lessons/24)"""
        self.pos = 0
        var k = kind_of(path)
        if k == K_DIRECTORY:
            self.buf = gc_atomic_bytes(1).unsafe_bitcast[UInt8]()
            self.len = 0
            self.dir = True
            self.opened = True
            self.failbit = False
            return
        var f = fopen(path[].cstr().p, rt_lit("rb").p)
        if isnull(f):
            self.buf = gc_atomic_bytes(1).unsafe_bitcast[UInt8]()
            self.len = 0
            self.opened = False
            self.failbit = True
            return
        var cap = 65536
        var b = gc_atomic_bytes(cap).unsafe_bitcast[UInt8]()
        var n = 0
        while True:
            if n == cap:
                var nb = gc_atomic_bytes(cap * 2).unsafe_bitcast[UInt8]()
                _ = external_call["memcpy", VP](nb.unsafe_bitcast[NoneType](), b.unsafe_bitcast[NoneType](), n)
                b = nb
                cap *= 2
            var got = fread(padd(b, n).unsafe_bitcast[NoneType](), 1, UInt64(cap - n), f)
            if got == 0:
                break
            n += Int(got)
        _ = fclose(f)
        self.buf = b
        self.len = n
        self.dir = False
        self.opened = True
        self.failbit = False

    def open(mut self, path: Ref[FsPath], mode: Int32) raises:
        self.open(path[].p, mode)

    def is_open(self) raises -> Bool:
        return self.opened

    def close(mut self) raises:
        self.opened = False
        self.dir = False

    def MoveFrom(mut self, o: Ref[IStream]) raises:
        self.failbit = o[].failbit
        self.eofbit = o[].eofbit
        self.badbit = o[].badbit
        self.prec = o[].prec
        self.buf = o[].buf
        self.len = o[].len
        self.pos = o[].pos
        self.gcountv = o[].gcountv
        self.is_file = o[].is_file
        self.opened = o[].opened
        self.dir = o[].dir
        o[].opened = False
        o[].dir = False


struct OStream(EStruct):
    var failbit: Bool
    var eofbit: Bool
    var badbit: Bool
    var prec: Int64
    var flagsv: Int32
    var widthv: Int64
    var fillc: Int32
    var file: Ref[CFile]
    var mem: P[UInt8]
    var mlen: Int
    var mcap: Int
    var is_mem: Bool

    @staticmethod
    def make() -> Ref[OStream]:
        var s = Ref[OStream](gc_new[OStream]())
        s[].prec = 6
        s[].fillc = 32
        return s

    @staticmethod
    def new_OStringStream() raises -> Ref[OStream]:
        var s = OStream.make()
        s[].is_mem = True
        return s

    @staticmethod
    def new_OStringStream(mode: Int32) raises -> Ref[OStream]:
        return OStream.new_OStringStream()

    @staticmethod
    def new_OStringStream(init: Ref[Str]) raises -> Ref[OStream]:
        var s = OStream.new_OStringStream()
        s[].str_(init)
        return s

    @staticmethod
    def new_OFStream() raises -> Ref[OStream]:
        return OStream.make()

    @staticmethod
    def new_OFStream(path: Ref[Str], mode: Int32) raises -> Ref[OStream]:
        var s = OStream.make()
        s[].open(path, mode)
        return s

    @staticmethod
    def new_OFStream(path: CPtr, mode: Int32) raises -> Ref[OStream]:
        return OStream.new_OFStream(Str.new_(path), mode)

    @staticmethod
    def new_OFStream(path: Ref[FsPath], mode: Int32) raises -> Ref[OStream]:
        return OStream.new_OFStream(path[].p, mode)

    @staticmethod
    def __dispose(x: Ref[OStream]) raises:
        if not x[].is_mem:
            x[].close()

    def me(mut self) -> Ref[OStream]:
        return Ref[OStream](rt_addr(self))

    def good(self) raises -> Bool:
        return not self.failbit and not self.eofbit and not self.badbit

    def fail(self) raises -> Bool:
        return self.failbit or self.badbit

    def bad(self) raises -> Bool:
        return self.badbit

    def eof(self) raises -> Bool:
        return self.eofbit

    def ok(self) raises -> Bool:
        return not (self.failbit or self.badbit)

    def notok(self) raises -> Bool:
        return self.failbit or self.badbit

    def clear(mut self, s: Int32) raises:
        self.failbit = False
        self.eofbit = False
        self.badbit = False

    def imbue[T: Elem](mut self, l: T) raises:
        pass

    def raw(mut self, b: P[UInt8], n: Int) raises:
        if not self.file.isnull():
            _ = fwrite(b.unsafe_bitcast[NoneType](), 1, UInt64(n), self.file[].f)
            return
        if self.is_mem:
            if self.mlen + n > self.mcap:
                var nc = max(self.mlen + n, self.mcap * 2, 64)
                var nb = gc_atomic_bytes(nc).unsafe_bitcast[UInt8]()
                if self.mlen > 0:
                    _ = external_call["memcpy", VP](nb.unsafe_bitcast[NoneType](), self.mem.unsafe_bitcast[NoneType](), self.mlen)
                self.mem = nb
                self.mcap = nc
            for i in range(n):
                self.mem[unsafe_offset=self.mlen + i] = b[unsafe_offset=i]
            self.mlen += n

    def pad(mut self, body: P[UInt8], n: Int) raises:
        var w = self.widthv
        self.widthv = 0
        if Int64(n) >= w:
            self.raw(body, n)
            return
        var k = Int(w) - n
        var p = gc_atomic_bytes(k).unsafe_bitcast[UInt8]()
        for i in range(k):
            p[unsafe_offset=i] = self.fillc.cast[DType.uint8]()
        if (self.flagsv & IOS_LEFT) != 0:
            self.raw(body, n)
            self.raw(p, k)
        else:
            self.raw(p, k)
            self.raw(body, n)

    def pad_list(mut self, o: List[UInt8]) raises:
        var b = gc_atomic_bytes(len(o) + 1).unsafe_bitcast[UInt8]()
        for i in range(len(o)):
            b[unsafe_offset=i] = o[i]
        self.pad(b, len(o))

    def Put(mut self, x: Ref[Str]) raises -> Ref[OStream]:
        self.pad(x[].b.p, Int(x[].n))
        return self.me()

    def Put(mut self, x: CPtr) raises -> Ref[OStream]:
        self.pad(x.u8(), cslen(x))
        return self.me()

    def Put(mut self, c: Int8) raises -> Ref[OStream]:
        var sp = rt_sp()
        var b = rt_salloc[UInt8]()
        b[] = c.cast[DType.uint8]()
        self.pad(b, 1)
        rt_set_sp(sp)
        return self.me()

    def Put(mut self, c: UInt8) raises -> Ref[OStream]:
        var sp = rt_sp()
        var b = rt_salloc[UInt8]()
        b[] = c
        self.pad(b, 1)
        rt_set_sp(sp)
        return self.me()

    def put_fmt(mut self, fmt: StaticString, a: Arg) raises -> Ref[OStream]:
        var o = List[UInt8]()
        fmt_into(o, rt_lit(fmt).p, a)
        self.pad_list(o)
        return self.me()

    def Put(mut self, v: Int32) raises -> Ref[OStream]:
        return self.put_fmt("%d", ai(v))

    def Put(mut self, v: Int64) raises -> Ref[OStream]:
        return self.put_fmt("%ld", al(v))

    def Put(mut self, v: UInt32) raises -> Ref[OStream]:
        return self.put_fmt("%u", au(v))

    def Put(mut self, v: UInt64) raises -> Ref[OStream]:
        return self.put_fmt("%lu", aul(v))

    def Put(mut self, v: Int16) raises -> Ref[OStream]:
        return self.put_fmt("%d", ai(Int32(v)))

    def Put(mut self, v: Bool) raises -> Ref[OStream]:
        if (self.flagsv & IOS_BOOLALPHA) != 0:
            return self.Put(rt_lit("true") if v else rt_lit("false"))
        return self.Put(rt_lit("1") if v else rt_lit("0"))

    def Put(mut self, v: Float32) raises -> Ref[OStream]:
        return self.Put(v.cast[DType.float64]())

    def Put(mut self, v: Float64) raises -> Ref[OStream]:
        var fx = (self.flagsv & IOS_FIXED) != 0
        var sci = (self.flagsv & IOS_SCIENTIFIC) != 0
        var sp = (self.flagsv & IOS_SHOWPOINT) != 0
        var o = List[UInt8]()
        var p = Int32(Int(self.prec))
        if fx and sci:
            fmt_into(o, (rt_lit("%#a") if sp else rt_lit("%a")).p, ad(v))
        elif fx:
            fmt_into(o, (rt_lit("%#.*f") if sp else rt_lit("%.*f")).p, ai(p), ad(v))
        elif sci:
            fmt_into(o, (rt_lit("%#.*e") if sp else rt_lit("%.*e")).p, ai(p), ad(v))
        else:
            fmt_into(o, (rt_lit("%#.*g") if sp else rt_lit("%.*g")).p, ai(p), ad(v))
        self.pad_list(o)
        return self.me()

    def Manip_endl(mut self) raises -> Ref[OStream]:
        var sp = rt_sp()
        var nl = rt_salloc[UInt8]()
        nl[] = 10
        self.raw(nl, 1)
        rt_set_sp(sp)
        _ = self.flush()
        return self.me()

    def Manip_flush(mut self) raises -> Ref[OStream]:
        _ = self.flush()
        return self.me()

    def Manip_setprecision(mut self, n: Int64) raises -> Ref[OStream]:
        self.prec = n
        return self.me()

    def Manip_setw(mut self, n: Int64) raises -> Ref[OStream]:
        self.widthv = n
        return self.me()

    def Manip_setfill(mut self, c: Int32) raises -> Ref[OStream]:
        self.fillc = c
        return self.me()

    def Manip_quoted(mut self, x: Ref[Str]) raises -> Ref[OStream]:
        var o = List[UInt8]()
        o.append(34)
        for i in range(Int(x[].n)):
            var c = x[].b.p[unsafe_offset=i]
            if c == 34 or c == 92:
                o.append(92)
            o.append(c)
        o.append(34)
        self.pad_list(o)
        return self.me()

    def Manip_quoted(mut self, x: CPtr) raises -> Ref[OStream]:
        return self.Manip_quoted(Str.new_(x))

    def Manip_fixed(mut self) raises -> Ref[OStream]:
        self.flagsv = (self.flagsv & ~(IOS_FIXED | IOS_SCIENTIFIC)) | IOS_FIXED
        return self.me()

    def Manip_scientific(mut self) raises -> Ref[OStream]:
        self.flagsv = (self.flagsv & ~(IOS_FIXED | IOS_SCIENTIFIC)) | IOS_SCIENTIFIC
        return self.me()

    def Manip_defaultfloat(mut self) raises -> Ref[OStream]:
        self.flagsv &= ~(IOS_FIXED | IOS_SCIENTIFIC)
        return self.me()

    def Manip_left(mut self) raises -> Ref[OStream]:
        self.flagsv = (self.flagsv & ~(IOS_LEFT | Int32(128))) | IOS_LEFT
        return self.me()

    def Manip_right(mut self) raises -> Ref[OStream]:
        self.flagsv = (self.flagsv & ~(IOS_LEFT | Int32(128))) | Int32(128)
        return self.me()

    def Manip_boolalpha(mut self) raises -> Ref[OStream]:
        self.flagsv |= IOS_BOOLALPHA
        return self.me()

    def write(mut self, p: CPtr, n: Int64) raises -> Ref[OStream]:
        if n != 0:
            self.raw(p.u8(), Int(n))
        return self.me()

    def write[T: Elem](mut self, p: Ptr[T], n: Int64) raises -> Ref[OStream]:
        if n == 0:
            return self.me()
        return self.write(CPtr(p.p.unsafe_bitcast[Int8]()), n)

    def flush(mut self) raises -> Ref[OStream]:
        if not self.file.isnull():
            _ = fflush(self.file[].f)
        return self.me()

    def tellp(self) raises -> Int64:
        if not self.file.isnull():
            return self.file[].f[].pos
        return Int64(self.mlen)

    def precision(self) raises -> Int64:
        return self.prec

    def str_(mut self) raises -> Ref[Str]:
        return Str.of_bytes(self.mem, self.mlen)

    def str_(mut self, x: Ref[Str]) raises:
        self.mlen = 0
        self.raw(x[].b.p, Int(x[].n))

    def open(mut self, path: Ref[Str], mode: Int32) raises:
        var f = R.fopen(path[].cstr(), rt_lit("ab") if (mode & IOS_APP) != 0 else rt_lit("wb"))
        self.file = f
        self.failbit = f.isnull()

    def open(mut self, path: Ref[FsPath], mode: Int32) raises:
        self.open(path[].p, mode)

    def is_open(self) raises -> Bool:
        return not self.file.isnull()

    def close(mut self) raises:
        if not self.file.isnull():
            _ = R.fclose(self.file)
        self.file = Ref[CFile]()

    def MoveFrom(mut self, o: Ref[OStream]) raises:
        self.failbit = o[].failbit
        self.eofbit = o[].eofbit
        self.badbit = o[].badbit
        self.prec = o[].prec
        self.flagsv = o[].flagsv
        self.widthv = o[].widthv
        self.fillc = o[].fillc
        self.file = o[].file
        self.mem = o[].mem
        self.mlen = o[].mlen
        self.mcap = o[].mcap
        self.is_mem = o[].is_mem
        o[].file = Ref[CFile]()
        o[].mem = rt_null[UInt8]()
        o[].mlen = 0
        o[].mcap = 0


struct Streams:
    @staticmethod
    def getline(s: Ref[IStream], line: Ref[Str]) raises -> Ref[IStream]:
        _ = s[].read_line(line, 10)
        return s

    @staticmethod
    def getline(s: Ref[IStream], line: Ref[Str], delim: Int8) raises -> Ref[IStream]:
        _ = s[].read_line(line, delim.cast[DType.uint8]())
        return s

    @staticmethod
    def getline(s: Ref[IStream], line: Ref[Str], delim: Int32) raises -> Ref[IStream]:
        _ = s[].read_line(line, delim.cast[DType.uint8]())
        return s
