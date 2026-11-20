# cont.mojo - the C++ containers and algorithms the engine uses, after cs/runtime (Std.cs, Containers.cs,
# StdAlgo.cs, Misc.cs) and zig/rt/cont.zig: std::vector (Vec), std::pair, std::optional, std::unordered_map and
# unordered_set with libstdc++'s exact node order (one singly linked list, a bucket array pointing at the node before
# each bucket's first node, new nodes at the front of their bucket, the prime rehash policy), std::map and std::set
# (sorted), std::stack and std::queue, <algorithm> with libstdc++'s introsort, and the C# runtime's helpers for
# arrays, raw memory and moves. The engine iterates hashed containers, so their order reaches its output.
# A function taking a C# delegate takes the engine's dispatcher for its signature as a compile-time parameter.
# Written by Claude (Anthropic) for the SWMM6 ports; see ../README.md and ../../AI-USE.md.

from std.ffi import external_call
from std.sys import size_of
from rt.core import *
from rt.crt import *
from rt.str import *
from rt.primes import PRIMES, N_PRIMES


# ================================================================ printf and tuple arguments
@always_inline
def A(v: Int32) -> Arg:
    return ai(v)


@always_inline
def A(v: Int64) -> Arg:
    return al(v)


@always_inline
def A(v: UInt32) -> Arg:
    return au(v)


@always_inline
def A(v: UInt64) -> Arg:
    return aul(v)


@always_inline
def A(v: Int8) -> Arg:
    return ai(Int32(v))


@always_inline
def A(v: UInt8) -> Arg:
    return ai(Int32(v))


@always_inline
def A(v: Int16) -> Arg:
    return ai(Int32(v))


@always_inline
def A(v: UInt16) -> Arg:
    return ai(Int32(v))


@always_inline
def A(v: Bool) -> Arg:
    return ai(Int32(1) if v else Int32(0))


@always_inline
def A(v: Float64) -> Arg:
    return ad(v)


@always_inline
def A(v: Float32) -> Arg:
    return ad(v.cast[DType.float64]())


@always_inline
def A(v: CPtr) -> Arg:
    return astr(v.p)


@always_inline
def A(v: Ref[Str]) -> Arg:
    """a string as a tuple element (kind 7)"""
    return Arg(7, 0, 0.0, Int(v.p))


@always_inline
def A(p: P[Int32]) -> Arg:
    return tpi(p)


@always_inline
def A(p: P[Int64]) -> Arg:
    return tpl(p)


@always_inline
def A(p: P[UInt32]) -> Arg:
    return tpu(p)


@always_inline
def A(p: P[Float64]) -> Arg:
    return tpd(p)


@always_inline
def A(p: P[Float32]) -> Arg:
    return tpf(p)


@always_inline
def A(p: P[Int8]) -> Arg:
    return tps(p)


@always_inline
def A(p: P[CPtr]) -> Arg:
    return tps(p[].p)


@always_inline
def A[T: EStruct](r: Ref[T]) -> Arg:
    """an object as a tuple element: its address"""
    return Arg(6, 0, 0.0, Int(r.p))


@always_inline
def A[T: Elem](a: Ary[T]) -> Arg:
    return Arg(6, 0, 0.0, Int(a.p))


@always_inline
def A[T: Elem](p: Ptr[T]) -> Arg:
    return Arg(6, 0, 0.0, Int(p.p))


@always_inline
def A_slot() -> Arg:
    return Arg(0, 0, 0.0, 0)


@always_inline
def A_null() -> Arg:
    return astr(rt_null[Int8]())


# ================================================================ a growable list (under map, set, stack, queue)
struct SList[E: Elem](Movable):
    var a: P[Self.E]
    var n: Int
    var cap: Int

    @staticmethod
    def make() -> P[SList[Self.E]]:
        var l = gc_new[SList[Self.E]]()
        l[].a = gc_array[Self.E](4)
        l[].cap = 4
        return l

    def insert_at(mut self, i: Int, x: Self.E):
        if self.n + 1 > self.cap:
            var nc = gc_array[Self.E](self.cap * 2)
            for k in range(self.n):
                nc[unsafe_offset=k] = self.a[unsafe_offset=k]
            self.a = nc
            self.cap *= 2
        var k = self.n
        while k > i:
            self.a[unsafe_offset=k] = self.a[unsafe_offset=k - 1]
            k -= 1
        self.a[unsafe_offset=i] = x
        self.n += 1

    def remove_at(mut self, i: Int):
        for k in range(i, self.n - 1):
            self.a[unsafe_offset=k] = self.a[unsafe_offset=k + 1]
        self.n -= 1
        self.a[unsafe_offset=self.n] = rt_zero[Self.E]()

    @always_inline
    def at(self, i: Int) -> ref[MutUntrackedOrigin] Self.E:
        return self.a[unsafe_offset=i]


# ================================================================ std::vector
struct Vec[T: Elem](EStruct):
    var a: Ary[Self.T]
    var n: Int32
    var mk: Int
    var mk2: Int
    comptime IS_CLASS = True
    comptime LIB = True

    @staticmethod
    def raw() -> Ref[Vec[Self.T]]:
        var v = Ref[Vec[Self.T]](gc_new[Vec[Self.T]]())
        v[].a = Ary[Self.T](gc_array[Self.T](0), 0)
        return v

    def make_elem(self) raises -> Self.T:
        if self.mk > 0:
            return elem_make_n[Self.T](self.mk, self.mk2)
        return elem_make[Self.T]()

    def fill(mut self, frm: Int, to: Int) raises:
        if self.mk > 0 or elem_makes[Self.T]():
            for i in range(frm, to):
                self.a.p[unsafe_offset=i] = self.make_elem()

    @staticmethod
    def new_() raises -> Ref[Vec[Self.T]]:
        return Self.raw()

    @staticmethod
    def new_(mk: Int, mk2: Int = 0) raises -> Ref[Vec[Self.T]]:
        var v = Self.raw()
        v[].mk = mk
        v[].mk2 = mk2
        return v

    @staticmethod
    def new_(count: UInt64, mk: Int, mk2: Int = 0) raises -> Ref[Vec[Self.T]]:
        var v = Self.raw()
        v[].mk = mk
        v[].mk2 = mk2
        v[].a = Ary[Self.T].make(Int(count))
        v[].n = Int32(Int(count))
        v[].fill(0, Int(count))
        return v

    @staticmethod
    def new_(count: UInt64) raises -> Ref[Vec[Self.T]]:
        var v = Self.raw()
        v[].a = Ary[Self.T].make(Int(count))
        v[].n = Int32(Int(count))
        v[].fill(0, Int(count))
        return v

    @staticmethod
    def new_(count: UInt64, x: Self.T) raises -> Ref[Vec[Self.T]]:
        var v = Self.raw()
        v[].a = Ary[Self.T].make(Int(count))
        v[].n = Int32(Int(count))
        for i in range(Int(count)):
            v[].a.p[unsafe_offset=i] = elem_copy(x)
        return v

    @staticmethod
    def new_(init: Ary[Self.T]) raises -> Ref[Vec[Self.T]]:
        var v = Self.raw()
        v[].a = Ary[Self.T].make(init.n)
        v[].n = Int32(init.n)
        for i in range(init.n):
            v[].a.p[unsafe_offset=i] = elem_copy(init.p[unsafe_offset=i])
        return v

    @staticmethod
    def __new() raises -> Ref[Vec[Self.T]]:
        return Self.raw()

    @staticmethod
    def __clone(x: Ref[Vec[Self.T]]) raises -> Ref[Vec[Self.T]]:
        return x[].Clone()

    @staticmethod
    def __assign(d: Ref[Vec[Self.T]], x: Ref[Vec[Self.T]]) raises:
        d[].Assign(x)

    @staticmethod
    def __moveFrom(d: Ref[Vec[Self.T]], x: Ref[Vec[Self.T]]) raises:
        d[].MoveFrom(x)

    @staticmethod
    def __dispose(x: Ref[Vec[Self.T]]) raises:
        for i in range(Int(x[].n)):
            rt_dispose(x[].a.p[unsafe_offset=i])

    def me(mut self) -> Ref[Vec[Self.T]]:
        return Ref[Vec[Self.T]](rt_addr(self))

    def size(self) raises -> UInt64:
        return UInt64(Int(self.n))

    def empty(self) raises -> Bool:
        return self.n == 0

    def capacity(self) raises -> UInt64:
        return UInt64(self.a.n)

    def at(mut self, i: UInt64) raises -> P[Self.T]:
        if i >= UInt64(Int(self.n)):
            var buf = gc_atomic_bytes(200).unsafe_bitcast[Int8]()
            _ = snprintf(buf, 200, rt_lit("vector::_M_range_check: __n (which is %lu) >= this->size() (which is %lu)").p, aul(i), aul(UInt64(Int(self.n))))
            raise rt_throw(rt_exc_new(5, CPtr(buf)))
        return self.a.ptr(Int(i))

    def front(mut self) raises -> P[Self.T]:
        return self.a.p

    def back(mut self) raises -> P[Self.T]:
        return self.a.ptr(Int(self.n) - 1)

    def data(mut self) raises -> Ptr[Self.T]:
        """libstdc++'s data() is nullptr until the vector first allocates (lessons/27)"""
        if self.a.n == 0:
            return Ptr[Self.T]()
        return Ptr[Self.T](self.a.p)

    def resize_cap(mut self, cap: Int):
        var nb = gc_array[Self.T](cap)
        var k = min(cap, self.a.n)
        for i in range(k):
            nb[unsafe_offset=i] = self.a.p[unsafe_offset=i]
        self.a = Ary[Self.T](nb, cap)

    def grow(mut self, need: Int):
        if need <= self.a.n:
            return
        var n = Int(self.n)
        # libstdc++: the new capacity is size + max(size, 1) when push_back runs out
        self.resize_cap(max(need, n + max(n, 1)))

    def reserve(mut self, c: UInt64) raises:
        if Int(c) > self.a.n:
            self.resize_cap(Int(c))

    def push_back(mut self, x: Self.T) raises:
        var n = Int(self.n)
        self.grow(n + 1)
        self.a.p[unsafe_offset=n] = x
        self.n += 1

    def emplace_back(mut self, x: Self.T) raises -> P[Self.T]:
        self.push_back(x)
        return self.a.ptr(Int(self.n) - 1)

    def pop_back(mut self) raises:
        self.n -= 1
        self.a.p[unsafe_offset=Int(self.n)] = rt_zero[Self.T]()

    def clear(mut self) raises:
        for i in range(Int(self.n)):
            self.a.p[unsafe_offset=i] = rt_zero[Self.T]()
        self.n = 0

    def resize(mut self, c: UInt64) raises:
        var m = Int(c)
        var n = Int(self.n)
        if m > n:
            self.grow(m)
            self.fill(n, m)
        else:
            for i in range(m, n):
                self.a.p[unsafe_offset=i] = rt_zero[Self.T]()
        self.n = Int32(m)

    def resize(mut self, c: UInt64, x: Self.T) raises:
        var m = Int(c)
        var n = Int(self.n)
        if m > n:
            self.grow(m)
            for i in range(n, m):
                self.a.p[unsafe_offset=i] = elem_copy(x)
        else:
            for i in range(m, n):
                self.a.p[unsafe_offset=i] = rt_zero[Self.T]()
        self.n = Int32(m)

    def assign(mut self, c: UInt64, x: Self.T) raises:
        var m = Int(c)
        if m > self.a.n:
            self.a = Ary[Self.T].make(m)
        else:
            for i in range(self.a.n):
                self.a.p[unsafe_offset=i] = rt_zero[Self.T]()
        for i in range(m):
            self.a.p[unsafe_offset=i] = elem_copy(x)
        self.n = Int32(m)

    def assign(mut self, b: Iter[Self.T], e: Iter[Self.T]) raises:
        var m = Int(e.i - b.i)
        var na = Ary[Self.T].make(m)
        for i in range(m):
            na.p[unsafe_offset=i] = elem_copy(b.a.p[unsafe_offset=Int(b.i) + i])
        self.a = na
        self.n = Int32(m)

    def assign(mut self, il: Ary[Self.T]) raises:
        var na = Ary[Self.T].make(il.n)
        for i in range(il.n):
            na.p[unsafe_offset=i] = elem_copy(il.p[unsafe_offset=i])
        self.a = na
        self.n = Int32(il.n)

    def shrink_to_fit(mut self) raises:
        if self.a.n != Int(self.n):
            self.resize_cap(Int(self.n))

    def swap_(mut self, o: Ref[Vec[Self.T]]) raises:
        var ta = self.a
        var tn = self.n
        self.a = o[].a
        self.n = o[].n
        o[].a = ta
        o[].n = tn

    def begin(self) raises -> Iter[Self.T]:
        return Iter[Self.T](self.a, 0)

    def end(self) raises -> Iter[Self.T]:
        return Iter[Self.T](self.a, Int64(self.n))

    def cbegin(self) raises -> Iter[Self.T]:
        return Iter[Self.T](self.a, 0)

    def cend(self) raises -> Iter[Self.T]:
        return Iter[Self.T](self.a, Int64(self.n))

    def rbegin(mut self) raises -> RevIter[Self.T]:
        return RevIter[Self.T](self.me(), Int64(self.n))

    def rend(mut self) raises -> RevIter[Self.T]:
        return RevIter[Self.T](self.me(), 0)

    def open_gap(mut self, p: Int, m: Int):
        var n = Int(self.n)
        self.grow(n + m)
        var k = n - 1
        while k >= p:
            self.a.p[unsafe_offset=k + m] = self.a.p[unsafe_offset=k]
            k -= 1
        self.n = Int32(n + m)

    def insert(mut self, pos: Iter[Self.T], x: Self.T) raises -> Iter[Self.T]:
        var p = Int(pos.i)
        self.open_gap(p, 1)
        self.a.p[unsafe_offset=p] = x
        return Iter[Self.T](self.a, pos.i)

    def insert(mut self, pos: Iter[Self.T], b: Iter[Self.T], e: Iter[Self.T]) raises -> Iter[Self.T]:
        var p = Int(pos.i)
        var m = Int(e.i - b.i)
        var tmp = gc_array[Self.T](m)
        for i in range(m):
            tmp[unsafe_offset=i] = elem_copy(b.a.p[unsafe_offset=Int(b.i) + i])
        self.open_gap(p, m)
        for i in range(m):
            self.a.p[unsafe_offset=p + i] = tmp[unsafe_offset=i]
        return Iter[Self.T](self.a, pos.i)

    def insert(mut self, pos: Iter[Self.T], il: Ary[Self.T]) raises -> Iter[Self.T]:
        var p = Int(pos.i)
        var m = il.n
        var tmp = gc_array[Self.T](m)
        for i in range(m):
            tmp[unsafe_offset=i] = elem_copy(il.p[unsafe_offset=i])
        self.open_gap(p, m)
        for i in range(m):
            self.a.p[unsafe_offset=p + i] = tmp[unsafe_offset=i]
        return Iter[Self.T](self.a, pos.i)

    def insert(mut self, pos: Iter[Self.T], b: Ptr[Self.T], e: Ptr[Self.T]) raises -> Iter[Self.T]:
        var p = Int(pos.i)
        var m = Int(e.diff(b))
        var tmp = gc_array[Self.T](m)
        for i in range(m):
            tmp[unsafe_offset=i] = elem_copy(b.p[unsafe_offset=i])
        self.open_gap(p, m)
        for i in range(m):
            self.a.p[unsafe_offset=p + i] = tmp[unsafe_offset=i]
        return Iter[Self.T](self.a, pos.i)

    def insert(mut self, pos: Iter[Self.T], cnt: UInt64, x: Self.T) raises -> Iter[Self.T]:
        var p = Int(pos.i)
        var m = Int(cnt)
        self.open_gap(p, m)
        for i in range(m):
            self.a.p[unsafe_offset=p + i] = elem_copy(x)
        return Iter[Self.T](self.a, pos.i)

    def erase(mut self, pos: Iter[Self.T]) raises -> Iter[Self.T]:
        var p = Int(pos.i)
        var n = Int(self.n)
        for i in range(p, n - 1):
            self.a.p[unsafe_offset=i] = self.a.p[unsafe_offset=i + 1]
        self.n -= 1
        self.a.p[unsafe_offset=n - 1] = rt_zero[Self.T]()
        return Iter[Self.T](self.a, pos.i)

    def erase(mut self, b: Iter[Self.T], e: Iter[Self.T]) raises -> Iter[Self.T]:
        var p = Int(b.i)
        var q = Int(e.i)
        var n = Int(self.n)
        var m = q - p
        for i in range(p, n - m):
            self.a.p[unsafe_offset=i] = self.a.p[unsafe_offset=i + m]
        for i in range(n - m, n):
            self.a.p[unsafe_offset=i] = rt_zero[Self.T]()
        self.n = Int32(n - m)
        return Iter[Self.T](self.a, b.i)

    def Clone(mut self) raises -> Ref[Vec[Self.T]]:
        var v = Self.raw()
        v[].mk = self.mk
        v[].mk2 = self.mk2
        var n = Int(self.n)
        v[].a = Ary[Self.T].make(n)
        v[].n = self.n
        for i in range(n):
            v[].a.p[unsafe_offset=i] = elem_copy(self.a.p[unsafe_offset=i])
        return v

    def Assign(mut self, o: Ref[Vec[Self.T]]) raises:
        if Int(o.p) == Int(rt_addr(self)):
            return
        var n = Int(o[].n)
        var na = Ary[Self.T].make(n)
        for i in range(n):
            na.p[unsafe_offset=i] = elem_copy(o[].a.p[unsafe_offset=i])
        self.a = na
        self.n = o[].n
        if self.mk == 0:
            self.mk = o[].mk
            self.mk2 = o[].mk2

    def Assign(mut self, il: Ary[Self.T]) raises:
        self.assign(il)

    def MoveFrom(mut self, o: Ref[Vec[Self.T]]) raises:
        """move-assign: take o's storage and leave o empty, as libstdc++ does"""
        if Int(o.p) == Int(rt_addr(self)):
            return
        self.a = o[].a
        self.n = o[].n
        if self.mk == 0:
            self.mk = o[].mk
            self.mk2 = o[].mk2
        o[].a = Ary[Self.T](gc_array[Self.T](0), 0)
        o[].n = 0

    def MoveFrom(mut self, il: Ary[Self.T]) raises:
        self.assign(il)

    def DestroyElems(mut self) raises:
        for i in range(Int(self.n)):
            rt_dispose(self.a.p[unsafe_offset=i])

    @staticmethod
    def Eq(x: Ref[Vec[Self.T]], y: Ref[Vec[Self.T]]) raises -> Bool:
        if x[].n != y[].n:
            return False
        for i in range(Int(x[].n)):
            if not elem_eq(x[].a.p[unsafe_offset=i], y[].a.p[unsafe_offset=i]):
                return False
        return True


def elem_makes[T: Elem]() -> Bool:
    """whether a new element is more than zero bytes: a class that a container constructs"""
    comptime if conforms_to(T, ElemOps):
        return T.MAKES
    return False


def elem_make_n[T: Elem](n: Int, n2: Int) raises -> T:
    comptime if conforms_to(T, ElemOps):
        return T.e_make_n(n, n2)
    return rt_zero[T]()


struct RevIter[T: Elem](ImplicitlyCopyable):
    var v: Ref[Vec[Self.T]]
    var i: Int64

    def __init__(out self, v: Ref[Vec[Self.T]], i: Int64):
        self.v = v
        self.i = i

    def p_Deref(self) -> P[Self.T]:
        return self.v[].a.ptr(Int(self.i) - 1)

    @staticmethod
    def op_inc(x: Self) -> Self:
        return Self(x.v, x.i - 1)

    @staticmethod
    def op_eq(x: Self, y: Self) -> Bool:
        return x.i == y.i

    @staticmethod
    def op_ne(x: Self, y: Self) -> Bool:
        return x.i != y.i


struct CSpan[T: Elem](ImplicitlyCopyable):
    var a: Ary[Self.T]
    var o: Int64
    var n: Int64

    def __init__(out self):
        self.a = Ary[Self.T]()
        self.o = 0
        self.n = 0

    def __init__(out self, a: Ary[Self.T], o: Int64, n: Int64):
        self.a = a
        self.o = o
        self.n = n

    def empty(self) raises -> Bool:
        return self.n == 0

    def size(self) raises -> UInt64:
        return UInt64(Int(self.n))

    def p_At(self, i: Int64) -> P[Self.T]:
        return self.a.ptr(Int(self.o + i))


# ================================================================ std::pair, std::optional, std::variant, tuples
struct Pair[A: Elem, B: Elem](EStruct):
    var first: Self.A
    var second: Self.B
    comptime IS_CLASS = True
    comptime LIB = True

    @staticmethod
    def new_() raises -> Ref[Pair[Self.A, Self.B]]:
        var p = Ref[Pair[Self.A, Self.B]](gc_new[Pair[Self.A, Self.B]]())
        p[].first = elem_make[Self.A]()
        p[].second = elem_make[Self.B]()
        return p

    @staticmethod
    def new_(a: Self.A, b: Self.B) raises -> Ref[Pair[Self.A, Self.B]]:
        var p = Ref[Pair[Self.A, Self.B]](gc_new[Pair[Self.A, Self.B]]())
        p[].first = a
        p[].second = b
        return p

    @staticmethod
    def __new() raises -> Ref[Pair[Self.A, Self.B]]:
        return Self.new_()

    @staticmethod
    def __clone(x: Ref[Pair[Self.A, Self.B]]) raises -> Ref[Pair[Self.A, Self.B]]:
        return Self.new_(elem_copy(x[].first), elem_copy(x[].second))

    @staticmethod
    def __assign(d: Ref[Pair[Self.A, Self.B]], x: Ref[Pair[Self.A, Self.B]]) raises:
        d[].first = elem_copy(x[].first)
        d[].second = elem_copy(x[].second)

    @staticmethod
    def __less(a: Ref[Pair[Self.A, Self.B]], b: Ref[Pair[Self.A, Self.B]]) raises -> Bool:
        return Self.cmp(a, b) < 0

    @staticmethod
    def __eqv(a: Ref[Pair[Self.A, Self.B]], b: Ref[Pair[Self.A, Self.B]]) raises -> Bool:
        return elem_eq(a[].first, b[].first) and elem_eq(a[].second, b[].second)

    def Clone(mut self) raises -> Ref[Pair[Self.A, Self.B]]:
        return Self.new_(elem_copy(self.first), elem_copy(self.second))

    def Assign(mut self, o: Ref[Pair[Self.A, Self.B]]) raises:
        self.first = elem_copy(o[].first)
        self.second = elem_copy(o[].second)

    @staticmethod
    def cmp(x: Ref[Pair[Self.A, Self.B]], o: Ref[Pair[Self.A, Self.B]]) raises -> Int32:
        """std::pair's operator<: first, then second"""
        if elem_less(x[].first, o[].first):
            return -1
        if elem_less(o[].first, x[].first):
            return 1
        if elem_less(x[].second, o[].second):
            return -1
        if elem_less(o[].second, x[].second):
            return 1
        return 0

    @staticmethod
    def op_lt(x: Ref[Pair[Self.A, Self.B]], y: Ref[Pair[Self.A, Self.B]]) raises -> Bool:
        return Self.cmp(x, y) < 0

    @staticmethod
    def op_gt(x: Ref[Pair[Self.A, Self.B]], y: Ref[Pair[Self.A, Self.B]]) raises -> Bool:
        return Self.cmp(x, y) > 0

    @staticmethod
    def op_eq(x: Ref[Pair[Self.A, Self.B]], y: Ref[Pair[Self.A, Self.B]]) raises -> Bool:
        return Self.__eqv(x, y)

    @staticmethod
    def Eq(x: Ref[Pair[Self.A, Self.B]], y: Ref[Pair[Self.A, Self.B]]) raises -> Bool:
        return Self.__eqv(x, y)


struct Opt[T: Elem](EStruct):
    var has: Bool
    var val: Self.T
    comptime IS_CLASS = True
    comptime LIB = True

    @staticmethod
    def new_() raises -> Ref[Opt[Self.T]]:
        return Ref[Opt[Self.T]](gc_new[Opt[Self.T]]())

    @staticmethod
    def new_(v: Self.T) raises -> Ref[Opt[Self.T]]:
        var o = Self.new_()
        o[].has = True
        o[].val = v
        return o

    @staticmethod
    def __new() raises -> Ref[Opt[Self.T]]:
        return Self.new_()

    @staticmethod
    def __clone(x: Ref[Opt[Self.T]]) raises -> Ref[Opt[Self.T]]:
        return x[].Clone()

    @staticmethod
    def __assign(d: Ref[Opt[Self.T]], x: Ref[Opt[Self.T]]) raises:
        d[].Assign(x)

    @staticmethod
    def __moveFrom(d: Ref[Opt[Self.T]], x: Ref[Opt[Self.T]]) raises:
        d[].MoveFrom(x)

    @staticmethod
    def __dispose(x: Ref[Opt[Self.T]]) raises:
        if x[].has:
            rt_dispose(x[].val)

    def DestroyElems(mut self) raises:
        if self.has:
            rt_dispose(self.val)

    def has_value(self) raises -> Bool:
        return self.has

    def value(mut self) raises -> P[Self.T]:
        if not self.has:
            raise rt_throw(rt_exc_kind(11, "bad optional access"))
        return rt_addr(self.val)

    def p_Deref(mut self) -> P[Self.T]:
        return rt_addr(self.val)

    def value_or(self, d: Self.T) raises -> Self.T:
        return self.val if self.has else d

    def reset(mut self) raises:
        self.has = False
        self.val = rt_zero[Self.T]()

    def MoveFrom(mut self, o: Ref[Opt[Self.T]]) raises:
        if Int(o.p) == Int(rt_addr(self)):
            return
        self.has = o[].has
        self.val = o[].val

    def emplace(mut self, v: Self.T) raises -> P[Self.T]:
        self.has = True
        self.val = v
        return rt_addr(self.val)

    def Clone(mut self) raises -> Ref[Opt[Self.T]]:
        if self.has:
            return Self.new_(elem_copy(self.val))
        return Self.new_()

    def Assign(mut self, o: Ref[Opt[Self.T]]) raises:
        self.has = o[].has
        self.val = elem_copy(o[].val) if o[].has else rt_zero[Self.T]()

    def Set(mut self, v: Self.T) raises:
        self.has = True
        self.val = v


struct Variant(EStruct):
    var b: Bool
    var i: Int32
    var d: Float64
    var s: Ref[Str]
    var idx: Int32
    comptime IS_CLASS = True
    comptime LIB = True

    @staticmethod
    def new_() raises -> Ref[Variant]:
        return Ref[Variant](gc_new[Variant]())

    @staticmethod
    def __new() raises -> Ref[Variant]:
        return Variant.new_()

    @staticmethod
    def __clone(x: Ref[Variant]) raises -> Ref[Variant]:
        var c = Variant.new_()
        c[].Assign(x)
        return c

    @staticmethod
    def __assign(d: Ref[Variant], x: Ref[Variant]) raises:
        d[].Assign(x)

    @staticmethod
    def __moveFrom(d: Ref[Variant], x: Ref[Variant]) raises:
        d[].MoveFrom(x)

    def clear_(mut self):
        self.b = False
        self.i = 0
        self.d = 0.0
        self.s = Ref[Str]()

    def Set(mut self, x: Bool) raises:
        self.clear_()
        self.b = x
        self.idx = 0

    def Set(mut self, x: Int32) raises:
        self.clear_()
        self.i = x
        self.idx = 1

    def Set(mut self, x: Float64) raises:
        self.clear_()
        self.d = x
        self.idx = 2

    def Set(mut self, x: Ref[Str]) raises:
        self.clear_()
        self.s = Str.__clone(x)
        self.idx = 3

    def index(self) raises -> UInt64:
        return UInt64(Int(self.idx))

    def Clone(mut self) raises -> Ref[Variant]:
        var c = Variant.new_()
        c[].Assign(Ref[Variant](rt_addr(self)))
        return c

    def Assign(mut self, o: Ref[Variant]) raises:
        self.b = o[].b
        self.i = o[].i
        self.d = o[].d
        self.idx = o[].idx
        self.s = Str.__clone(o[].s) if not o[].s.isnull() else Ref[Str]()

    def MoveFrom(mut self, o: Ref[Variant]) raises:
        self.b = o[].b
        self.i = o[].i
        self.d = o[].d
        self.idx = o[].idx
        self.s = o[].s


struct ArgList(Movable):
    var p: P[Arg]
    var n: Int

    @staticmethod
    def make(n: Int) -> P[ArgList]:
        var l = gc_new[ArgList]()
        l[].p = gc_bytes(max(n, 1) * size_of[Arg]()).unsafe_bitcast[Arg]()
        l[].n = n
        return l

    def __getitem__(self, i: Int) -> ref[MutUntrackedOrigin] Arg:
        return self.p[unsafe_offset=i]


struct TupN(EStruct):
    """std::tuple of more than three elements (a map key compared element by element, as std::tuple's operator<)"""
    var v: P[ArgList]
    comptime IS_CLASS = True
    comptime LIB = True

    @staticmethod
    def new_() raises -> Ref[TupN]:
        var t = Ref[TupN](gc_new[TupN]())
        t[].v = ArgList.make(0)
        return t

    @staticmethod
    def new_(*items: Arg) raises -> Ref[TupN]:
        var t = Ref[TupN](gc_new[TupN]())
        t[].v = ArgList.make(len(items))
        for i in range(len(items)):
            t[].v[][i] = items[i].copy()
        return t

    @staticmethod
    def __new() raises -> Ref[TupN]:
        return TupN.new_()

    @staticmethod
    def __clone(x: Ref[TupN]) raises -> Ref[TupN]:
        var t = Ref[TupN](gc_new[TupN]())
        t[].v = ArgList.make(x[].v[].n)
        for i in range(x[].v[].n):
            t[].v[][i] = x[].v[][i].copy()
        return t

    @staticmethod
    def __assign(d: Ref[TupN], x: Ref[TupN]) raises:
        d[].v = TupN.__clone(x)[].v

    @staticmethod
    def __moveFrom(d: Ref[TupN], x: Ref[TupN]) raises:
        d[].v = x[].v

    @staticmethod
    def __less(a: Ref[TupN], b: Ref[TupN]) raises -> Bool:
        return TupN.cmp(a, b) < 0

    @staticmethod
    def __eqv(a: Ref[TupN], b: Ref[TupN]) raises -> Bool:
        return TupN.cmp(a, b) == 0

    @staticmethod
    def cmp(a: Ref[TupN], b: Ref[TupN]) raises -> Int32:
        for i in range(a[].v[].n):
            var x = a[].v[][i].copy()
            var y = b[].v[][i].copy()
            var c: Int32 = 0
            if x.kind == 5:
                c = Int32(-1) if x.d < y.d else (Int32(1) if y.d < x.d else Int32(0))
            elif x.kind == 4:
                var p = UInt64(x.i)
                var q = UInt64(y.i)
                c = Int32(-1) if p < q else (Int32(1) if p > q else Int32(0))
            elif x.kind == 7:
                var s = Ref[Str](P[Str](unsafe_from_address=x.a))
                var t = Ref[Str](P[Str](unsafe_from_address=y.a))
                c = bytes_cmp(s[].b.p, Int(s[].n), t[].b.p, Int(t[].n))
            elif x.kind == 6:
                c = Int32(-1) if x.a < y.a else (Int32(1) if x.a > y.a else Int32(0))
            else:
                c = Int32(-1) if x.i < y.i else (Int32(1) if x.i > y.i else Int32(0))
            if c != 0:
                return c
        return 0

    def CompareTo(self, o: Ref[TupN]) raises -> Int32:
        return TupN.cmp(Ref[TupN](rt_addr(self)), o)


# ================================================================ hashed containers (libstdc++'s _Hashtable)
trait KeyHash:
    comptime HAS: Bool = True

    @staticmethod
    def __hash_str(k: Ref[Str]) raises -> UInt64:
        ...


trait KeyEq:
    comptime HAS: Bool = True

    @staticmethod
    def __eq_str(a: Ref[Str], b: Ref[Str]) raises -> Bool:
        ...


struct NoHash(KeyHash):
    comptime HAS = False

    @staticmethod
    def __hash_str(k: Ref[Str]) raises -> UInt64:
        return 0


struct NoEq(KeyEq):
    comptime HAS = False

    @staticmethod
    def __eq_str(a: Ref[Str], b: Ref[Str]) raises -> Bool:
        return False


struct HNode[E: Elem](Movable):
    var next: P[HNode[Self.E]]
    var val: Self.E
    var code: UInt64


struct RehashPolicy(Movable):
    """the prime rehash policy (libstdc++ src/c++11/hashtable_c++0x.cc and hashtable-aux.cc)"""
    var max_load: Float64
    var next_resize: UInt64

    def next_bkt(mut self, n: UInt64) -> UInt64:
        if n < 14:
            if n == 0:
                return 1
            var fb = _fast_bkt(Int(n))
            self.next_resize = _floor_u(Float64(fb) * self.max_load)
            return UInt64(fb)
        var last = N_PRIMES - 1      # __prime_list + __n_primes - 1 (the sentinel is excluded)
        var lo = 6
        var hi = last
        while lo < hi:
            var mid = (lo + hi) // 2
            if PRIMES(mid) < n:
                lo = mid + 1
            else:
                hi = mid
        if lo == last:
            self.next_resize = UInt64(0xFFFFFFFFFFFFFFFF)
        else:
            self.next_resize = _floor_u(PRIMES(lo).cast[DType.float64]() * self.max_load)
        return PRIMES(lo)

    def bkt_for_elements(self, n: UInt64) -> UInt64:
        return rt_d2uint64(Math.Ceiling(n.cast[DType.float64]() / self.max_load))

    def need_rehash(mut self, n_bkt: UInt64, n_elt: UInt64, n_ins: UInt64) -> UInt64:
        """the new bucket count, or 0 for none"""
        if n_elt + n_ins > self.next_resize:
            var base = max(n_elt + n_ins, UInt64(0) if self.next_resize != 0 else UInt64(11))
            var min_bkts = base.cast[DType.float64]() / self.max_load
            if min_bkts >= n_bkt.cast[DType.float64]():
                return self.next_bkt(max(_floor_u(min_bkts) + 1, n_bkt * 2))
            self.next_resize = _floor_u(n_bkt.cast[DType.float64]() * self.max_load)
            return 0
        return 0


def _fast_bkt(n: Int) -> Int:
    if n <= 2:
        return 2
    if n == 3:
        return 3
    if n <= 5:
        return 5
    if n <= 7:
        return 7
    if n <= 11:
        return 11
    return 13


def _floor_u(x: Float64) -> UInt64:
    return rt_d2uint64(Math.Floor(x))


struct MIt[E: Elem](ImplicitlyCopyable, ElemOps):
    """an iterator over a hashed or sorted container: a node (0 at the end) or a position in a sorted list"""
    var node: Int
    var list: Int
    var pos: Int32
    comptime NEEDS_COPY = False

    def __init__(out self):
        self.node = 0
        self.list = 0
        self.pos = 0

    def __init__(out self, node: Int, list: Int, pos: Int32):
        self.node = node
        self.list = list
        self.pos = pos

    def p_Deref(self) -> Self.E:
        if self.list != 0:
            return P[SList[Self.E]](unsafe_from_address=self.list)[].at(Int(self.pos))
        return P[HNode[Self.E]](unsafe_from_address=self.node)[].val

    @staticmethod
    def op_inc(x: Self) -> Self:
        if x.list != 0:
            return Self(0, x.list, x.pos + 1)
        return Self(Int(P[HNode[Self.E]](unsafe_from_address=x.node)[].next), 0, 0)

    @staticmethod
    def op_dec(x: Self) -> Self:
        return Self(0, x.list, x.pos - 1)

    @staticmethod
    def op_eq(a: Self, b: Self) -> Bool:
        if a.list != 0 or b.list != 0:
            var pa = Int(a.pos) if a.list != 0 else 2147483647
            var pb = Int(b.pos) if b.list != 0 else 2147483647
            return pa == pb
        return a.node == b.node

    @staticmethod
    def op_ne(a: Self, b: Self) -> Bool:
        return not Self.op_eq(a, b)

    @staticmethod
    def e_make() raises -> Self:
        return Self()

    def e_copy(self) raises -> Self:
        return self

    def e_eq(self, o: Self) raises -> Bool:
        return Self.op_eq(self, o)

    def e_less(self, o: Self) raises -> Bool:
        return self.pos < o.pos

    def e_hash(self) raises -> UInt64:
        return UInt64(self.node + Int(self.pos))


struct ItemIter[E: Elem](Movable):
    """an enumeration of a container's elements (C#'s Items()), for a foreach"""
    var node: Int
    var list: Int
    var pos: Int
    var cur_: Self.E

    def __init__(out self, node: Int, list: Int, pos: Int):
        self.node = node
        self.list = list
        self.pos = pos
        self.cur_ = rt_zero[Self.E]()

    def next(mut self) -> Bool:
        if self.list != 0:
            var l = P[SList[Self.E]](unsafe_from_address=self.list)
            if self.pos >= l[].n:
                return False
            self.cur_ = l[].at(self.pos)
            self.pos += 1
            return True
        if self.node == 0:
            return False
        var n = P[HNode[Self.E]](unsafe_from_address=self.node)
        self.cur_ = n[].val
        self.node = Int(n[].next)
        return True

    def cur(self) -> Self.E:
        return self.cur_


struct HashTable[K: Elem, V: Elem, E: Elem, IS_MAP: Bool, H: KeyHash, Q: KeyEq](EStruct):
    """libstdc++'s _Hashtable for unique keys. E is the stored element: a Pair(K, V) for a map, K for a set"""
    var buckets: P[P[HNode[Self.E]]]
    var nbkt: Int
    var before_begin: P[HNode[Self.E]]
    var nelem: UInt64
    var pol: RehashPolicy
    var mk: Int
    var mk2: Int
    comptime IS_CLASS = True
    comptime LIB = True
    comptime NodeP = P[HNode[Self.E]]

    @staticmethod
    def init() -> Ref[Self]:
        var t = Ref[Self](gc_new[Self]())
        t[].buckets = gc_array[Self.NodeP](1)
        t[].nbkt = 1
        t[].before_begin = gc_new[HNode[Self.E]]()
        t[].pol.max_load = 1.0
        return t

    @staticmethod
    def new_(mk: Int = 0, mk2: Int = 0) raises -> Ref[Self]:
        var t = Self.init()
        t[].mk = mk
        t[].mk2 = mk2
        return t

    @staticmethod
    def new_(il: Ary[Self.E]) raises -> Ref[Self]:
        var t = Self.init()
        for i in range(il.n):
            _ = t[].insert_elem(elem_copy(il.p[unsafe_offset=i]))
        return t

    @staticmethod
    def __new() raises -> Ref[Self]:
        return Self.init()

    @staticmethod
    def __clone(x: Ref[Self]) raises -> Ref[Self]:
        return x[].Clone()

    @staticmethod
    def __assign(d: Ref[Self], x: Ref[Self]) raises:
        d[].Assign(x)

    @staticmethod
    def __moveFrom(d: Ref[Self], x: Ref[Self]) raises:
        d[].MoveFrom(x)

    def me(mut self) -> Ref[Self]:
        return Ref[Self](rt_addr(self))

    @staticmethod
    def key(e: Self.E) -> Self.K:
        comptime if Self.IS_MAP:
            return rebind[Ref[Pair[Self.K, Self.V]]](e)[].first
        return rebind[Self.K](e)

    def hash_of(self, k: Self.K) raises -> UInt64:
        comptime if Self.H.HAS:
            return Self.H.__hash_str(rebind[Ref[Str]](k))
        return elem_hash(k)

    def eq_of(self, a: Self.K, b: Self.K) raises -> Bool:
        comptime if Self.Q.HAS:
            return Self.Q.__eq_str(rebind[Ref[Str]](a), rebind[Ref[Str]](b))
        return elem_eq(a, b)

    @always_inline
    def bkt(self, code: UInt64) -> Int:
        return Int(code % UInt64(self.nbkt))

    def find_node(self, k: Self.K) raises -> Self.NodeP:
        var code = self.hash_of(k)
        var b = self.bkt(code)
        var before = self.buckets[unsafe_offset=b]
        if pnull(before):
            return before
        var p = before[].next
        while not pnull(p):
            if p[].code == code and self.eq_of(k, Self.key(p[].val)):
                return p
            if pnull(p[].next) or self.bkt(p[].next[].code) != b:
                break
            p = p[].next
        return rt_null[HNode[Self.E]]()

    def insert_elem(mut self, e: Self.E) raises -> Pair2:
        var k = Self.key(e)
        var f = self.find_node(k)
        if not pnull(f):
            return Pair2(Int(f), False)
        var code = self.hash_of(k)
        var n = self.pol.need_rehash(UInt64(self.nbkt), self.nelem, 1)
        if n != 0:
            self.rehash_to(n)
        var node = gc_new[HNode[Self.E]]()
        node[].val = e
        node[].code = code
        self.insert_bucket_begin(self.bkt(code), node)
        self.nelem += 1
        return Pair2(Int(node), True)

    def insert_bucket_begin(mut self, b: Int, node: Self.NodeP):
        var first = self.buckets[unsafe_offset=b]
        if not pnull(first):
            node[].next = first[].next
            first[].next = node
        else:
            node[].next = self.before_begin[].next
            self.before_begin[].next = node
            if not pnull(node[].next):
                self.buckets[unsafe_offset=self.bkt(node[].next[].code)] = node
            self.buckets[unsafe_offset=b] = self.before_begin

    def rehash_to(mut self, n: UInt64):
        var nb = gc_array[Self.NodeP](Int(n))
        var p = self.before_begin[].next
        self.before_begin[].next = rt_null[HNode[Self.E]]()
        var bbegin_bkt = 0
        while not pnull(p):
            var next = p[].next
            var b = Int(p[].code % n)
            if pnull(nb[unsafe_offset=b]):
                p[].next = self.before_begin[].next
                self.before_begin[].next = p
                nb[unsafe_offset=b] = self.before_begin
                if not pnull(p[].next):
                    nb[unsafe_offset=bbegin_bkt] = p
                bbegin_bkt = b
            else:
                p[].next = nb[unsafe_offset=b][].next
                nb[unsafe_offset=b][].next = p
            p = next
        self.buckets = nb
        self.nbkt = Int(n)

    def erase_key(mut self, k: Self.K) raises -> Bool:
        var code = self.hash_of(k)
        var b = self.bkt(code)
        var prev = self.buckets[unsafe_offset=b]
        if pnull(prev):
            return False
        var p = prev[].next
        while not pnull(p):
            if p[].code == code and self.eq_of(k, Self.key(p[].val)):
                break
            if pnull(p[].next) or self.bkt(p[].next[].code) != b:
                return False
            prev = p
            p = p[].next
        if pnull(p):
            return False
        self.erase_node(b, prev, p)
        return True

    def erase_node(mut self, b: Int, prev: Self.NodeP, n: Self.NodeP):
        if Int(prev) == Int(self.buckets[unsafe_offset=b]):
            # removing the bucket's first node (_M_remove_bucket_begin)
            var next = n[].next
            var next_bkt = self.bkt(next[].code) if not pnull(next) else 0
            if pnull(next) or next_bkt != b:
                if not pnull(next):
                    self.buckets[unsafe_offset=next_bkt] = self.buckets[unsafe_offset=b]
                if Int(self.buckets[unsafe_offset=b]) == Int(self.before_begin):
                    self.before_begin[].next = next
                self.buckets[unsafe_offset=b] = rt_null[HNode[Self.E]]()
        elif not pnull(n[].next):
            var nb2 = self.bkt(n[].next[].code)
            if nb2 != b:
                self.buckets[unsafe_offset=nb2] = prev
        prev[].next = n[].next
        self.nelem -= 1

    def erase_at(mut self, n: Self.NodeP):
        var b = self.bkt(n[].code)
        var prev = self.buckets[unsafe_offset=b]
        while Int(prev[].next) != Int(n):
            prev = prev[].next
        self.erase_node(b, prev, n)

    def copy_from(mut self, o: Ref[Self], deep: Bool) raises:
        # _M_assign: same bucket count, same node order
        self.buckets = gc_array[Self.NodeP](o[].nbkt)
        self.nbkt = o[].nbkt
        self.before_begin[].next = rt_null[HNode[Self.E]]()
        self.nelem = 0
        self.pol.next_resize = o[].pol.next_resize
        var prev = self.before_begin
        var p = o[].before_begin[].next
        while not pnull(p):
            var n = gc_new[HNode[Self.E]]()
            n[].val = elem_copy(p[].val) if deep else p[].val
            n[].code = p[].code
            prev[].next = n
            var b = self.bkt(n[].code)
            if pnull(self.buckets[unsafe_offset=b]):
                self.buckets[unsafe_offset=b] = prev
            prev = n
            self.nelem += 1
            p = p[].next

    # ---- the public interface
    def size(self) raises -> UInt64:
        return self.nelem

    def empty(self) raises -> Bool:
        return self.nelem == 0

    def clear(mut self) raises:
        self.buckets = gc_array[Self.NodeP](self.nbkt)
        self.before_begin[].next = rt_null[HNode[Self.E]]()
        self.nelem = 0

    def bucket_count(self) raises -> UInt64:
        return UInt64(self.nbkt)

    def reserve(mut self, n: UInt64) raises:
        self.rehash(self.pol.bkt_for_elements(n))

    def rehash(mut self, n: UInt64) raises:
        var want = self.pol.next_bkt(max(n, self.pol.bkt_for_elements(self.nelem + 1)))
        if want != UInt64(self.nbkt):
            self.rehash_to(want)

    def Items(self) raises -> ItemIter[Self.E]:
        return ItemIter[Self.E](Int(self.before_begin[].next), 0, 0)

    def begin(self) raises -> MIt[Self.E]:
        return MIt[Self.E](Int(self.before_begin[].next), 0, 0)

    def end(self) raises -> MIt[Self.E]:
        return MIt[Self.E]()

    def find(self, k: Self.K) raises -> MIt[Self.E]:
        return MIt[Self.E](Int(self.find_node(k)), 0, 0)

    def count(self, k: Self.K) raises -> UInt64:
        return UInt64(0) if pnull(self.find_node(k)) else UInt64(1)

    def count_(self, k: Self.K) raises -> UInt64:
        return self.count(k)

    def contains(self, k: Self.K) raises -> Bool:
        return not pnull(self.find_node(k))

    def erase(mut self, k: Self.K) raises -> UInt64:
        return UInt64(1) if self.erase_key(k) else UInt64(0)

    def erase(mut self, it: MIt[Self.E]) raises -> MIt[Self.E]:
        var n = Self.NodeP(unsafe_from_address=it.node)
        var nx = n[].next
        self.erase_at(n)
        return MIt[Self.E](Int(nx), 0, 0)

    # ---- maps
    def make_v(self) raises -> Self.V:
        if self.mk > 0:
            return elem_make_n[Self.V](self.mk, self.mk2)
        return elem_make[Self.V]()

    def Index(mut self, k: Self.K) raises -> P[Self.V]:
        """operator[]: the value, inserted default-constructed if absent (the map owns a copy of the key)"""
        var f = self.find_node(k)
        if pnull(f):
            var pr = Pair[Self.K, Self.V].new_(key_copy(k), self.make_v())
            f = Self.NodeP(unsafe_from_address=self.insert_elem(rebind[Self.E](pr)).a)
        return rt_addr(rebind[Ref[Pair[Self.K, Self.V]]](f[].val)[].second)

    def at(mut self, k: Self.K) raises -> P[Self.V]:
        var f = self.find_node(k)
        if pnull(f):
            raise rt_throw(rt_exc_kind(5, "_Map_base::at"))
        return rt_addr(rebind[Ref[Pair[Self.K, Self.V]]](f[].val)[].second)

    def insert_pair(mut self, k: Self.K, v: Self.V) raises -> Ref[Pair[MIt[Self.E], Bool]]:
        var pr = Pair[Self.K, Self.V].new_(key_copy(k), v)
        var r = self.insert_elem(rebind[Self.E](pr))
        return Pair[MIt[Self.E], Bool].new_(MIt[Self.E](r.a, 0, 0), r.b)

    def insert(mut self, x: Self.E) raises -> Ref[Pair[MIt[Self.E], Bool]]:
        """insert(pair) of a map, insert(key) of a set"""
        comptime if Self.IS_MAP:
            var pr = rebind[Ref[Pair[Self.K, Self.V]]](x)
            return self.insert_pair(pr[].first, pr[].second)
        var r = self.insert_elem(rebind[Self.E](key_copy(rebind[Self.K](x))))
        return Pair[MIt[Self.E], Bool].new_(MIt[Self.E](r.a, 0, 0), r.b)

    def emplace(mut self, x: Self.E) raises -> Ref[Pair[MIt[Self.E], Bool]]:
        return self.insert(x)

    def emplace(mut self, k: Self.K, v: Self.V) raises -> Ref[Pair[MIt[Self.E], Bool]]:
        return self.insert_pair(k, v)

    def try_emplace(mut self, k: Self.K, v: Self.V) raises -> Ref[Pair[MIt[Self.E], Bool]]:
        return self.insert_pair(k, v)

    def try_emplace(mut self, k: Self.K) raises -> Ref[Pair[MIt[Self.E], Bool]]:
        return self.insert_pair(k, self.make_v())

    def insert_or_assign(mut self, k: Self.K, v: Self.V) raises -> Ref[Pair[MIt[Self.E], Bool]]:
        var f = self.find_node(k)
        if not pnull(f):
            rebind[Ref[Pair[Self.K, Self.V]]](f[].val)[].second = v
            return Pair[MIt[Self.E], Bool].new_(MIt[Self.E](Int(f), 0, 0), False)
        return self.insert_pair(k, v)

    def Clone(mut self) raises -> Ref[Self]:
        var m = Self.init()
        m[].mk = self.mk
        m[].mk2 = self.mk2
        m[].copy_from(self.me(), True)
        return m

    def Assign(mut self, o: Ref[Self]) raises:
        if Int(o.p) != Int(rt_addr(self)):
            self.copy_from(o, True)

    def MoveFrom(mut self, o: Ref[Self]) raises:
        if Int(o.p) != Int(rt_addr(self)):
            self.copy_from(o, False)
            o[].clear()


struct Pair2(ImplicitlyCopyable):
    var a: Int
    var b: Bool

    def __init__(out self, a: Int, b: Bool):
        self.a = a
        self.b = b


def key_copy[K: Elem](x: K) raises -> K:
    """a key stored in a map or set is the container's own copy, as in C++, when the key is a library value (a
    string, a vector, a pair); an engine class as key is a pointer in C++, so it is stored as it is (lessons/68)"""
    comptime if conforms_to(K, ElemOps):
        comptime if K.LIB_VALUE:
            return elem_copy(x)
    return x


comptime UMap[K: Elem, V: Elem] = HashTable[K, V, Ref[Pair[K, V]], True, NoHash, NoEq]
comptime UMapC[K: Elem, V: Elem, H: KeyHash, Q: KeyEq] = HashTable[K, V, Ref[Pair[K, V]], True, H, Q]
comptime USet[T: Elem] = HashTable[T, Bool, T, False, NoHash, NoEq]
comptime USetC[T: Elem, H: KeyHash, Q: KeyEq] = HashTable[T, Bool, T, False, H, Q]


# ================================================================ sorted containers
struct Map[K: Elem, V: Elem](EStruct):
    """std::map: keys kept sorted (a red-black tree's order is the sorted order)"""
    var l: P[SList[Ref[Pair[Self.K, Self.V]]]]
    var mk: Int
    var mk2: Int
    comptime IS_CLASS = True
    comptime LIB = True
    comptime Ev = Ref[Pair[Self.K, Self.V]]

    @staticmethod
    def new_(mk: Int = 0, mk2: Int = 0) raises -> Ref[Self]:
        var m = Ref[Self](gc_new[Self]())
        m[].l = SList[Self.Ev].make()
        m[].mk = mk
        m[].mk2 = mk2
        return m

    @staticmethod
    def new_(il: Ary[Self.Ev]) raises -> Ref[Self]:
        var m = Self.new_()
        for i in range(il.n):
            _ = m[].insert(Pair[Self.K, Self.V].__clone(il.p[unsafe_offset=i]))
        return m

    @staticmethod
    def __new() raises -> Ref[Self]:
        return Self.new_()

    @staticmethod
    def __clone(x: Ref[Self]) raises -> Ref[Self]:
        return x[].Clone()

    @staticmethod
    def __assign(d: Ref[Self], x: Ref[Self]) raises:
        d[].Assign(x)

    @staticmethod
    def __moveFrom(d: Ref[Self], x: Ref[Self]) raises:
        d[].MoveFrom(x)

    def lower(self, k: Self.K) raises -> Int:
        var lo = 0
        var hi = self.l[].n
        while lo < hi:
            var mid = (lo + hi) // 2
            if elem_less(self.l[].at(mid)[].first, k):
                lo = mid + 1
            else:
                hi = mid
        return lo

    def find_i(self, k: Self.K) raises -> Int:
        var i = self.lower(k)
        if i < self.l[].n and not elem_less(k, self.l[].at(i)[].first):
            return i
        return -1

    def it(self, i: Int) -> MIt[Self.Ev]:
        return MIt[Self.Ev](0, Int(self.l), Int32(i))

    def make_v(self) raises -> Self.V:
        if self.mk > 0:
            return elem_make_n[Self.V](self.mk, self.mk2)
        return elem_make[Self.V]()

    def Index(mut self, k: Self.K) raises -> P[Self.V]:
        var i = self.lower(k)
        if i == self.l[].n or elem_less(k, self.l[].at(i)[].first):
            self.l[].insert_at(i, Pair[Self.K, Self.V].new_(key_copy(k), self.make_v()))
        return rt_addr(self.l[].at(i)[].second)

    def at(mut self, k: Self.K) raises -> P[Self.V]:
        var i = self.find_i(k)
        if i < 0:
            raise rt_throw(rt_exc_kind(5, "map::at"))
        return rt_addr(self.l[].at(i)[].second)

    def insert(mut self, p: Self.Ev) raises -> Ref[Pair[MIt[Self.Ev], Bool]]:
        var i = self.lower(p[].first)
        if i < self.l[].n and not elem_less(p[].first, self.l[].at(i)[].first):
            return Pair[MIt[Self.Ev], Bool].new_(self.it(i), False)
        self.l[].insert_at(i, Pair[Self.K, Self.V].new_(key_copy(p[].first), p[].second))
        return Pair[MIt[Self.Ev], Bool].new_(self.it(i), True)

    def emplace(mut self, k: Self.K, v: Self.V) raises -> Ref[Pair[MIt[Self.Ev], Bool]]:
        return self.insert(Pair[Self.K, Self.V].new_(k, v))

    def emplace(mut self, p: Self.Ev) raises -> Ref[Pair[MIt[Self.Ev], Bool]]:
        return self.insert(p)

    def try_emplace(mut self, k: Self.K, v: Self.V) raises -> Ref[Pair[MIt[Self.Ev], Bool]]:
        return self.insert(Pair[Self.K, Self.V].new_(k, v))

    def insert_or_assign(mut self, k: Self.K, v: Self.V) raises -> Ref[Pair[MIt[Self.Ev], Bool]]:
        var i = self.find_i(k)
        if i >= 0:
            self.l[].at(i)[].second = v
            return Pair[MIt[Self.Ev], Bool].new_(self.it(i), False)
        return self.insert(Pair[Self.K, Self.V].new_(k, v))

    def find(self, k: Self.K) raises -> MIt[Self.Ev]:
        var i = self.find_i(k)
        return self.it(self.l[].n if i < 0 else i)

    def lower_bound(self, k: Self.K) raises -> MIt[Self.Ev]:
        return self.it(self.lower(k))

    def upper_bound(self, k: Self.K) raises -> MIt[Self.Ev]:
        var i = self.lower(k)
        while i < self.l[].n and not elem_less(k, self.l[].at(i)[].first):
            i += 1
        return self.it(i)

    def count(self, k: Self.K) raises -> UInt64:
        return UInt64(1) if self.find_i(k) >= 0 else UInt64(0)

    def contains(self, k: Self.K) raises -> Bool:
        return self.find_i(k) >= 0

    def erase(mut self, k: Self.K) raises -> UInt64:
        var i = self.find_i(k)
        if i < 0:
            return 0
        self.l[].remove_at(i)
        return 1

    def erase(mut self, x: MIt[Self.Ev]) raises -> MIt[Self.Ev]:
        self.l[].remove_at(Int(x.pos))
        return self.it(Int(x.pos))

    def size(self) raises -> UInt64:
        return UInt64(self.l[].n)

    def empty(self) raises -> Bool:
        return self.l[].n == 0

    def clear(mut self) raises:
        self.l = SList[Self.Ev].make()

    def begin(self) raises -> MIt[Self.Ev]:
        return self.it(0)

    def end(self) raises -> MIt[Self.Ev]:
        return self.it(self.l[].n)

    def Items(self) raises -> ItemIter[Self.Ev]:
        return ItemIter[Self.Ev](0, Int(self.l), 0)

    def Clone(mut self) raises -> Ref[Self]:
        var m = Self.new_(self.mk, self.mk2)
        for i in range(self.l[].n):
            m[].l[].insert_at(i, Pair[Self.K, Self.V].__clone(self.l[].at(i)))
        return m

    def Assign(mut self, o: Ref[Self]) raises:
        if Int(o.p) == Int(rt_addr(self)):
            return
        var nl = SList[Self.Ev].make()
        for i in range(o[].l[].n):
            nl[].insert_at(i, Pair[Self.K, Self.V].__clone(o[].l[].at(i)))
        self.l = nl

    def MoveFrom(mut self, o: Ref[Self]) raises:
        if Int(o.p) == Int(rt_addr(self)):
            return
        self.l = o[].l
        o[].l = SList[Self.Ev].make()


struct Set[T: Elem](EStruct):
    var l: P[SList[Self.T]]
    comptime IS_CLASS = True
    comptime LIB = True

    @staticmethod
    def new_() raises -> Ref[Self]:
        var m = Ref[Self](gc_new[Self]())
        m[].l = SList[Self.T].make()
        return m

    @staticmethod
    def new_(il: Ary[Self.T]) raises -> Ref[Self]:
        var m = Self.new_()
        for i in range(il.n):
            _ = m[].insert(il.p[unsafe_offset=i])
        return m

    @staticmethod
    def __new() raises -> Ref[Self]:
        return Self.new_()

    @staticmethod
    def __clone(x: Ref[Self]) raises -> Ref[Self]:
        return x[].Clone()

    @staticmethod
    def __assign(d: Ref[Self], x: Ref[Self]) raises:
        d[].Assign(x)

    def lower(self, k: Self.T) raises -> Int:
        var lo = 0
        var hi = self.l[].n
        while lo < hi:
            var mid = (lo + hi) // 2
            if elem_less(self.l[].at(mid), k):
                lo = mid + 1
            else:
                hi = mid
        return lo

    def it(self, i: Int) -> MIt[Self.T]:
        return MIt[Self.T](0, Int(self.l), Int32(i))

    def insert(mut self, x: Self.T) raises -> Ref[Pair[MIt[Self.T], Bool]]:
        var i = self.lower(x)
        if i < self.l[].n and not elem_less(x, self.l[].at(i)):
            return Pair[MIt[Self.T], Bool].new_(self.it(i), False)
        self.l[].insert_at(i, key_copy(x))
        return Pair[MIt[Self.T], Bool].new_(self.it(i), True)

    def emplace(mut self, x: Self.T) raises -> Ref[Pair[MIt[Self.T], Bool]]:
        return self.insert(x)

    def find(self, k: Self.T) raises -> MIt[Self.T]:
        var i = self.lower(k)
        if i < self.l[].n and not elem_less(k, self.l[].at(i)):
            return self.it(i)
        return self.it(self.l[].n)

    def count(self, k: Self.T) raises -> UInt64:
        var i = self.lower(k)
        return UInt64(1) if (i < self.l[].n and not elem_less(k, self.l[].at(i))) else UInt64(0)

    def contains(self, k: Self.T) raises -> Bool:
        return self.count(k) > 0

    def erase(mut self, k: Self.T) raises -> UInt64:
        var i = self.lower(k)
        if i < self.l[].n and not elem_less(k, self.l[].at(i)):
            self.l[].remove_at(i)
            return 1
        return 0

    def erase(mut self, x: MIt[Self.T]) raises -> MIt[Self.T]:
        self.l[].remove_at(Int(x.pos))
        return self.it(Int(x.pos))

    def size(self) raises -> UInt64:
        return UInt64(self.l[].n)

    def empty(self) raises -> Bool:
        return self.l[].n == 0

    def clear(mut self) raises:
        self.l = SList[Self.T].make()

    def begin(self) raises -> MIt[Self.T]:
        return self.it(0)

    def end(self) raises -> MIt[Self.T]:
        return self.it(self.l[].n)

    def Items(self) raises -> ItemIter[Self.T]:
        return ItemIter[Self.T](0, Int(self.l), 0)

    def Clone(mut self) raises -> Ref[Self]:
        var m = Self.new_()
        for i in range(self.l[].n):
            m[].l[].insert_at(i, elem_copy(self.l[].at(i)))
        return m

    def Assign(mut self, o: Ref[Self]) raises:
        if Int(o.p) == Int(rt_addr(self)):
            return
        var nl = SList[Self.T].make()
        for i in range(o[].l[].n):
            nl[].insert_at(i, elem_copy(o[].l[].at(i)))
        self.l = nl

    def MoveFrom(mut self, o: Ref[Self]) raises:
        if Int(o.p) == Int(rt_addr(self)):
            return
        self.l = o[].l
        o[].l = SList[Self.T].make()


struct Stk[T: Elem](EStruct):
    """std::stack over std::deque"""
    var l: P[SList[Self.T]]
    comptime IS_CLASS = True
    comptime LIB = True

    @staticmethod
    def new_() raises -> Ref[Self]:
        var s = Ref[Self](gc_new[Self]())
        s[].l = SList[Self.T].make()
        return s

    @staticmethod
    def __new() raises -> Ref[Self]:
        return Self.new_()

    @staticmethod
    def __clone(x: Ref[Self]) raises -> Ref[Self]:
        var s = Self.new_()
        for i in range(x[].l[].n):
            s[].push(elem_copy(x[].l[].at(i)))
        return s

    @staticmethod
    def __assign(d: Ref[Self], x: Ref[Self]) raises:
        if Int(d.p) == Int(x.p):
            return
        d[].l = SList[Self.T].make()
        for i in range(x[].l[].n):
            d[].push(elem_copy(x[].l[].at(i)))

    def push(mut self, x: Self.T) raises:
        self.l[].insert_at(self.l[].n, x)

    def pop(mut self) raises:
        self.l[].n -= 1

    def top(mut self) raises -> P[Self.T]:
        return padd(self.l[].a, self.l[].n - 1)

    def empty(self) raises -> Bool:
        return self.l[].n == 0

    def size(self) raises -> UInt64:
        return UInt64(self.l[].n)

    def Clone(mut self) raises -> Ref[Self]:
        return Self.__clone(Ref[Self](rt_addr(self)))

    def Assign(mut self, o: Ref[Self]) raises:
        Self.__assign(Ref[Self](rt_addr(self)), o)


struct Que[T: Elem](EStruct):
    """std::queue over std::deque: first in, first out"""
    var l: P[SList[Self.T]]
    var head: Int
    comptime IS_CLASS = True
    comptime LIB = True

    @staticmethod
    def new_() raises -> Ref[Self]:
        var s = Ref[Self](gc_new[Self]())
        s[].l = SList[Self.T].make()
        return s

    @staticmethod
    def __new() raises -> Ref[Self]:
        return Self.new_()

    @staticmethod
    def __clone(x: Ref[Self]) raises -> Ref[Self]:
        var s = Self.new_()
        for i in range(x[].head, x[].l[].n):
            s[].push(elem_copy(x[].l[].at(i)))
        return s

    @staticmethod
    def __assign(d: Ref[Self], x: Ref[Self]) raises:
        if Int(d.p) == Int(x.p):
            return
        d[].l = SList[Self.T].make()
        d[].head = 0
        for i in range(x[].head, x[].l[].n):
            d[].push(elem_copy(x[].l[].at(i)))

    def push(mut self, x: Self.T) raises:
        self.l[].insert_at(self.l[].n, x)

    def pop(mut self) raises:
        self.l[].a[unsafe_offset=self.head] = rt_zero[Self.T]()
        self.head += 1

    def front(mut self) raises -> P[Self.T]:
        return padd(self.l[].a, self.head)

    def back(mut self) raises -> P[Self.T]:
        return padd(self.l[].a, self.l[].n - 1)

    def empty(self) raises -> Bool:
        return self.l[].n == self.head

    def size(self) raises -> UInt64:
        return UInt64(self.l[].n - self.head)

    def Clone(mut self) raises -> Ref[Self]:
        return Self.__clone(Ref[Self](rt_addr(self)))

    def Assign(mut self, o: Ref[Self]) raises:
        Self.__assign(Ref[Self](rt_addr(self)), o)


# ================================================================ disposal
def rt_dispose[T: Elem](x: T) raises:
    """a C++ destructor the engine relies on (Dtor.Run, the end of a using declaration): an engine class's Dispose,
    a container's elements, a file stream's close"""
    comptime if conforms_to(T, ElemOps):
        x.e_dispose()


def rt_array_fill[T: Elem](a: Ary[T], v: T) raises:
    for i in range(a.n):
        a.p[unsafe_offset=i] = v


struct File:
    @staticmethod
    def Exists(s: CStr) raises -> Bool:
        var b = gc_atomic_bytes(s.n + 1).unsafe_bitcast[Int8]()
        for i in range(s.n):
            b[unsafe_offset=i] = Int8(s.p[unsafe_offset=i])
        var st = gc_atomic_bytes(256)
        var r = external_call["stat", Int32](b, st)
        if r != 0:
            return False
        var mode = st.unsafe_bitcast[UInt32]()[unsafe_offset=6]
        return (mode & 0o170000) != 0o040000


# ================================================================ arrays, memory, moves
struct Arr:
    """the C# runtime's helpers for C arrays (T a[n], T a[n][m])"""
    @staticmethod
    def Make[T: Elem](n: Int32) raises -> Ary[T]:
        var a = Ary[T].make(Int(n))
        if elem_makes[T]():
            for i in range(Int(n)):
                a.p[unsafe_offset=i] = elem_make[T]()
        return a

    @staticmethod
    def Make2[T: Elem](n: Int32, m: Int32) raises -> Ary[Ary[T]]:
        var a = Ary[Ary[T]].make(Int(n))
        for i in range(Int(n)):
            a.p[unsafe_offset=i] = Arr.Make[T](m)
        return a

    @staticmethod
    def Clone[T: Elem](a: Ary[T]) raises -> Ary[T]:
        if a.isnull():
            return a
        var b = Ary[T].make(a.n)
        for i in range(a.n):
            b.p[unsafe_offset=i] = elem_copy(a.p[unsafe_offset=i]) if elem_is_class[T]() else a.p[unsafe_offset=i]
        return b

    @staticmethod
    def Assign[T: Elem](dst: Ary[T], src: Ary[T]) raises:
        for i in range(src.n):
            if elem_is_class[T]():
                elem_assign(dst.p[unsafe_offset=i], src.p[unsafe_offset=i])
            else:
                dst.p[unsafe_offset=i] = src.p[unsafe_offset=i]

    @staticmethod
    def Eq[T: Elem](x: Ary[T], y: Ary[T]) raises -> Bool:
        if x.n != y.n:
            return False
        for i in range(x.n):
            if not elem_eq(x.p[unsafe_offset=i], y.p[unsafe_offset=i]):
                return False
        return True


struct Bytes:
    @staticmethod
    def View[T: Elem](p: Ptr[T]) raises -> CPtr:
        return CPtr(p.p.unsafe_bitcast[Int8]())

    @staticmethod
    def View(p: CPtr) raises -> CPtr:
        return p


struct Mv:
    @staticmethod
    def Reset[T: Elem](p: P[T], q: T) raises:
        """unique_ptr::reset(q) and unique_ptr assignment: store the new pointer, then delete the old one"""
        var old = p[]
        p[] = q
        if not _is_null(old) and not elem_eq(old, q):
            rt_dispose(old)

    @staticmethod
    def Take[T: Elem](x: P[T]) raises -> T:
        """std::move of a container or class into a new owner: the source is left empty"""
        var r = x[]
        x[] = elem_make[T]()
        return r

    @staticmethod
    def TakeRef[T: Elem](x: P[T]) raises -> T:
        """std::move of a unique_ptr or std::function: the source is left null"""
        var r = x[]
        x[] = rt_zero[T]()
        return r

    @staticmethod
    def PostStep[T: Elem](p: P[Ptr[T]], d: Int32) raises -> Ptr[T]:
        var r = p[]
        p[] = r.add(Int(d))
        return r

    @staticmethod
    def PostStep[T: Elem](p: P[Iter[T]], d: Int32) raises -> Iter[T]:
        var r = p[]
        p[] = Iter[T](r.a, r.i + Int64(d))
        return r


def _is_null[T: Elem](x: T) -> Bool:
    # a copy on the runtime's stack, not the argument's address (see rt_box in core.mojo)
    var sp = rt_sp()
    var sx = rt_salloc[T]()
    sx[] = x
    var pa = P[UInt8](unsafe_from_address=Int(sx))
    var r = True
    for i in range(size_of[T]()):
        if pa[unsafe_offset=i] != 0:
            r = False
            break
    rt_set_sp(sp)
    return r


struct Less[T: Elem]:
    @staticmethod
    def s_Fn() -> Dlg:
        return Dlg(VP_null(), LESS_ID)


# ================================================================ <algorithm> and <numeric>
struct Algo:
    @staticmethod
    def fill[T: Elem](b: Iter[T], e: Iter[T], v: T) raises:
        for i in range(Int(b.i), Int(e.i)):
            b.a.p[unsafe_offset=i] = elem_copy(v)

    @staticmethod
    def fill[T: Elem](b: Ptr[T], e: Ptr[T], v: T) raises:
        for i in range(Int(e.diff(b))):
            b.p[unsafe_offset=i] = elem_copy(v)

    @staticmethod
    def fill_n[T: Elem](b: Ptr[T], n: UInt64, v: T) raises -> Ptr[T]:
        for i in range(Int(n)):
            b.p[unsafe_offset=i] = elem_copy(v)
        return b.add(Int(n))

    @staticmethod
    def any_of[T: Elem, call: def(Dlg, T) raises thin -> Bool](b: Iter[T], e: Iter[T], f: Dlg) raises -> Bool:
        for i in range(Int(b.i), Int(e.i)):
            if call(f, b.a.p[unsafe_offset=i]):
                return True
        return False

    @staticmethod
    def all_of[T: Elem, call: def(Dlg, T) raises thin -> Bool](b: Iter[T], e: Iter[T], f: Dlg) raises -> Bool:
        for i in range(Int(b.i), Int(e.i)):
            if not call(f, b.a.p[unsafe_offset=i]):
                return False
        return True

    @staticmethod
    def none_of[T: Elem, call: def(Dlg, T) raises thin -> Bool](b: Iter[T], e: Iter[T], f: Dlg) raises -> Bool:
        for i in range(Int(b.i), Int(e.i)):
            if call(f, b.a.p[unsafe_offset=i]):
                return False
        return True

    @staticmethod
    def find_if[T: Elem, call: def(Dlg, T) raises thin -> Bool](b: Iter[T], e: Iter[T], f: Dlg) raises -> Iter[T]:
        for i in range(Int(b.i), Int(e.i)):
            if call(f, b.a.p[unsafe_offset=i]):
                return Iter[T](b.a, Int64(i))
        return e

    @staticmethod
    def find[T: Elem](b: Iter[T], e: Iter[T], v: T) raises -> Iter[T]:
        for i in range(Int(b.i), Int(e.i)):
            if elem_eq(b.a.p[unsafe_offset=i], v):
                return Iter[T](b.a, Int64(i))
        return e

    @staticmethod
    def count[T: Elem](b: Iter[T], e: Iter[T], v: T) raises -> Int64:
        var c: Int64 = 0
        for i in range(Int(b.i), Int(e.i)):
            if elem_eq(b.a.p[unsafe_offset=i], v):
                c += 1
        return c

    @staticmethod
    def accumulate(b: Iter[Float64], e: Iter[Float64], init: Float64) raises -> Float64:
        var s = init
        for i in range(Int(b.i), Int(e.i)):
            s = s + b.a.p[unsafe_offset=i]
        return s

    @staticmethod
    def lower_bound[T: Elem](b: Iter[T], e: Iter[T], v: T) raises -> Iter[T]:
        var first = b.i
        var len = e.i - b.i
        while len > 0:
            var half = len >> 1
            var mid = first + half
            if elem_less(b.a.p[unsafe_offset=Int(mid)], v):
                first = mid + 1
                len = len - half - 1
            else:
                len = half
        return Iter[T](b.a, first)

    @staticmethod
    def lower_bound[T: Elem, V: Elem, call: def(Dlg, T, V) raises thin -> Bool](b: Iter[T], e: Iter[T], v: V, f: Dlg) raises -> Iter[T]:
        var first = b.i
        var len = e.i - b.i
        while len > 0:
            var half = len >> 1
            var mid = first + half
            if call(f, b.a.p[unsafe_offset=Int(mid)], v):
                first = mid + 1
                len = len - half - 1
            else:
                len = half
        return Iter[T](b.a, first)

    @staticmethod
    def upper_bound[T: Elem](b: Iter[T], e: Iter[T], v: T) raises -> Iter[T]:
        var first = b.i
        var len = e.i - b.i
        while len > 0:
            var half = len >> 1
            var mid = first + half
            if elem_less(v, b.a.p[unsafe_offset=Int(mid)]):
                len = half
            else:
                first = mid + 1
                len = len - half - 1
        return Iter[T](b.a, first)

    @staticmethod
    def is_sorted[T: Elem](b: Iter[T], e: Iter[T]) raises -> Bool:
        for i in range(Int(b.i) + 1, Int(e.i)):
            if elem_less(b.a.p[unsafe_offset=i], b.a.p[unsafe_offset=i - 1]):
                return False
        return True

    @staticmethod
    def unique[T: Elem](b: Iter[T], e: Iter[T]) raises -> Iter[T]:
        """std::unique: keeps the first of each run of equal elements (libstdc++'s order of moves)"""
        if b.i == e.i:
            return e
        var a = b.a.p
        var first = Int(b.i)
        var last = Int(e.i)
        var nxt = first
        while True:
            nxt += 1
            if nxt == last:
                break
            if elem_eq(a[unsafe_offset=first], a[unsafe_offset=nxt]):
                break
            first = nxt
        if nxt == last:
            return e
        var dest = first
        first = nxt
        while True:
            first += 1
            if first == last:
                break
            if not elem_eq(a[unsafe_offset=dest], a[unsafe_offset=first]):
                dest += 1
                a[unsafe_offset=dest] = a[unsafe_offset=first]
        return Iter[T](b.a, Int64(dest + 1))

    @staticmethod
    def max_element[T: Elem](b: Iter[T], e: Iter[T]) raises -> Iter[T]:
        if b.i == e.i:
            return e
        var best = Int(b.i)
        for i in range(Int(b.i) + 1, Int(e.i)):
            if elem_less(b.a.p[unsafe_offset=best], b.a.p[unsafe_offset=i]):
                best = i
        return Iter[T](b.a, Int64(best))

    @staticmethod
    def min_element[T: Elem](b: Iter[T], e: Iter[T]) raises -> Iter[T]:
        if b.i == e.i:
            return e
        var best = Int(b.i)
        for i in range(Int(b.i) + 1, Int(e.i)):
            if elem_less(b.a.p[unsafe_offset=i], b.a.p[unsafe_offset=best]):
                best = i
        return Iter[T](b.a, Int64(best))

    @staticmethod
    def copy_[T: Elem](b: Iter[T], e: Iter[T], o: Iter[T]) raises -> Iter[T]:
        for i in range(Int(b.i), Int(e.i)):
            o.a.p[unsafe_offset=Int(o.i) + (i - Int(b.i))] = elem_copy(b.a.p[unsafe_offset=i])
        return Iter[T](o.a, o.i + (e.i - b.i))

    @staticmethod
    def copy_n[T: Elem](b: Ptr[T], n: UInt64, o: Ptr[T]) raises -> Ptr[T]:
        for i in range(Int(n)):
            o.p[unsafe_offset=i] = elem_copy(b.p[unsafe_offset=i])
        return o.add(Int(n))

    @staticmethod
    def transform[T: Elem, U: Elem, call: def(Dlg, T) raises thin -> U](b: Iter[T], e: Iter[T], o: Iter[U], f: Dlg) raises -> Iter[U]:
        for i in range(Int(b.i), Int(e.i)):
            o.a.p[unsafe_offset=Int(o.i) + (i - Int(b.i))] = call(f, b.a.p[unsafe_offset=i])
        return Iter[U](o.a, o.i + (e.i - b.i))

    @staticmethod
    def transform[call: def(Dlg, UInt8) raises thin -> Int8](b: Iter[UInt8], e: Iter[UInt8], o: Iter[UInt8], f: Dlg) raises -> Iter[UInt8]:
        for i in range(Int(b.i), Int(e.i)):
            o.a.p[unsafe_offset=Int(o.i) + (i - Int(b.i))] = call(f, b.a.p[unsafe_offset=i]).cast[DType.uint8]()
        return Iter[UInt8](o.a, o.i + (e.i - b.i))

    @staticmethod
    def replace[T: Elem](b: Iter[T], e: Iter[T], old: T, nw: T) raises:
        for i in range(Int(b.i), Int(e.i)):
            if elem_eq(b.a.p[unsafe_offset=i], old):
                b.a.p[unsafe_offset=i] = nw

    @staticmethod
    def iota(b: Iter[UInt64], e: Iter[UInt64], v0: UInt64) raises:
        var v = v0
        for i in range(Int(b.i), Int(e.i)):
            b.a.p[unsafe_offset=i] = v
            v += 1

    @staticmethod
    def iota(b: Iter[Int32], e: Iter[Int32], v0: Int32) raises:
        var v = v0
        for i in range(Int(b.i), Int(e.i)):
            b.a.p[unsafe_offset=i] = v
            v += 1

    @staticmethod
    def VecFrom[T: Elem](b: Iter[T], e: Iter[T]) raises -> Ref[Vec[T]]:
        var v = Vec[T].new_()
        var n = Int(e.i - b.i)
        v[].a = Ary[T].make(n)
        v[].n = Int32(n)
        for k in range(n):
            v[].a.p[unsafe_offset=k] = elem_copy(b.a.p[unsafe_offset=Int(b.i) + k])
        return v

    @staticmethod
    def begin[T: Elem](a: Ary[T]) raises -> Iter[T]:
        return Iter[T](a, 0)

    @staticmethod
    def end[T: Elem](a: Ary[T]) raises -> Iter[T]:
        return Iter[T](a, Int64(a.n))


struct StdAlgo:
    """libstdc++'s std::sort (introsort with the median-of-three pivot and the final insertion sort: the same
    comparisons and the same swaps) and std::stable_sort, after StdAlgo.cs; tests/stdcheck holds them to libstdc++"""
    @staticmethod
    def Sort[T: Elem, call: def(Dlg, T, T) raises thin -> Bool](arr: Ary[T], first: Int64, last: Int64, comp: Dlg) raises:
        if first == last:
            return
        var s = Sorter[T, call](arr.p, comp)
        s.introsort_loop(Int(first), Int(last), _lg(Int(last - first)) * 2)
        s.final_insertion_sort(Int(first), Int(last))

    @staticmethod
    def PartialSort[T: Elem, call: def(Dlg, T, T) raises thin -> Bool](arr: Ary[T], first: Int64, middle: Int64, last: Int64, comp: Dlg) raises:
        var s = Sorter[T, call](arr.p, comp)
        s.partial_sort(Int(first), Int(middle), Int(last))

    @staticmethod
    def StableSort[T: Elem, call: def(Dlg, T, T) raises thin -> Bool](arr: Ary[T], first: Int64, last: Int64, comp: Dlg) raises:
        var n = Int(last - first)
        if n < 2:
            return
        var s = Sorter[T, call](arr.p, comp)
        var buf = gc_array[T](n)
        s.merge_sort(Int(first), Int(last), buf)


def _lg(n: Int) -> Int:
    var r = 0
    var x = n
    while x > 1:
        x >>= 1
        r += 1
    return r


struct Sorter[T: Elem, call: def(Dlg, T, T) raises thin -> Bool](Movable):
    var a: P[Self.T]
    var f: Dlg

    def __init__(out self, a: P[Self.T], f: Dlg):
        self.a = a
        self.f = f

    @always_inline
    def lt(self, x: Self.T, y: Self.T) raises -> Bool:
        if self.f.id == LESS_ID:
            return elem_less(x, y)
        return Self.call(self.f, x, y)

    @always_inline
    def get(self, i: Int) -> Self.T:
        return self.a[unsafe_offset=i]

    @always_inline
    def put(self, i: Int, v: Self.T):
        self.a[unsafe_offset=i] = v

    def swap(self, i: Int, j: Int):
        var t = self.get(i)
        self.put(i, self.get(j))
        self.put(j, t)

    def introsort_loop(self, first: Int, last0: Int, depth0: Int) raises:
        var last = last0
        var depth = depth0
        while last - first > 16:
            if depth == 0:
                self.partial_sort(first, last, last)
                return
            depth -= 1
            var cut = self.unguarded_partition_pivot(first, last)
            self.introsort_loop(cut, last, depth)
            last = cut

    def unguarded_partition_pivot(self, first: Int, last: Int) raises -> Int:
        var mid = first + (last - first) // 2
        self.move_median_to_first(first, first + 1, mid, last - 1)
        return self.unguarded_partition(first + 1, last, first)

    def move_median_to_first(self, result: Int, a: Int, b: Int, c: Int) raises:
        if self.lt(self.get(a), self.get(b)):
            if self.lt(self.get(b), self.get(c)):
                self.swap(result, b)
            elif self.lt(self.get(a), self.get(c)):
                self.swap(result, c)
            else:
                self.swap(result, a)
        elif self.lt(self.get(a), self.get(c)):
            self.swap(result, a)
        elif self.lt(self.get(b), self.get(c)):
            self.swap(result, c)
        else:
            self.swap(result, b)

    def unguarded_partition(self, first0: Int, last0: Int, pivot: Int) raises -> Int:
        var first = first0
        var last = last0
        while True:
            while self.lt(self.get(first), self.get(pivot)):
                first += 1
            last -= 1
            while self.lt(self.get(pivot), self.get(last)):
                last -= 1
            if not (first < last):
                return first
            self.swap(first, last)
            first += 1

    def final_insertion_sort(self, first: Int, last: Int) raises:
        if last - first > 16:
            self.insertion_sort(first, first + 16)
            var i = first + 16
            while i != last:
                self.unguarded_linear_insert(i)
                i += 1
        else:
            self.insertion_sort(first, last)

    def insertion_sort(self, first: Int, last: Int) raises:
        if first == last:
            return
        var i = first + 1
        while i != last:
            if self.lt(self.get(i), self.get(first)):
                var val = self.get(i)
                var k = i
                while k > first:
                    self.put(k, self.get(k - 1))
                    k -= 1
                self.put(first, val)
            else:
                self.unguarded_linear_insert(i)
            i += 1

    def unguarded_linear_insert(self, last0: Int) raises:
        var last = last0
        var val = self.get(last)
        var next = last - 1
        while self.lt(val, self.get(next)):
            self.put(last, self.get(next))
            last = next
            next -= 1
        self.put(last, val)

    def partial_sort(self, first: Int, middle: Int, last: Int) raises:
        self.make_heap(first, middle)
        var i = middle
        while i < last:
            if self.lt(self.get(i), self.get(first)):
                self.pop_heap(first, middle, i)
            i += 1
        var l = middle
        while l - first > 1:
            l -= 1
            self.pop_heap(first, l, l)

    def make_heap(self, first: Int, last: Int) raises:
        if last - first < 2:
            return
        var len = last - first
        var parent = (len - 2) // 2
        while True:
            var value = self.get(first + parent)
            self.adjust_heap(first, parent, len, value)
            if parent == 0:
                return
            parent -= 1

    def pop_heap(self, first: Int, last: Int, result: Int) raises:
        var value = self.get(result)
        self.put(result, self.get(first))
        self.adjust_heap(first, 0, last - first, value)

    def adjust_heap(self, first: Int, hole0: Int, len: Int, value: Self.T) raises:
        var hole = hole0
        var top = hole
        var second = hole
        while second < (len - 1) // 2:
            second = 2 * (second + 1)
            if self.lt(self.get(first + second), self.get(first + (second - 1))):
                second -= 1
            self.put(first + hole, self.get(first + second))
            hole = second
        if (len & 1) == 0 and second == (len - 2) // 2:
            second = 2 * (second + 1)
            self.put(first + hole, self.get(first + (second - 1)))
            hole = second - 1
        var parent = (hole - 1) // 2
        while hole > top and self.lt(self.get(first + parent), value):
            self.put(first + hole, self.get(first + parent))
            hole = parent
            parent = (hole - 1) // 2
        self.put(first + hole, value)

    def merge_sort(self, lo: Int, hi: Int, buf: P[Self.T]) raises:
        if hi - lo < 2:
            return
        var mid = lo + (hi - lo) // 2
        self.merge_sort(lo, mid, buf)
        self.merge_sort(mid, hi, buf)
        var i = lo
        var j = mid
        var k = 0
        while i < mid and j < hi:
            if self.lt(self.get(j), self.get(i)):
                buf[unsafe_offset=k] = self.get(j)
                j += 1
            else:
                buf[unsafe_offset=k] = self.get(i)
                i += 1
            k += 1
        while i < mid:
            buf[unsafe_offset=k] = self.get(i)
            i += 1
            k += 1
        while j < hi:
            buf[unsafe_offset=k] = self.get(j)
            j += 1
            k += 1
        for q in range(k):
            self.put(lo + q, buf[unsafe_offset=q])
