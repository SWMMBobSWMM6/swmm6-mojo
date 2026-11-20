# str.mojo - std::string (the C# runtime's Str): bytes and a length, with libstdc++'s exceptions and the
# conversions the engine uses. After zig/rt/str.zig and cs/runtime/Str.cs.
# Written by Claude (Anthropic) for the SWMM6 ports; see ../README.md and ../../AI-USE.md.

from std.ffi import external_call
from rt.core import *
from rt.crt import *

comptime NPOS = UInt64(0xFFFFFFFFFFFFFFFF)


def cslen(p: CPtr) -> Int:
    var n = 0
    while p.p[unsafe_offset=n] != 0:
        n += 1
    return n


def bytes_eq(a: P[UInt8], b: P[UInt8], n: Int) -> Bool:
    for i in range(n):
        if a[unsafe_offset=i] != b[unsafe_offset=i]:
            return False
    return True


def bytes_cmp(a: P[UInt8], na: Int, b: P[UInt8], nb: Int) -> Int32:
    var m = min(na, nb)
    for i in range(m):
        var x = a[unsafe_offset=i]
        var y = b[unsafe_offset=i]
        if x != y:
            return Int32(-1) if x < y else Int32(1)
    var d = na - nb
    if d > 2147483647:
        return Int32(2147483647)
    if d < -2147483648:
        return Int32(-2147483648)
    return Int32(d)


def throw_out_of_range(what: StaticString, n: UInt64, size: UInt64) raises:
    """libstdc++'s message: `what: __n (which is N) >= this->size() (which is S)`"""
    var buf = gc_atomic_bytes(200).unsafe_bitcast[Int8]()
    _ = snprintf(buf, 200, rt_lit("%s (which is %lu) >= this->size() (which is %lu)").p, astr(rt_lit(what).p), aul(n), aul(size))
    raise rt_throw(rt_exc_new(5, CPtr(buf)))


struct Str(EStruct):
    """std::string: b holds at least n + 1 bytes; b[n] is 0 whenever c_str() has been taken"""
    var b: Ary[UInt8]
    var n: Int32
    comptime IS_CLASS = True
    comptime LIB = True

    # ---------------------------------------------------------------- making
    @staticmethod
    def raw(cap: Int) -> Ref[Str]:
        var o = Ref[Str](gc_new[Str]())
        o[].b = Ary[UInt8](gc_atomic_bytes(max(cap, 1)).unsafe_bitcast[UInt8](), max(cap, 1))
        return o

    @staticmethod
    def of_bytes(p: P[UInt8], n: Int) -> Ref[Str]:
        var o = Str.raw(n + 1)
        if n > 0:
            _ = external_call["memcpy", VP](o[].b.p.unsafe_bitcast[NoneType](), p.unsafe_bitcast[NoneType](), n)
        o[].n = Int32(n)
        return o

    @staticmethod
    def of_lit(s: StaticString) -> Ref[Str]:
        return Str.of_bytes(P[UInt8](unsafe_from_address=Int(s.unsafe_ptr())), s.byte_length())

    @staticmethod
    def new_() raises -> Ref[Str]:
        return Str.raw(16)

    @staticmethod
    def new_(s: Ref[Str]) raises -> Ref[Str]:
        return Str.of_bytes(s[].b.p, Int(s[].n))

    @staticmethod
    def new_(p: CPtr) raises -> Ref[Str]:
        return Str.of_bytes(p.u8(), cslen(p))

    @staticmethod
    def new_(p: CPtr, len: UInt64) raises -> Ref[Str]:
        if len == 0:
            return Str.raw(1)
        return Str.of_bytes(p.u8(), Int(len))

    @staticmethod
    def new_(count: UInt64, ch: Int32) raises -> Ref[Str]:
        var m = Int(count)
        var o = Str.raw(m + 1)
        for i in range(m):
            o[].b.p[unsafe_offset=i] = ch.cast[DType.uint8]()
        o[].n = Int32(m)
        return o

    @staticmethod
    def fromCPtr(p: CPtr) raises -> Ref[Str]:
        return Str.new_(p)

    @staticmethod
    def fromCStr(s: CStr) raises -> Ref[Str]:
        return Str.of_bytes(s.p, s.n)

    @staticmethod
    def __new() raises -> Ref[Str]:
        return Str.new_()

    @staticmethod
    def __clone(x: Ref[Str]) raises -> Ref[Str]:
        return Str.of_bytes(x[].b.p, Int(x[].n))

    @staticmethod
    def __assign(d: Ref[Str], x: Ref[Str]) raises:
        d[].Assign(x)

    @staticmethod
    def __moveFrom(d: Ref[Str], x: Ref[Str]) raises:
        d[].MoveFrom(x)

    @staticmethod
    def __less(a: Ref[Str], b: Ref[Str]) raises -> Bool:
        return bytes_cmp(a[].b.p, Int(a[].n), b[].b.p, Int(b[].n)) < 0

    @staticmethod
    def __eqv(a: Ref[Str], b: Ref[Str]) raises -> Bool:
        return a[].n == b[].n and bytes_eq(a[].b.p, b[].b.p, Int(a[].n))

    @staticmethod
    def __hashv(a: Ref[Str]) raises -> UInt64:
        return hash_bytes(a[].b.p, Int(a[].n), 0xc70f6907)

    # ---------------------------------------------------------------- storage
    def me(mut self) -> Ref[Str]:
        return Ref[Str](rt_addr(self))

    def reserve_cap(mut self, need: Int):
        if need + 1 <= self.b.n:
            return
        var cap = max(need + 1, self.b.n * 2)
        var nb = gc_atomic_bytes(cap).unsafe_bitcast[UInt8]()
        if self.n > 0:
            _ = external_call["memcpy", VP](nb.unsafe_bitcast[NoneType](), self.b.p.unsafe_bitcast[NoneType](), Int(self.n))
        self.b = Ary[UInt8](nb, cap)

    def size(self) raises -> UInt64:
        return UInt64(Int(self.n))

    def length(self) raises -> UInt64:
        return UInt64(Int(self.n))

    def empty(self) raises -> Bool:
        return self.n == 0

    def clear(mut self) raises:
        self.n = 0

    def cstr(mut self) -> CPtr:
        self.reserve_cap(Int(self.n))
        self.b.p[unsafe_offset=Int(self.n)] = 0
        return CPtr(self.b.p.unsafe_bitcast[Int8]())

    def c_str(mut self) raises -> CPtr:
        return self.cstr()

    def data(mut self) raises -> CPtr:
        return self.cstr()

    def front(mut self) raises -> P[UInt8]:
        return self.b.p

    def back(mut self) raises -> P[UInt8]:
        return padd(self.b.p, Int(self.n) - 1)

    def at(self, i: UInt64) raises -> UInt8:
        if i >= UInt64(Int(self.n)):
            throw_out_of_range("basic_string::at: __n", i, UInt64(Int(self.n)))
        return self.b.p[unsafe_offset=Int(i)]

    def begin(self) raises -> Iter[UInt8]:
        return Iter[UInt8](self.b, 0)

    def end(self) raises -> Iter[UInt8]:
        return Iter[UInt8](self.b, Int64(self.n))

    # ---------------------------------------------------------------- assignment
    def Clone(mut self) raises -> Ref[Str]:
        return Str.of_bytes(self.b.p, Int(self.n))

    def Assign(mut self, o: Ref[Str]) raises:
        if Int(o.p) == Int(rt_addr(self)):
            return
        var m = Int(o[].n)
        self.reserve_cap(m)
        if m > 0:
            _ = external_call["memmove", VP](self.b.p.unsafe_bitcast[NoneType](), o[].b.p.unsafe_bitcast[NoneType](), m)
        self.n = Int32(m)

    def Assign(mut self, p: CPtr) raises:
        var m = cslen(p)
        var t = gc_atomic_bytes(m + 1).unsafe_bitcast[UInt8]()
        _ = external_call["memcpy", VP](t.unsafe_bitcast[NoneType](), p.p.unsafe_bitcast[NoneType](), m)
        self.b = Ary[UInt8](t, m + 1)
        self.n = Int32(m)

    def Assign(mut self, ch: Int32) raises:
        self.reserve_cap(1)
        self.b.p[] = ch.cast[DType.uint8]()
        self.n = 1

    def MoveFrom(mut self, o: Ref[Str]) raises:
        if Int(o.p) == Int(rt_addr(self)):
            return
        self.b = o[].b
        self.n = o[].n
        o[].b = Ary[UInt8](gc_atomic_bytes(16).unsafe_bitcast[UInt8](), 16)
        o[].n = 0

    def assign(mut self, o: Ref[Str]) raises -> Ref[Str]:
        self.Assign(o)
        return self.me()

    def assign(mut self, p: CPtr) raises -> Ref[Str]:
        self.Assign(p)
        return self.me()

    def assign(mut self, p: CPtr, len: UInt64) raises -> Ref[Str]:
        var m = Int(len)
        var t = gc_atomic_bytes(m + 1).unsafe_bitcast[UInt8]()
        if m != 0:
            _ = external_call["memcpy", VP](t.unsafe_bitcast[NoneType](), p.p.unsafe_bitcast[NoneType](), m)
        self.b = Ary[UInt8](t, m + 1)
        self.n = Int32(m)
        return self.me()

    def assign(mut self, b0: Ptr[Int8], e0: Ptr[Int8]) raises -> Ref[Str]:
        return self.assign(CPtr(b0.p), UInt64(Int(e0.diff(b0))))

    def assign(mut self, count: UInt64, ch: Int32) raises -> Ref[Str]:
        var m = Int(count)
        self.reserve_cap(m)
        for i in range(m):
            self.b.p[unsafe_offset=i] = ch.cast[DType.uint8]()
        self.n = Int32(m)
        return self.me()

    # ---------------------------------------------------------------- appending
    def append_bytes(mut self, src: P[UInt8], k: Int):
        var n = Int(self.n)
        self.reserve_cap(n + k)
        if k > 0:
            _ = external_call["memmove", VP](padd(self.b.p, n).unsafe_bitcast[NoneType](), src.unsafe_bitcast[NoneType](), k)
        self.n = Int32(n + k)

    def append(mut self, o: Ref[Str]) raises -> Ref[Str]:
        self.append_bytes(o[].b.p, Int(o[].n))
        return self.me()

    def append(mut self, o: Ref[Str], pos: UInt64, len: UInt64) raises -> Ref[Str]:
        var m = min(len, UInt64(Int(o[].n)) - pos)
        self.append_bytes(padd(o[].b.p, Int(pos)), Int(m))
        return self.me()

    def append(mut self, p: CPtr) raises -> Ref[Str]:
        self.append_bytes(p.u8(), cslen(p))
        return self.me()

    def append(mut self, p: CPtr, len: UInt64) raises -> Ref[Str]:
        if len != 0:
            self.append_bytes(p.u8(), Int(len))
        return self.me()

    def append(mut self, count: UInt64, ch: Int32) raises -> Ref[Str]:
        for _ in range(Int(count)):
            self.push_back(ch)
        return self.me()

    def append(mut self, ch: Int32) raises -> Ref[Str]:
        self.push_back(ch)
        return self.me()

    def push_back(mut self, ch: Int32) raises:
        var n = Int(self.n)
        self.reserve_cap(n + 1)
        self.b.p[unsafe_offset=n] = ch.cast[DType.uint8]()
        self.n += 1

    def pop_back(mut self) raises:
        self.n -= 1

    def resize(mut self, m: UInt64, ch: Int32) raises:
        var k = Int(m)
        self.reserve_cap(k)
        for i in range(Int(self.n), k):
            self.b.p[unsafe_offset=i] = ch.cast[DType.uint8]()
        self.n = Int32(k)

    def resize(mut self, m: UInt64) raises:
        self.resize(m, 0)

    def reserve(mut self, m: UInt64) raises:
        self.reserve_cap(Int(m))

    def shrink_to_fit(mut self) raises:
        pass

    def remove_prefix(mut self, k: UInt64) raises:
        var m = Int(k)
        var n = Int(self.n)
        for i in range(n - m):
            self.b.p[unsafe_offset=i] = self.b.p[unsafe_offset=i + m]
        self.n = Int32(n - m)
        self.b.p[unsafe_offset=n - m] = 0

    def remove_suffix(mut self, k: UInt64) raises:
        self.n -= Int32(Int(k))
        self.b.p[unsafe_offset=Int(self.n)] = 0

    def substr(mut self, pos: UInt64, len: UInt64) raises -> Ref[Str]:
        var n = UInt64(Int(self.n))
        if pos > n:
            var buf = gc_atomic_bytes(200).unsafe_bitcast[Int8]()
            _ = snprintf(buf, 200, rt_lit("basic_string::substr: __pos (which is %lu) > this->size() (which is %lu)").p, aul(pos), aul(n))
            raise rt_throw(rt_exc_new(5, CPtr(buf)))
        var m = min(len, n - pos)
        return Str.of_bytes(padd(self.b.p, Int(pos)), Int(m))

    def erase(mut self, pos: UInt64, len: UInt64) raises -> Ref[Str]:
        var n = Int(self.n)
        var p = Int(pos)
        var m = Int(min(len, UInt64(n - p)))
        for i in range(p, n - m):
            self.b.p[unsafe_offset=i] = self.b.p[unsafe_offset=i + m]
        self.n = Int32(n - m)
        return self.me()

    def insert(mut self, pos: UInt64, s: Ref[Str]) raises -> Ref[Str]:
        var src = Str.__clone(s)
        var n = Int(self.n)
        var p = Int(pos)
        var k = Int(src[].n)
        self.reserve_cap(n + k)
        var i = n - 1
        while i >= p:
            self.b.p[unsafe_offset=i + k] = self.b.p[unsafe_offset=i]
            i -= 1
        for j in range(k):
            self.b.p[unsafe_offset=p + j] = src[].b.p[unsafe_offset=j]
        self.n = Int32(n + k)
        return self.me()

    # ---------------------------------------------------------------- searching
    def find_bytes(self, s: P[UInt8], k: Int, pos: UInt64) -> UInt64:
        var n = UInt64(Int(self.n))
        if k == 0:
            return pos if pos <= n else NPOS
        var i = pos
        while i + UInt64(k) <= n:
            if bytes_eq(padd(self.b.p, Int(i)), s, k):
                return i
            i += 1
        return NPOS

    def rfind_bytes(self, s: P[UInt8], k: Int, pos: UInt64) -> UInt64:
        var n = UInt64(Int(self.n))
        if UInt64(k) > n:
            return NPOS
        var i = Int(min(pos, n - UInt64(k)))
        while i >= 0:
            if bytes_eq(padd(self.b.p, i), s, k):
                return UInt64(i)
            i -= 1
        return NPOS

    def find(self, s: Ref[Str], pos: UInt64) raises -> UInt64:
        return self.find_bytes(s[].b.p, Int(s[].n), pos)

    def find(self, s: CPtr, pos: UInt64) raises -> UInt64:
        return self.find_bytes(s.u8(), cslen(s), pos)

    def find(self, ch: Int32, pos: UInt64) raises -> UInt64:
        var c = ch.cast[DType.uint8]()
        var i = Int(pos)
        while i < Int(self.n):
            if self.b.p[unsafe_offset=i] == c:
                return UInt64(i)
            i += 1
        return NPOS

    def rfind(self, s: Ref[Str], pos: UInt64) raises -> UInt64:
        return self.rfind_bytes(s[].b.p, Int(s[].n), pos)

    def rfind(self, s: CPtr, pos: UInt64) raises -> UInt64:
        return self.rfind_bytes(s.u8(), cslen(s), pos)

    def rfind(self, ch: Int32, pos: UInt64) raises -> UInt64:
        if self.n == 0:
            return NPOS
        var c = ch.cast[DType.uint8]()
        var i = Int(min(pos, UInt64(Int(self.n) - 1)))
        while i >= 0:
            if self.b.p[unsafe_offset=i] == c:
                return UInt64(i)
            i -= 1
        return NPOS

    def first_of(self, set: P[UInt8], k: Int, pos: UInt64, want: Bool) -> UInt64:
        var i = Int(pos)
        while i < Int(self.n):
            if _in(self.b.p[unsafe_offset=i], set, k) == want:
                return UInt64(i)
            i += 1
        return NPOS

    def last_of(self, set: P[UInt8], k: Int, pos: UInt64, want: Bool) -> UInt64:
        if self.n == 0:
            return NPOS
        var i = Int(min(pos, UInt64(Int(self.n) - 1)))
        while i >= 0:
            if _in(self.b.p[unsafe_offset=i], set, k) == want:
                return UInt64(i)
            i -= 1
        return NPOS

    def find_first_of(self, s: Ref[Str], pos: UInt64) raises -> UInt64:
        return self.first_of(s[].b.p, Int(s[].n), pos, True)

    def find_first_of(self, s: CPtr, pos: UInt64) raises -> UInt64:
        return self.first_of(s.u8(), cslen(s), pos, True)

    def find_first_of(self, ch: Int32, pos: UInt64) raises -> UInt64:
        return self.find(ch, pos)

    def find_first_not_of(self, s: Ref[Str], pos: UInt64) raises -> UInt64:
        return self.first_of(s[].b.p, Int(s[].n), pos, False)

    def find_first_not_of(self, s: CPtr, pos: UInt64) raises -> UInt64:
        return self.first_of(s.u8(), cslen(s), pos, False)

    def find_first_not_of(self, ch: Int32, pos: UInt64) raises -> UInt64:
        var sp = rt_sp()
        var c = rt_salloc[UInt8]()
        c[] = ch.cast[DType.uint8]()
        var r = self.first_of(c, 1, pos, False)
        rt_set_sp(sp)
        return r

    def find_last_of(self, s: Ref[Str], pos: UInt64) raises -> UInt64:
        return self.last_of(s[].b.p, Int(s[].n), pos, True)

    def find_last_of(self, s: CPtr, pos: UInt64) raises -> UInt64:
        return self.last_of(s.u8(), cslen(s), pos, True)

    def find_last_of(self, ch: Int32, pos: UInt64) raises -> UInt64:
        return self.rfind(ch, pos)

    def find_last_not_of(self, s: Ref[Str], pos: UInt64) raises -> UInt64:
        return self.last_of(s[].b.p, Int(s[].n), pos, False)

    def find_last_not_of(self, s: CPtr, pos: UInt64) raises -> UInt64:
        return self.last_of(s.u8(), cslen(s), pos, False)

    def find_last_not_of(self, ch: Int32, pos: UInt64) raises -> UInt64:
        var sp = rt_sp()
        var c = rt_salloc[UInt8]()
        c[] = ch.cast[DType.uint8]()
        var r = self.last_of(c, 1, pos, False)
        rt_set_sp(sp)
        return r

    def starts_with(self, s: Ref[Str]) raises -> Bool:
        return s[].n <= self.n and bytes_eq(self.b.p, s[].b.p, Int(s[].n))

    def starts_with(self, s: CPtr) raises -> Bool:
        var k = cslen(s)
        return k <= Int(self.n) and bytes_eq(self.b.p, s.u8(), k)

    def starts_with(self, ch: Int32) raises -> Bool:
        return self.n > 0 and self.b.p[] == ch.cast[DType.uint8]()

    def ends_with(self, s: Ref[Str]) raises -> Bool:
        var k = Int(s[].n)
        return k <= Int(self.n) and bytes_eq(padd(self.b.p, Int(self.n) - k), s[].b.p, k)

    def ends_with(self, s: CPtr) raises -> Bool:
        var k = cslen(s)
        return k <= Int(self.n) and bytes_eq(padd(self.b.p, Int(self.n) - k), s.u8(), k)

    # ---------------------------------------------------------------- comparing
    def compare(self, o: Ref[Str]) raises -> Int32:
        return bytes_cmp(self.b.p, Int(self.n), o[].b.p, Int(o[].n))

    def compare(self, o: CPtr) raises -> Int32:
        return bytes_cmp(self.b.p, Int(self.n), o.u8(), cslen(o))

    def compare(mut self, pos: UInt64, len: UInt64, o: Ref[Str]) raises -> Int32:
        var s = self.substr(pos, len)
        return bytes_cmp(s[].b.p, Int(s[].n), o[].b.p, Int(o[].n))

    def Equals(self, o: Ref[Str]) raises -> Bool:
        if o.isnull():
            return False
        return self.n == o[].n and bytes_eq(self.b.p, o[].b.p, Int(self.n))

    def EqLit(self, p: CPtr) raises -> Bool:
        var k = cslen(p)
        return k == Int(self.n) and bytes_eq(self.b.p, p.u8(), k)

    def ToString(self) raises -> CStr:
        var t = gc_atomic_bytes(Int(self.n) + 1).unsafe_bitcast[UInt8]()
        if self.n > 0:
            _ = external_call["memcpy", VP](t.unsafe_bitcast[NoneType](), self.b.p.unsafe_bitcast[NoneType](), Int(self.n))
        return CStr(t, Int(self.n))

    # ---------------------------------------------------------------- operators and conversions
    @staticmethod
    def Cat(x: Ref[Str], y: Ref[Str]) raises -> Ref[Str]:
        var r = Str.of_bytes(x[].b.p, Int(x[].n))
        r[].append_bytes(y[].b.p, Int(y[].n))
        return r

    @staticmethod
    def Cat(x: Ref[Str], y: CPtr) raises -> Ref[Str]:
        var r = Str.of_bytes(x[].b.p, Int(x[].n))
        r[].append_bytes(y.u8(), cslen(y))
        return r

    @staticmethod
    def Cat(x: CPtr, y: Ref[Str]) raises -> Ref[Str]:
        var r = Str.new_(x)
        r[].append_bytes(y[].b.p, Int(y[].n))
        return r

    @staticmethod
    def Cat(x: Ref[Str], ch: Int32) raises -> Ref[Str]:
        var r = Str.of_bytes(x[].b.p, Int(x[].n))
        r[].push_back(ch)
        return r

    @staticmethod
    def to_string(v: Int32) raises -> Ref[Str]:
        return _fmt1(rt_lit("%d"), ai(v))

    @staticmethod
    def to_string(v: Int64) raises -> Ref[Str]:
        return _fmt1(rt_lit("%ld"), al(v))

    @staticmethod
    def to_string(v: UInt32) raises -> Ref[Str]:
        return _fmt1(rt_lit("%u"), au(v))

    @staticmethod
    def to_string(v: UInt64) raises -> Ref[Str]:
        return _fmt1(rt_lit("%lu"), aul(v))

    @staticmethod
    def to_string(v: Float64) raises -> Ref[Str]:
        return _fmt1(rt_lit("%f"), ad(v))

    @staticmethod
    def stod(s: Ref[Str], idx: Ptr[UInt64]) raises -> Float64:
        """std::stod: invalid_argument when nothing is read, out_of_range when strtod sets ERANGE (lessons/22)"""
        var p = s[].cstr()
        var endp = gc_new[P[Int8]]()
        endp[] = p.p
        var v = strtod_erange(p.p, endp)
        var e = endp[]
        if Int(e) == Int(p.p):
            raise rt_throw(rt_exc_kind(4, "stod"))
        if crt_state()[].erange != 0:
            raise rt_throw(rt_exc_kind(5, "stod"))
        if not idx.isnull():
            idx.p[] = UInt64(Int(e) - Int(p.p))
        return v


def _in(c: UInt8, set: P[UInt8], k: Int) -> Bool:
    for i in range(k):
        if set[unsafe_offset=i] == c:
            return True
    return False


def _fmt1(fmt: CPtr, a: Arg) raises -> Ref[Str]:
    var buf = gc_atomic_bytes(512).unsafe_bitcast[Int8]()
    var n = snprintf(buf, 512, fmt.p, a)
    return Str.of_bytes(buf.unsafe_bitcast[UInt8](), Int(n))


def rt_exc_make(kind: Int, msg: Ref[Str]) raises -> Ref[CppException]:
    if msg.isnull():
        return rt_exc_new(kind, CPtr())
    return rt_exc_new(kind, msg[].cstr())


def rt_exc_make(kind: Int, msg: CPtr) raises -> Ref[CppException]:
    return rt_exc_new(kind, msg)


def rt_exc_make(kind: Int, msg: CStr) raises -> Ref[CppException]:
    return rt_exc_new(kind, rt_lit(msg))
