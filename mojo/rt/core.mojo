# core.mojo - the base of the Mojo runtime of the SWMM6 port: pointers, object references, the collector, arrays,
# delegates, the runtime's state, the engine's own stack for locals whose address is taken, exceptions, C#'s
# conversions and integer operators, the element protocol the containers use, and the math library (glibc's own).
#
# Mojo 1.2 has no global variables: the runtime's state (RTS) and the engine's static fields (GS) live in two blocks
# mapped at fixed addresses at start-up, so every function reaches them without a parameter. Memory comes from the
# Boehm collector (libgc.so.1), zero-filled; nothing is freed by hand.
# Written by Claude (Anthropic) for the SWMM6 ports; see ../README.md and ../../AI-USE.md.

from std.ffi import external_call
from std.sys import size_of, argv
from std.memory import bitcast

comptime P = Pointer[_, MutUntrackedOrigin]
comptime VP = Pointer[NoneType, MutUntrackedOrigin]
comptime Elem = ImplicitlyCopyable & Deinitable

comptime RTS_ADDR = 0x6f0000000000
comptime GS_ADDR = 0x6f0100000000
comptime STACK_BYTES = 8 * 1024 * 1024
comptime GS_MAX = 16 * 1024 * 1024        # address space reserved for the static fields (they need about 8 KB)


# ================================================================ pointers
@always_inline
def rt_null[T: AnyType]() -> P[T]:
    return P[T](unsafe_from_address=Int(0))


@always_inline
def VP_null() -> VP:
    return VP(unsafe_from_address=Int(0))


@always_inline
def rt_addr[T: AnyType](ref x: T) -> P[T]:
    """the address of x as an untracked pointer (x lives in collected memory, a fixed block or the runtime stack)"""
    return P[T](unsafe_from_address=Int(Pointer(to=x)))


@always_inline
def pnull[T: AnyType](p: P[T]) -> Bool:
    return Int(p) == 0


@always_inline
def padd[T: AnyType](p: P[T], k: Int) -> P[T]:
    return P[T](unsafe_from_address=Int(p) + k * size_of[T]())


@always_inline
def pcast[U: AnyType, T: AnyType](p: P[T]) -> P[U]:
    return P[U](unsafe_from_address=Int(p))


# ================================================================ the collector
@always_inline
def gc_bytes(n: Int) -> VP:
    var p = external_call["GC_malloc", VP](n if n > 0 else 1)
    if Int(p) == 0:
        rt_die("out of memory (" + String(n) + " bytes)")
    return p


@always_inline
def gc_atomic_bytes(n: Int) -> VP:
    """memory the collector does not scan (numbers only), zeroed here: GC_malloc_atomic does not clear it"""
    var m = n if n > 0 else 1
    var p = external_call["GC_malloc_atomic", VP](m)
    if Int(p) == 0:
        rt_die("out of memory (" + String(m) + " bytes)")
    _ = external_call["memset", VP](p, Int32(0), m)
    return p


@always_inline
def gc_new[T: AnyType]() -> P[T]:
    return gc_bytes(size_of[T]()).unsafe_bitcast[T]()


def gc_array[T: AnyType](n: Int) -> P[T]:
    comptime if is_number[T]():
        return gc_atomic_bytes(n * size_of[T]()).unsafe_bitcast[T]()
    return gc_bytes(n * size_of[T]()).unsafe_bitcast[T]()


@always_inline
def is_number[T: AnyType]() -> Bool:
    return (T == Float64 or T == Float32 or T == Int32 or T == Int64 or T == UInt64 or T == UInt32 or T == Int8 or
            T == UInt8 or T == Int16 or T == UInt16 or T == Bool)


def rt_die(msg: String):
    var b = msg.as_bytes()
    _ = external_call["write", Int](Int32(2), VP(unsafe_from_address=Int(b.unsafe_ptr())), len(b))
    _ = external_call["write", Int](Int32(2), VP(unsafe_from_address=Int("\n".unsafe_ptr())), 1)
    external_call["exit", NoneType](Int32(3))


def rt_die(msg: StaticString):
    _ = external_call["write", Int](Int32(2), VP(unsafe_from_address=Int(msg.unsafe_ptr())), msg.byte_length())
    _ = external_call["write", Int](Int32(2), VP(unsafe_from_address=Int("\n".unsafe_ptr())), 1)
    external_call["exit", NoneType](Int32(3))


# ================================================================ the runtime's state, at a fixed address
struct RTS(Movable):
    var exc: Ref[CppException]
    var sp: Int
    var stack: Int
    var stack_end: Int
    var stdout_: VP
    var stderr_: VP
    var strtok_pos: Int
    var stdin_: VP
    var primes: Int
    var open_files: Int


@always_inline
def rts() -> P[RTS]:
    return P[RTS](unsafe_from_address=RTS_ADDR)


def _map_fixed(addr: Int, n: Int):
    # MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE | MAP_NORESERVE
    var r = external_call["mmap", Int](addr, n, Int32(3), Int32(0x104022), Int32(-1), Int(0))
    if r != addr:
        _reexec()


def _reexec():
    """the fixed address is taken: Mojo's own runtime reserves 1 GB regions at random addresses before main runs,
    and once in the 932 starts of the first two gate runs one of them covered RTS_ADDR or GS_ADDR (lessons/79). Nothing has been read or
    written yet, so the program starts again (execv of /proc/self/exe with the same arguments), with new random
    regions; OPENSWMM_MOJO_REMAP counts the attempts, at most 8."""
    var name = StaticString("OPENSWMM_MOJO_REMAP")
    # the same declaration as R.getenv's (Mojo rejects two signatures for one C function)
    var e = external_call["getenv", P[Int8]](P[Int8](unsafe_from_address=Int(name.unsafe_ptr())))
    var k = 0
    if Int(e) != 0:
        k = Int(e[]) - 48
    if k >= 8:
        rt_die("cannot map the runtime's state block")
    var digits = StaticString("0123456789")
    var v = gc_atomic_bytes(2).unsafe_bitcast[UInt8]()
    v[] = digits.unsafe_ptr()[k + 1]
    _ = external_call["setenv", Int32](Int(name.unsafe_ptr()), Int(v), Int32(1))
    var args = argv()
    var n = len(args)
    var arr = gc_bytes(8 * (n + 1)).unsafe_bitcast[Int]()
    for i in range(n):
        P[Int](unsafe_from_address=Int(arr) + 8 * i)[] = Int(args[i].unsafe_ptr())
    P[Int](unsafe_from_address=Int(arr) + 8 * n)[] = 0
    var exe = StaticString("/proc/self/exe")
    _ = external_call["execv", Int32](Int(exe.unsafe_ptr()), Int(arr))
    rt_die("cannot map the runtime's state block")


def rt_init():
    external_call["GC_init", NoneType]()
    _ = external_call["GC_expand_hp", Int32](Int(64 * 1024 * 1024))
    _map_fixed(RTS_ADDR, 1 << 20)
    _ = external_call["GC_add_roots", NoneType](VP(unsafe_from_address=RTS_ADDR), VP(unsafe_from_address=RTS_ADDR + (1 << 20)))
    # the static fields' block is reserved here too, before anything is read or written (see _reexec); the engine's
    # static initializer registers the part it uses with the collector (rt_map_statics)
    _map_fixed(GS_ADDR, GS_MAX)
    # the engine's own stack: locals whose address is taken (MOJO.md; lessons/74)
    var st = external_call["mmap", Int](Int(0), STACK_BYTES, Int32(3), Int32(0x22), Int32(-1), Int(0))
    _ = external_call["GC_add_roots", NoneType](VP(unsafe_from_address=st), VP(unsafe_from_address=st + STACK_BYTES))
    rts()[].stack = st
    rts()[].sp = st
    rts()[].stack_end = st + STACK_BYTES


def rt_map_statics(n: Int):
    if n > GS_MAX:
        rt_die("the static fields need more than GS_MAX bytes")
    var m = ((n + 4095) // 4096) * 4096
    _ = external_call["GC_add_roots", NoneType](VP(unsafe_from_address=GS_ADDR), VP(unsafe_from_address=GS_ADDR + m))


# ---------------------------------------------------------------- the engine's own stack
@always_inline
def rt_sp() -> Int:
    return rts()[].sp


@always_inline
def rt_set_sp(sp: Int):
    rts()[].sp = sp


@always_inline
def rt_salloc[T: AnyType]() -> P[T]:
    """a zeroed slot for one local whose address is taken; the function gives it back at its returns"""
    var r = rts()
    var p = r[].sp
    var n = ((size_of[T]() + 15) // 16) * 16
    if p + n > r[].stack_end:
        rt_die("the engine's stack is full")
    r[].sp = p + n
    _ = external_call["memset", VP](VP(unsafe_from_address=p), Int32(0), n)
    return P[T](unsafe_from_address=p)


@always_inline
def rt_cell[T: Elem](v: T) -> P[T]:
    """a collected cell for a local captured by a lambda"""
    var c = gc_new[T]()
    c[] = v
    return c


@always_inline
def rt_zero[T: Elem]() -> T:
    """the all-zero value of T (C#'s default): read from a zeroed block"""
    return P[T](unsafe_from_address=RTS_ADDR + 0x40000)[]


# ================================================================ object references
trait EStruct:
    """an engine or runtime class: how containers make, copy, assign, move, compare, hash and destroy it"""
    comptime IS_CLASS: Bool = False
    comptime LIB: Bool = False

    @staticmethod
    def __new() raises -> Ref[Self]:
        return Ref[Self]()

    @staticmethod
    def __clone(x: Ref[Self]) raises -> Ref[Self]:
        return x

    @staticmethod
    def __assign(d: Ref[Self], x: Ref[Self]) raises:
        raise rt_todo_err("assign of a class without Assign")

    @staticmethod
    def __moveFrom(d: Ref[Self], x: Ref[Self]) raises:
        raise rt_todo_err("move of a class without MoveFrom")

    @staticmethod
    def __dispose(x: Ref[Self]) raises:
        pass

    @staticmethod
    def __less(a: Ref[Self], b: Ref[Self]) raises -> Bool:
        return Int(a.p) < Int(b.p)

    @staticmethod
    def __eqv(a: Ref[Self], b: Ref[Self]) raises -> Bool:
        return Int(a.p) == Int(b.p)

    @staticmethod
    def __hashv(a: Ref[Self]) raises -> UInt64:
        return UInt64(Int(a.p))



trait ElemOps(Elem):
    """a value the containers copy with more than a bit copy, or compare and hash in their own way"""
    comptime NEEDS_COPY: Bool
    comptime IS_CLASS: Bool = False
    comptime MAKES: Bool = False
    comptime LIB_VALUE: Bool = False
    comptime IS_REF: Bool = False

    def e_word(self) -> Int:
        """an IS_REF value as the address it holds (rt_box)"""
        return 0

    @staticmethod
    def e_of_word(a: Int) -> Self:
        """the IS_REF value holding address a (rt_unbox)"""
        return rt_zero[Self]()

    @staticmethod
    def e_make_n(n: Int, n2: Int) raises -> Self:
        return Self.e_make()

    def e_dispose(self) raises:
        pass

    @staticmethod
    def e_make() raises -> Self:
        ...

    def e_assign(self, s: Self) raises:
        raise rt_todo_err("assign of a value")

    def e_copy(self) raises -> Self:
        ...

    def e_eq(self, o: Self) raises -> Bool:
        ...

    def e_less(self, o: Self) raises -> Bool:
        ...

    def e_hash(self) raises -> UInt64:
        ...


struct Ref[T: EStruct](ImplicitlyCopyable, Equatable, ElemOps):
    """a C# reference to an object of class T: a pointer, null at address 0"""
    var p: P[Self.T]
    comptime NEEDS_COPY = Self.T.IS_CLASS
    comptime IS_CLASS = Self.T.IS_CLASS
    comptime MAKES = True
    comptime LIB_VALUE = Self.T.IS_CLASS and Self.T.LIB
    comptime IS_REF = True

    def e_dispose(self) raises:
        if not self.isnull():
            Self.T.__dispose(self)

    @always_inline
    def __init__(out self):
        self.p = P[Self.T](unsafe_from_address=Int(0))

    @always_inline
    def __init__(out self, p: P[Self.T]):
        self.p = p

    @always_inline
    def e_word(self) -> Int:
        return Int(self.p)

    @always_inline
    @staticmethod
    def e_of_word(a: Int) -> Self:
        return Self(P[Self.T](unsafe_from_address=a))

    @always_inline
    def __getitem__(self) -> ref[MutUntrackedOrigin] Self.T:
        return self.p[]

    @always_inline
    def __eq__(self, o: Self) -> Bool:
        return Int(self.p) == Int(o.p)

    @always_inline
    def __ne__(self, o: Self) -> Bool:
        return Int(self.p) != Int(o.p)

    @always_inline
    def isnull(self) -> Bool:
        return Int(self.p) == 0

    @always_inline
    def cast[U: EStruct](self) -> Ref[U]:
        return Ref[U](P[U](unsafe_from_address=Int(self.p)))

    @always_inline
    def vp(self) -> VP:
        return VP(unsafe_from_address=Int(self.p))

    @staticmethod
    def e_make() raises -> Self:
        return Self.T.__new()

    def e_copy(self) raises -> Self:
        comptime if Self.T.IS_CLASS:
            if self.isnull():
                return self
            return Self.T.__clone(self)
        return self

    def e_assign(self, s: Self) raises:
        Self.T.__assign(self, s)

    def e_eq(self, o: Self) raises -> Bool:
        if self.isnull() or o.isnull():
            return self.isnull() and o.isnull()
        return Self.T.__eqv(self, o)

    def e_less(self, o: Self) raises -> Bool:
        return Self.T.__less(self, o)

    def e_hash(self) raises -> UInt64:
        return Self.T.__hashv(self)


# ================================================================ C# arrays
struct Ary[T: Elem](ImplicitlyCopyable, ElemOps):
    """a C# array T[]: storage and length (null when p is 0); copying the struct copies the reference"""
    var p: P[Self.T]
    var n: Int
    comptime NEEDS_COPY = True

    @always_inline
    def __init__(out self):
        self.p = P[Self.T](unsafe_from_address=Int(0))
        self.n = 0

    @always_inline
    def __init__(out self, p: P[Self.T], n: Int):
        self.p = p
        self.n = n

    @staticmethod
    def make(n: Int) raises -> Self:
        """new T[n]: zero elements"""
        return Self(gc_array[Self.T](n), n)

    @staticmethod
    def of(*vals: Self.T) raises -> Self:
        var a = Self.make(len(vals))
        for i in range(len(vals)):
            a.p[unsafe_offset=i] = vals[i]
        return a

    @always_inline
    def __getitem__(self, i: Int) -> ref[MutUntrackedOrigin] Self.T:
        comptime if CHECKED:
            if i < 0 or i >= self.n:
                rt_die("array index out of range")
        return self.p[unsafe_offset=i]

    @always_inline
    def ptr(self, i: Int) -> P[Self.T]:
        return padd(self.p, i)

    @always_inline
    def isnull(self) -> Bool:
        return Int(self.p) == 0

    @always_inline
    def __eq__(self, o: Self) -> Bool:
        return Int(self.p) == Int(o.p)

    @staticmethod
    def e_make() raises -> Self:
        return Self()

    @staticmethod
    def e_make_n(n: Int, n2: Int) raises -> Self:
        """a C array element of a container (Vec(() => Arr.Make<T>(n))): n elements, each made"""
        var a = Self.make(n)
        for i in range(n):
            a.p[unsafe_offset=i] = _elem_make_n[Self.T](n2) if n2 > 0 else _elem_make_cls[Self.T]()
        return a

    def e_copy(self) raises -> Self:
        """a C array member copied with its object: every element (ArrCopy.Deep)"""
        if self.isnull():
            return self
        var b = Self.make(self.n)
        for i in range(self.n):
            b.p[unsafe_offset=i] = elem_copy(self.p[unsafe_offset=i])
        return b

    def e_eq(self, o: Self) raises -> Bool:
        return Int(self.p) == Int(o.p) and self.n == o.n

    def e_less(self, o: Self) raises -> Bool:
        return Int(self.p) < Int(o.p)

    def e_hash(self) raises -> UInt64:
        return UInt64(Int(self.p))


comptime CHECKED = False


# ================================================================ delegates
struct Dlg(ImplicitlyCopyable, ElemOps):
    """a C# delegate: a context and the number of its function, dispatched per signature by the engine (Mojo 1.2
    cannot keep a function in a struct field); id 0 is null"""
    var ctx: VP
    var id: Int
    comptime NEEDS_COPY = False

    @always_inline
    def __init__(out self):
        self.ctx = VP_null()
        self.id = 0

    @always_inline
    def __init__(out self, ctx: VP, id: Int):
        self.ctx = ctx
        self.id = id

    @staticmethod
    def e_make() raises -> Self:
        return Self()

    def e_copy(self) raises -> Self:
        return self

    def e_eq(self, o: Self) raises -> Bool:
        return self.id == o.id and Int(self.ctx) == Int(o.ctx)

    def e_less(self, o: Self) raises -> Bool:
        return self.id < o.id

    def e_hash(self) raises -> UInt64:
        return UInt64(self.id)


comptime LESS_ID = -1
"""the id of the runtime's Less<T>.Fn: the runtime compares with elem_less instead of calling the engine"""


# ================================================================ object (boxing)
struct Obj(ImplicitlyCopyable, ElemOps):
    """a C# object: an address (a reference, or a box holding a value)"""
    var a: Int
    comptime NEEDS_COPY = False
    comptime IS_REF = True

    @always_inline
    def __ne__(self, o: Self) -> Bool:
        return self.a != o.a

    @always_inline
    def __init__(out self):
        self.a = 0

    @always_inline
    def __init__(out self, a: Int):
        self.a = a

    @always_inline
    def isnull(self) -> Bool:
        return self.a == 0

    @always_inline
    def e_word(self) -> Int:
        return self.a

    @always_inline
    @staticmethod
    def e_of_word(a: Int) -> Self:
        return Self(a)

    @always_inline
    def __eq__(self, o: Self) -> Bool:
        return self.a == o.a

    @staticmethod
    def e_make() raises -> Self:
        return Self()

    def e_copy(self) raises -> Self:
        return self

    def e_eq(self, o: Self) raises -> Bool:
        return self.a == o.a

    def e_less(self, o: Self) raises -> Bool:
        return self.a < o.a

    def e_hash(self) raises -> UInt64:
        return UInt64(self.a)


def rt_box[T: Elem](x: T) -> Obj:
    """a value as a C# object: a reference is its address (identity), anything else a copy in a collected box"""
    comptime if conforms_to(T, ElemOps):
        comptime if T.IS_REF:
            # not by reading x's bytes through its address: an argument's address is a stack slot LLVM may never
            # have written (the engine handle came back undefined and the whole open() became unreachable)
            return Obj(x.e_word())
    var c = gc_new[T]()
    c[] = x
    return Obj(Int(c))


def rt_unbox[T: Elem](o: Obj) -> T:
    comptime if conforms_to(T, ElemOps):
        comptime if T.IS_REF:
            return T.e_of_word(o.a)
    return P[T](unsafe_from_address=o.a)[]


# ================================================================ C strings
struct CStr(ImplicitlyCopyable, ElemOps):
    """a C# string (only literals and messages): bytes and a length, with a NUL after them"""
    var p: P[UInt8]
    var n: Int
    comptime NEEDS_COPY = False

    @always_inline
    def __init__(out self):
        self.p = rt_null[UInt8]()
        self.n = 0

    @always_inline
    def __init__(out self, s: StaticString):
        self.p = P[UInt8](unsafe_from_address=Int(s.unsafe_ptr()))
        self.n = s.byte_length()

    @always_inline
    def __init__(out self, p: P[UInt8], n: Int):
        self.p = p
        self.n = n

    @always_inline
    def isnull(self) -> Bool:
        return Int(self.p) == 0

    @staticmethod
    def e_make() raises -> Self:
        return Self()

    def e_copy(self) raises -> Self:
        return self

    def e_eq(self, o: Self) raises -> Bool:
        return rt_str_eq(self, o)

    def e_less(self, o: Self) raises -> Bool:
        return Int(self.p) < Int(o.p)

    def e_hash(self) raises -> UInt64:
        return UInt64(Int(self.p))


def rt_str_eq(a: CStr, b: CStr) -> Bool:
    if a.n != b.n:
        return False
    for i in range(a.n):
        if a.p[unsafe_offset=i] != b.p[unsafe_offset=i]:
            return False
    return True


def rt_hex(h: StaticString) -> CStr:
    """a string with bytes above 127, written as hexadecimal by the translator (Mojo writes "\\xb3" as UTF-8)"""
    var n = h.byte_length() // 2
    var p = gc_atomic_bytes(n + 1).unsafe_bitcast[UInt8]()
    var s = h.unsafe_ptr()
    for i in range(n):
        p[unsafe_offset=i] = UInt8(_hexdig(Int(s[2 * i])) * 16 + _hexdig(Int(s[2 * i + 1])))
    return CStr(p, n)


@always_inline
def _hexdig(c: Int) -> Int:
    return c - 48 if c <= 57 else c - 87


# ================================================================ char* and T*
struct CPtr(ImplicitlyCopyable, ElemOps):
    """a C char*: a byte pointer (null at 0)"""
    var p: P[Int8]
    comptime NEEDS_COPY = False

    @always_inline
    def __init__(out self):
        self.p = rt_null[Int8]()

    @always_inline
    def __init__(out self, p: P[Int8]):
        self.p = p

    @always_inline
    def __init__[T: Elem](out self, q: Ptr[T]):
        self.p = P[Int8](unsafe_from_address=Int(q.p))

    @always_inline
    def __getitem__(self, i: Int) -> ref[MutUntrackedOrigin] Int8:
        return self.p[unsafe_offset=i]

    @always_inline
    def get(self, i: Int) -> Int32:
        """C#'s CPtr indexer: the byte as a signed char"""
        return Int32(self.p[unsafe_offset=i])

    @always_inline
    def set(self, i: Int, v: Int32):
        self.p[unsafe_offset=i] = v.cast[DType.int8]()

    @always_inline
    def set_v(self, i: Int, v: Int32) -> Int32:
        self.p[unsafe_offset=i] = v.cast[DType.int8]()
        return v

    @always_inline
    def isnull(self) -> Bool:
        return Int(self.p) == 0

    @always_inline
    def add(self, k: Int) -> Self:
        return Self(padd(self.p, k))

    @always_inline
    def diff(self, o: Self) -> Int64:
        return Int64(Int(self.p) - Int(o.p))

    @always_inline
    def addr(self) -> Int:
        return Int(self.p)

    @always_inline
    def __eq__(self, o: Self) -> Bool:
        return Int(self.p) == Int(o.p)

    @always_inline
    def __ne__(self, o: Self) -> Bool:
        return Int(self.p) != Int(o.p)

    @always_inline
    def u8(self) -> P[UInt8]:
        return P[UInt8](unsafe_from_address=Int(self.p))

    @staticmethod
    def e_make() raises -> Self:
        return Self()

    def e_copy(self) raises -> Self:
        return self

    def e_eq(self, o: Self) raises -> Bool:
        return Int(self.p) == Int(o.p)

    def e_less(self, o: Self) raises -> Bool:
        return Int(self.p) < Int(o.p)

    def e_hash(self) raises -> UInt64:
        return UInt64(Int(self.p))

    @staticmethod
    def Diff(a: CPtr, b: CPtr) raises -> Int64:
        return Int64(Int(a.p) - Int(b.p))


struct Ptr[T: Elem](ImplicitlyCopyable, ElemOps):
    """a C pointer T*"""
    var p: P[Self.T]
    comptime NEEDS_COPY = False

    @always_inline
    def __init__(out self):
        self.p = rt_null[Self.T]()

    @always_inline
    def __init__(out self, p: P[Self.T]):
        self.p = p

    @always_inline
    def __init__(out self, a: Ary[Self.T], i: Int):
        self.p = padd(a.p, i)

    @always_inline
    def __getitem__(self, i: Int) -> ref[MutUntrackedOrigin] Self.T:
        return self.p[unsafe_offset=i]

    @always_inline
    def isnull(self) -> Bool:
        return Int(self.p) == 0

    @always_inline
    def add(self, k: Int) -> Self:
        return Self(padd(self.p, k))

    @always_inline
    def diff(self, o: Self) -> Int64:
        return Int64((Int(self.p) - Int(o.p)) // size_of[Self.T]())

    @always_inline
    def addr(self) -> Int:
        return Int(self.p)

    @always_inline
    def __eq__(self, o: Self) -> Bool:
        return Int(self.p) == Int(o.p)

    @always_inline
    def __ne__(self, o: Self) -> Bool:
        return Int(self.p) != Int(o.p)

    @staticmethod
    def e_make() raises -> Self:
        return Self()

    def e_copy(self) raises -> Self:
        return self

    def e_eq(self, o: Self) raises -> Bool:
        return Int(self.p) == Int(o.p)

    def e_less(self, o: Self) raises -> Bool:
        return Int(self.p) < Int(o.p)

    def e_hash(self) raises -> UInt64:
        return UInt64(Int(self.p))


def rt_lit(s: StaticString) -> CPtr:
    """a C string literal: the compiler stores the text with a NUL after it"""
    return CPtr(P[Int8](unsafe_from_address=Int(s.unsafe_ptr())))


def rt_lit(s: CStr) -> CPtr:
    return CPtr(P[Int8](unsafe_from_address=Int(s.p)))


def rt_litn(s: StaticString, n: Int) -> CPtr:
    """char buf[n] = "...": a writable copy of n bytes"""
    var p = gc_atomic_bytes(n + 1).unsafe_bitcast[Int8]()
    var src = s.unsafe_ptr()
    for i in range(min(n, s.byte_length())):
        p[unsafe_offset=i] = Int8(src[i])
    return CPtr(p)


def rt_litn(s: CStr, n: Int) -> CPtr:
    var p = gc_atomic_bytes(n + 1).unsafe_bitcast[Int8]()
    for i in range(min(n, s.n)):
        p[unsafe_offset=i] = Int8(s.p[unsafe_offset=i])
    return CPtr(p)


# ================================================================ expressions with side effects
@always_inline
def rt_asg[T: Elem](p: P[T], v: T) -> T:
    """C#'s (x = v) used as a value"""
    p[] = v
    return v


@always_inline
def rt_back[T: Elem, U: Elem](v: T, x: P[U], box: Ary[U]) -> T:
    """Mv.Back(v, ref x, box): v, after x takes the value the call left in box[0] (a boxed out-parameter)"""
    x[] = box.p[]
    return v


# ================================================================ integers as C# computes them
@always_inline
def rt_idiv[dt: DType](a: Scalar[dt], b: Scalar[dt]) -> Scalar[dt]:
    """a / b truncating toward zero (Mojo's // floors)"""
    var q = a // b
    if (a % b != 0) and ((a < 0) != (b < 0)):
        q += 1
    return q


@always_inline
def rt_irem[dt: DType](a: Scalar[dt], b: Scalar[dt]) -> Scalar[dt]:
    return a - b * rt_idiv(a, b)


@always_inline
def _mask[dt: DType]() -> Int:
    comptime if dt == DType.int64 or dt == DType.uint64:
        return 63
    return 31


@always_inline
def rt_shl[dt: DType, dt2: DType](a: Scalar[dt], n: Scalar[dt2]) -> Scalar[dt]:
    return a << Scalar[dt](Int(n) & _mask[dt]())


@always_inline
def rt_shr[dt: DType, dt2: DType](a: Scalar[dt], n: Scalar[dt2]) -> Scalar[dt]:
    return a >> Scalar[dt](Int(n) & _mask[dt]())


@always_inline
def rt_ushr[dt: DType, dt2: DType](a: Scalar[dt], n: Scalar[dt2]) -> Scalar[dt]:
    comptime if dt == DType.int64:
        return (a.cast[DType.uint64]() >> UInt64(Int(n) & 63)).cast[dt]()
    comptime if dt == DType.int32:
        return (a.cast[DType.uint32]() >> UInt32(Int(n) & 31)).cast[dt]()
    return a >> Scalar[dt](Int(n) & _mask[dt]())


@always_inline
def rt_band(a: Bool, b: Bool) -> Bool:
    return a and b


@always_inline
def rt_bor(a: Bool, b: Bool) -> Bool:
    return a or b


# double to integer as .NET 8 on x86-64 does it (cvttsd2si: NaN and out of range give the minimum)
@always_inline
def rt_d2int32(x: Float64) -> Int32:
    if not (x > -2147483649.0 and x < 2147483648.0):
        return Int32(-2147483648)
    return Int32(Int(x))


@always_inline
def rt_d2int64(x: Float64) -> Int64:
    if not (x >= -9223372036854775808.0 and x < 9223372036854775808.0):
        return Int64(-9223372036854775807) - 1
    return Int64(Int(x))


@always_inline
def rt_d2uint32(x: Float64) -> UInt32:
    return rt_d2int64(x).cast[DType.uint32]()


@always_inline
def rt_d2uint64(x: Float64) -> UInt64:
    if x < 9223372036854775808.0:
        return rt_d2int64(x).cast[DType.uint64]()
    return rt_d2int64(x - 9223372036854775808.0).cast[DType.uint64]() ^ UInt64(0x8000000000000000)


@always_inline
def rt_d2int16(x: Float64) -> Int16:
    return rt_d2int32(x).cast[DType.int16]()


@always_inline
def rt_d2uint16(x: Float64) -> UInt16:
    return rt_d2int32(x).cast[DType.uint16]()


@always_inline
def rt_d2int8(x: Float64) -> Int8:
    return rt_d2int32(x).cast[DType.int8]()


@always_inline
def rt_d2uint8(x: Float64) -> UInt8:
    return rt_d2int32(x).cast[DType.uint8]()


@always_inline
def f64_bits(u: UInt64) -> Float64:
    return bitcast[DType.float64, 1](u)


@always_inline
def f32_bits(u: UInt32) -> Float32:
    return bitcast[DType.float32, 1](u)


@always_inline
def bits_of(x: Float64) -> UInt64:
    return bitcast[DType.uint64, 1](x)


struct Conv:
    @staticmethod
    def D2I(x: Float64) raises -> Int32:
        return rt_d2int32(x)

    @staticmethod
    def D2L(x: Float64) raises -> Int64:
        return rt_d2int64(x)

    @staticmethod
    def D2UL(x: Float64) raises -> UInt64:
        # the C++ reference's (unsigned long) cast: NaN gives 2^63 (lessons/44)
        return rt_d2uint64(x)

    @staticmethod
    def D2SB(x: Float64) raises -> Int8:
        return rt_d2int8(x)

    @staticmethod
    def D2U(x: Float64) raises -> UInt32:
        return rt_d2uint32(x)


# ================================================================ the element protocol (C#'s Elem<T>, EqualityComparer, Comparer, std::hash)
def elem_make[T: Elem]() raises -> T:
    comptime if conforms_to(T, ElemOps):
        return T.e_make()
    return rt_zero[T]()


def elem_copy[T: Elem](x: T) raises -> T:
    comptime if conforms_to(T, ElemOps):
        comptime if T.NEEDS_COPY:
            return x.e_copy()
    return x


def elem_needs_copy[T: Elem]() -> Bool:
    comptime if conforms_to(T, ElemOps):
        return T.NEEDS_COPY
    return False


def elem_is_class[T: Elem]() -> Bool:
    """Elem<T>.IsClass: an engine or runtime class with copy semantics"""
    comptime if conforms_to(T, ElemOps):
        return T.IS_CLASS
    return False


def elem_assign[T: Elem](d: T, s: T) raises:
    comptime if conforms_to(T, ElemOps):
        d.e_assign(s)


def elem_eq[T: Elem](a: T, b: T) raises -> Bool:
    comptime if T == Float64:
        var x = rebind[Float64](a)
        var y = rebind[Float64](b)
        return x == y or (x != x and y != y)
    comptime if T == Float32:
        var x = rebind[Float32](a)
        var y = rebind[Float32](b)
        return x == y or (x != x and y != y)
    comptime if conforms_to(T, ElemOps):
        return a.e_eq(b)
    return _bits_eq(a, b)


def _bits_eq[T: Elem](a: T, b: T) -> Bool:
    # the bytes are compared in copies on the runtime's stack, not through the arguments' addresses (stack slots
    # LLVM may never have written; see rt_box)
    var sp = rt_sp()
    var sa = rt_salloc[T]()
    var sb = rt_salloc[T]()
    sa[] = a
    sb[] = b
    var pa = P[UInt8](unsafe_from_address=Int(sa))
    var pb = P[UInt8](unsafe_from_address=Int(sb))
    var r = True
    for i in range(size_of[T]()):
        if pa[unsafe_offset=i] != pb[unsafe_offset=i]:
            r = False
            break
    rt_set_sp(sp)
    return r


def elem_less[T: Elem](a: T, b: T) raises -> Bool:
    comptime if T == Float64:
        var x = rebind[Float64](a)
        var y = rebind[Float64](b)
        return x < y or (x != x and y == y)
    comptime if T == Float32:
        var x = rebind[Float32](a)
        var y = rebind[Float32](b)
        return x < y or (x != x and y == y)
    comptime if T == Int32:
        return rebind[Int32](a) < rebind[Int32](b)
    comptime if T == Int64:
        return rebind[Int64](a) < rebind[Int64](b)
    comptime if T == UInt64:
        return rebind[UInt64](a) < rebind[UInt64](b)
    comptime if T == UInt32:
        return rebind[UInt32](a) < rebind[UInt32](b)
    comptime if T == Int8:
        return rebind[Int8](a) < rebind[Int8](b)
    comptime if T == UInt8:
        return rebind[UInt8](a) < rebind[UInt8](b)
    comptime if T == Int16:
        return rebind[Int16](a) < rebind[Int16](b)
    comptime if T == UInt16:
        return rebind[UInt16](a) < rebind[UInt16](b)
    comptime if T == Bool:
        return (not rebind[Bool](a)) and rebind[Bool](b)
    comptime if conforms_to(T, ElemOps):
        return a.e_less(b)
    raise rt_todo_err("less of an unknown type")


def elem_hash[T: Elem](x: T) raises -> UInt64:
    """std::hash as libstdc++ computes it (identity for integers, _Hash_bytes for doubles and strings)"""
    comptime if T == Int32:
        return Int64(rebind[Int32](x)).cast[DType.uint64]()
    comptime if T == Int64:
        return rebind[Int64](x).cast[DType.uint64]()
    comptime if T == UInt64:
        return rebind[UInt64](x)
    comptime if T == UInt32:
        return rebind[UInt32](x).cast[DType.uint64]()
    comptime if T == Int16:
        return Int64(rebind[Int16](x)).cast[DType.uint64]()
    comptime if T == Int8:
        return Int64(rebind[Int8](x)).cast[DType.uint64]()
    comptime if T == UInt8:
        return rebind[UInt8](x).cast[DType.uint64]()
    comptime if T == UInt16:
        return rebind[UInt16](x).cast[DType.uint64]()
    comptime if T == Bool:
        return UInt64(1) if rebind[Bool](x) else UInt64(0)
    comptime if T == Float64:
        var d = rebind[Float64](x)
        if d == 0.0:
            return 0
        var b = bits_of(d)
        return hash_bytes(P[UInt8](unsafe_from_address=Int(rt_addr(b))), 8, 0xc70f6907)
    comptime if conforms_to(T, ElemOps):
        return x.e_hash()
    raise rt_todo_err("hash of an unknown type")


def hash_bytes(b: P[UInt8], len: Int, seed: UInt64) -> UInt64:
    """libstdc++'s std::_Hash_bytes (libsupc++/hash_bytes.cc, the 64-bit branch)"""
    var mul: UInt64 = (UInt64(0xc6a4a793) << 32) + UInt64(0x5bd1e995)
    var aligned = len & ~7
    var h: UInt64 = seed ^ (UInt64(len) * mul)
    var p = 0
    while p < aligned:
        var data: UInt64 = 0
        for k in range(8):
            data |= b[unsafe_offset=p + k].cast[DType.uint64]() << UInt64(8 * k)
        data = _shift_mix(data * mul) * mul
        h ^= data
        h *= mul
        p += 8
    var rest = len & 7
    if rest != 0:
        var data: UInt64 = 0
        var n = rest - 1
        while n >= 0:
            data = (data << 8) + b[unsafe_offset=p + n].cast[DType.uint64]()
            n -= 1
        h ^= data
        h *= mul
    h = _shift_mix(h) * mul
    h = _shift_mix(h)
    return h


@always_inline
def _shift_mix(v: UInt64) -> UInt64:
    return v ^ (v >> 47)


# ================================================================ exceptions
struct CppException(EStruct):
    """std::exception and the runtime's kinds: a type id (1 to 13 the C++ standard exceptions, 100 on .NET's) and the
    message; an engine exception class embeds it as its base"""
    var tid: UInt32
    var msg: VP

    def init_default(mut self):
        if self.tid == 0:
            self.tid = 1
        self.msg = VP_null()

    def what(self) raises -> CPtr:
        if Int(self.msg) == 0:
            return rt_lit(_kind_name(self.tid))
        return CPtr(self.msg.unsafe_bitcast[Int8]())


def _kind_name(k: UInt32) -> StaticString:
    if k == 10:
        return "std::bad_alloc"
    if k == 11:
        return "bad optional access"
    if k == 12:
        return "bad_function_call"
    if k == 13:
        return "std::get: wrong index for variant"
    return "std::exception"


def exc_parent(t: UInt32) -> UInt32:
    if t == 2 or t == 3 or t == 10 or t == 11 or t == 12 or t == 13:
        return 1
    if t == 4 or t == 5 or t == 6 or t == 7:
        return 2
    if t == 8 or t == 9:
        return 3
    if t >= 101 and t <= 105:
        return 100
    return 0


def rt_exc_new(kind: Int, msg: CPtr) -> Ref[CppException]:
    """an exception of a runtime kind with a copy of the message (NUL-terminated bytes)"""
    var e = Ref[CppException](gc_new[CppException]())
    e[].tid = UInt32(kind)
    if not msg.isnull():
        var n = 0
        while msg.p[unsafe_offset=n] != 0:
            n += 1
        var b = gc_atomic_bytes(n + 1)
        _ = external_call["memcpy", VP](b, VP(unsafe_from_address=Int(msg.p)), n)
        e[].msg = b
    return e


def rt_exc_kind(kind: Int, msg: StaticString) -> Ref[CppException]:
    return rt_exc_new(kind, rt_lit(msg))


@always_inline
def rt_throw(e: Ref[CppException]) -> Error:
    """throw e: the pending exception, and the Mojo error that carries it up"""
    rts()[].exc = e
    return Error()


@always_inline
def rt_exc_get() -> Ref[CppException]:
    return rts()[].exc


def rt_unreachable() -> Error:
    rt_die("unreachable code reached")
    return Error()


def rt_todo(msg: StaticString) -> Error:
    _ = external_call["write", Int](Int32(2), VP(unsafe_from_address=Int("untranslated: ".unsafe_ptr())), 14)
    rt_die(msg)
    return Error()


def rt_todo_err(msg: StaticString) -> Error:
    return rt_throw(rt_exc_kind(103, msg))


def rt_bad_function_call() -> Error:
    return rt_throw(rt_exc_kind(12, "bad_function_call"))


# ================================================================ math: glibc's own, at the C++ engine's symbol versions
# The build passes `--fp-mode contract=off --target-cpu x86-64`: no fused multiply-add, and the baseline instructions.
# Each libm call is a wrapper the compiler may not inline, so LLVM cannot fold or rewrite it (swmm5-ports lessons/43).
@no_inline
def _exp(x: Float64) -> Float64:
    return external_call["exp", Float64](x)


@no_inline
def _log(x: Float64) -> Float64:
    return external_call["log", Float64](x)


@no_inline
def _log10(x: Float64) -> Float64:
    return external_call["log10", Float64](x)


@no_inline
def _log2(x: Float64) -> Float64:
    return external_call["log2", Float64](x)


@no_inline
def _pow(x: Float64, y: Float64) -> Float64:
    return external_call["pow", Float64](x, y)


@no_inline
def _sin(x: Float64) -> Float64:
    return external_call["sin", Float64](x)


@no_inline
def _cos(x: Float64) -> Float64:
    return external_call["cos", Float64](x)


@no_inline
def _tan(x: Float64) -> Float64:
    return external_call["tan", Float64](x)


@no_inline
def _asin(x: Float64) -> Float64:
    return external_call["asin", Float64](x)


@no_inline
def _acos(x: Float64) -> Float64:
    return external_call["acos", Float64](x)


@no_inline
def _atan(x: Float64) -> Float64:
    return external_call["atan", Float64](x)


@no_inline
def _atan2(y: Float64, x: Float64) -> Float64:
    return external_call["atan2", Float64](y, x)


@no_inline
def _sinh(x: Float64) -> Float64:
    return external_call["sinh", Float64](x)


@no_inline
def _cosh(x: Float64) -> Float64:
    return external_call["cosh", Float64](x)


@no_inline
def _tanh(x: Float64) -> Float64:
    return external_call["tanh", Float64](x)


@no_inline
def _expm1(x: Float64) -> Float64:
    return external_call["expm1", Float64](x)


@no_inline
def _log1p(x: Float64) -> Float64:
    return external_call["log1p", Float64](x)


@no_inline
def _cbrt(x: Float64) -> Float64:
    return external_call["cbrt", Float64](x)


@no_inline
def _hypot(x: Float64, y: Float64) -> Float64:
    return external_call["hypot", Float64](x, y)


@no_inline
def _fmod(x: Float64, y: Float64) -> Float64:
    return external_call["fmod", Float64](x, y)


@no_inline
def _remainder(x: Float64, y: Float64) -> Float64:
    return external_call["remainder", Float64](x, y)


@no_inline
def _nextafter(x: Float64, y: Float64) -> Float64:
    return external_call["nextafter", Float64](x, y)


@no_inline
def _round(x: Float64) -> Float64:
    return external_call["round", Float64](x)


@no_inline
def _floor(x: Float64) -> Float64:
    return external_call["floor", Float64](x)


@no_inline
def _ceil(x: Float64) -> Float64:
    return external_call["ceil", Float64](x)


@no_inline
def _trunc(x: Float64) -> Float64:
    return external_call["trunc", Float64](x)


@no_inline
def _sqrt(x: Float64) -> Float64:
    return external_call["sqrt", Float64](x)


@always_inline
def _fabs(x: Float64) -> Float64:
    return f64_bits(bits_of(x) & UInt64(0x7FFFFFFFFFFFFFFF))


struct Math:
    """System.Math as the C# engine calls it: glibc's functions, as the C++ engine calls them"""
    @staticmethod
    def Abs(x: Float64) -> Float64:
        return _fabs(x)

    @staticmethod
    def Abs(x: Int32) -> Int32:
        return -x if x < 0 else x

    @staticmethod
    def Abs(x: Int64) -> Int64:
        return -x if x < 0 else x

    @staticmethod
    def Acos(x: Float64) -> Float64:
        return _acos(x)

    @staticmethod
    def Asin(x: Float64) -> Float64:
        return _asin(x)

    @staticmethod
    def Atan(x: Float64) -> Float64:
        return _atan(x)

    @staticmethod
    def Atan2(y: Float64, x: Float64) -> Float64:
        return _atan2(y, x)

    @staticmethod
    def Cbrt(x: Float64) -> Float64:
        return _cbrt(x)

    @staticmethod
    def Ceiling(x: Float64) -> Float64:
        return _ceil(x)

    @staticmethod
    def CopySign(x: Float64, y: Float64) -> Float64:
        return f64_bits((bits_of(x) & UInt64(0x7FFFFFFFFFFFFFFF)) | (bits_of(y) & UInt64(0x8000000000000000)))

    @staticmethod
    def Cos(x: Float64) -> Float64:
        return _cos(x)

    @staticmethod
    def Cosh(x: Float64) -> Float64:
        return _cosh(x)

    @staticmethod
    def Exp(x: Float64) -> Float64:
        return _exp(x)

    @staticmethod
    def Floor(x: Float64) -> Float64:
        return _floor(x)

    @staticmethod
    def Log(x: Float64) -> Float64:
        return _log(x)

    @staticmethod
    def Log10(x: Float64) -> Float64:
        return _log10(x)

    @staticmethod
    def Log2(x: Float64) -> Float64:
        return _log2(x)

    @staticmethod
    def Pow(x: Float64, y: Float64) -> Float64:
        return _pow(x, y)

    @staticmethod
    def Sin(x: Float64) -> Float64:
        return _sin(x)

    @staticmethod
    def Sinh(x: Float64) -> Float64:
        return _sinh(x)

    @staticmethod
    def Sqrt(x: Float64) -> Float64:
        return _sqrt(x)

    @staticmethod
    def Tan(x: Float64) -> Float64:
        return _tan(x)

    @staticmethod
    def Tanh(x: Float64) -> Float64:
        return _tanh(x)

    @staticmethod
    def Truncate(x: Float64) -> Float64:
        return _trunc(x)


struct LibM:
    @staticmethod
    def expm1(x: Float64) raises -> Float64:
        return _expm1(x)

    @staticmethod
    def log1p(x: Float64) raises -> Float64:
        return _log1p(x)

    @staticmethod
    def fmod(x: Float64, y: Float64) -> Float64:
        return _fmod(x, y)

    @staticmethod
    def fmod(x: Float32, y: Float32) -> Float32:
        return _fmod(x.cast[DType.float64](), y.cast[DType.float64]()).cast[DType.float32]()

    @staticmethod
    def hypot(x: Float64, y: Float64) raises -> Float64:
        return _hypot(x, y)

    @staticmethod
    def remainder(x: Float64, y: Float64) raises -> Float64:
        return _remainder(x, y)

    @staticmethod
    def nextafter(x: Float64, y: Float64) raises -> Float64:
        return _nextafter(x, y)

    @staticmethod
    def round_(x: Float64) raises -> Float64:
        return _round(x)


struct Dbl:
    @staticmethod
    def IsNaN(x: Float64) -> Bool:
        return x != x

    @staticmethod
    def IsFinite(x: Float64) -> Bool:
        return (bits_of(x) & UInt64(0x7FF0000000000000)) != UInt64(0x7FF0000000000000)

    @staticmethod
    def IsInfinity(x: Float64) -> Bool:
        return (bits_of(x) & UInt64(0x7FFFFFFFFFFFFFFF)) == UInt64(0x7FF0000000000000)

    @staticmethod
    def IsPositiveInfinity(x: Float64) -> Bool:
        return bits_of(x) == UInt64(0x7FF0000000000000)

    @staticmethod
    def IsNegativeInfinity(x: Float64) -> Bool:
        return bits_of(x) == UInt64(0xFFF0000000000000)

    @staticmethod
    def IsNegative(x: Float64) -> Bool:
        return (bits_of(x) >> 63) != 0


struct BitConverter:
    @staticmethod
    def DoubleToInt64Bits(d: Float64) -> Int64:
        return bitcast[DType.int64, 1](d)

    @staticmethod
    def Int64BitsToDouble(l: Int64) -> Float64:
        return bitcast[DType.float64, 1](l)


struct M:
    """std::min, std::max, std::clamp"""
    @staticmethod
    def min_[dt: DType](a: Scalar[dt], b: Scalar[dt]) raises -> Scalar[dt]:
        return b if b < a else a

    @staticmethod
    def max_[dt: DType](a: Scalar[dt], b: Scalar[dt]) raises -> Scalar[dt]:
        return b if a < b else a

    @staticmethod
    def clamp[dt: DType](v: Scalar[dt], lo: Scalar[dt], hi: Scalar[dt]) raises -> Scalar[dt]:
        return lo if v < lo else (hi if hi < v else v)

    @staticmethod
    def min_[dt: DType](a: Ary[Scalar[dt]]) raises -> Scalar[dt]:
        var r = a[0]
        for i in range(1, a.n):
            if a[i] < r:
                r = a[i]
        return r

    @staticmethod
    def max_[dt: DType](a: Ary[Scalar[dt]]) raises -> Scalar[dt]:
        var r = a[0]
        for i in range(1, a.n):
            if r < a[i]:
                r = a[i]
        return r


# ================================================================ small runtime classes
struct Box[T: Elem](EStruct):
    """a C++ pointer to a local or a field (Box<T>.Of(() => ref x)): the address"""
    var p: P[Self.T]

    @staticmethod
    def of(p: P[Self.T]) raises -> Ref[Box[Self.T]]:
        var b = Ref[Box[Self.T]](gc_new[Box[Self.T]]())
        b[].p = p
        return b

    def p_V(self) raises -> P[Self.T]:
        return self.p


struct Atomic[T: Elem](EStruct):
    var v: Self.T
    comptime IS_CLASS = True

    @staticmethod
    def new_() raises -> Ref[Atomic[Self.T]]:
        return Ref[Atomic[Self.T]](gc_new[Atomic[Self.T]]())

    @staticmethod
    def new_(x: Self.T) raises -> Ref[Atomic[Self.T]]:
        var a = Self.new_()
        a[].v = x
        return a

    def fetch_add(mut self, d: Self.T, order: Int32) raises -> Self.T:
        var o = self.v
        self.v = rt_add(o, d)
        return o

    def compare_exchange(mut self, expected: P[Self.T], desired: Self.T) raises -> Bool:
        if elem_eq(self.v, expected[]):
            self.v = desired
            return True
        expected[] = self.v
        return False

    @staticmethod
    def __clone(x: Ref[Self]) raises -> Ref[Self]:
        return Self.new_(x[].v)

    @staticmethod
    def __assign(d: Ref[Self], x: Ref[Self]) raises:
        d[].v = x[].v




struct OnceFlag(EStruct):
    var done: Bool

    @staticmethod
    def new_() raises -> Ref[OnceFlag]:
        return Ref[OnceFlag](gc_new[OnceFlag]())


struct Mutex(EStruct):
    var x: UInt8

    @staticmethod
    def new_() raises -> Ref[Mutex]:
        return Ref[Mutex](gc_new[Mutex]())


struct CondVar(EStruct):
    var x: UInt8

    @staticmethod
    def new_() raises -> Ref[CondVar]:
        return Ref[CondVar](gc_new[CondVar]())


struct Lock(EStruct):
    var x: UInt8

    @staticmethod
    def new_() raises -> Ref[Lock]:
        return Ref[Lock](gc_new[Lock]())


struct Thread(EStruct):
    var x: UInt8

    @staticmethod
    def new_() raises -> Ref[Thread]:
        return Ref[Thread](gc_new[Thread]())

    def joinable(self) raises -> Bool:
        return False

    def join(self) raises:
        pass


struct Defer(EStruct):
    """a destructor deferred to the end of the enclosing block (a using declaration), unless cancelled"""
    var a: Dlg

    @staticmethod
    def new_(a: Dlg) raises -> Ref[Defer]:
        var d = Ref[Defer](gc_new[Defer]())
        d[].a = a
        return d

    def Cancel(mut self) raises:
        self.a = Dlg()

    def dispose_[call: def(Dlg) raises thin](mut self) raises:
        var x = self.a
        self.a = Dlg()
        if x.id != 0:
            call(x)


struct Sys:
    @staticmethod
    def hardware_concurrency() raises -> UInt32:
        var n = external_call["get_nprocs", Int32]()
        return UInt32(n) if n > 0 else UInt32(0)


struct Duration(ImplicitlyCopyable):
    var ns: Int64

    def __init__(out self):
        self.ns = 0

    def __init__(out self, ns: Int64):
        self.ns = ns

    def count(self) raises -> Float64:
        return self.ns.cast[DType.float64]() * 1e-9


struct TimePoint(ImplicitlyCopyable):
    var ns: Int64

    def __init__(out self):
        self.ns = 0

    def __init__(out self, ns: Int64):
        self.ns = ns

    @staticmethod
    def now() raises -> TimePoint:
        var ts = gc_atomic_bytes(16).unsafe_bitcast[Int64]()
        _ = external_call["clock_gettime", Int32](Int32(1), ts)
        return TimePoint(ts[] * 1000000000 + ts[unsafe_offset=1])

    @staticmethod
    def op_sub(a: TimePoint, b: TimePoint) -> Duration:
        return Duration(a.ns - b.ns)

    def time_since_epoch(self) raises -> Duration:
        return Duration(self.ns)


# ================================================================ iterators over contiguous storage
struct Iter[T: Elem](ImplicitlyCopyable, ElemOps):
    """a vector or array iterator: the storage and an index; two iterators compare by index (the C# runtime's)"""
    var a: Ary[Self.T]
    var i: Int64
    comptime NEEDS_COPY = False

    @always_inline
    def __init__(out self):
        self.a = Ary[Self.T]()
        self.i = 0

    @always_inline
    def __init__(out self, a: Ary[Self.T], i: Int64):
        self.a = a
        self.i = i

    @staticmethod
    def new_(a: Ary[Self.T], i: Int64) raises -> Self:
        return Self(a, i)

    @always_inline
    def p_Deref(self) -> P[Self.T]:
        return padd(self.a.p, Int(self.i))

    @always_inline
    def p_At(self, k: Int64) -> P[Self.T]:
        return padd(self.a.p, Int(self.i + k))

    @always_inline
    def ptr(self) -> Ptr[Self.T]:
        return Ptr[Self.T](padd(self.a.p, Int(self.i)))

    @staticmethod
    def op_add(x: Self, k: Int64) -> Self:
        return Self(x.a, x.i + k)

    @staticmethod
    def op_sub(x: Self, k: Int64) -> Self:
        return Self(x.a, x.i - k)

    @staticmethod
    def op_sub(x: Self, y: Self) -> Int64:
        return x.i - y.i

    @staticmethod
    def op_inc(x: Self) -> Self:
        return Self(x.a, x.i + 1)

    @staticmethod
    def op_dec(x: Self) -> Self:
        return Self(x.a, x.i - 1)

    @staticmethod
    def op_eq(x: Self, y: Self) -> Bool:
        return x.i == y.i

    @staticmethod
    def op_ne(x: Self, y: Self) -> Bool:
        return x.i != y.i

    @staticmethod
    def op_lt(x: Self, y: Self) -> Bool:
        return x.i < y.i

    @staticmethod
    def op_gt(x: Self, y: Self) -> Bool:
        return x.i > y.i

    @staticmethod
    def op_le(x: Self, y: Self) -> Bool:
        return x.i <= y.i

    @staticmethod
    def op_ge(x: Self, y: Self) -> Bool:
        return x.i >= y.i

    @staticmethod
    def e_make() raises -> Self:
        return Self()

    def e_copy(self) raises -> Self:
        return self

    def e_eq(self, o: Self) raises -> Bool:
        return self.i == o.i

    def e_less(self, o: Self) raises -> Bool:
        return self.i < o.i

    def e_hash(self) raises -> UInt64:
        return UInt64(self.i)


def _elem_make_n[T: Elem](n: Int) raises -> T:
    comptime if conforms_to(T, ElemOps):
        return T.e_make_n(n, 0)
    return rt_zero[T]()


def _elem_make_cls[T: Elem]() raises -> T:
    comptime if conforms_to(T, ElemOps):
        comptime if T.MAKES:
            return T.e_make()
    return rt_zero[T]()


def rt_add[T: Elem](a: T, b: T) -> T:
    comptime if T == Int64:
        return rebind[T](rebind[Int64](a) + rebind[Int64](b))
    comptime if T == Int32:
        return rebind[T](rebind[Int32](a) + rebind[Int32](b))
    comptime if T == UInt64:
        return rebind[T](rebind[UInt64](a) + rebind[UInt64](b))
    comptime if T == Float64:
        return rebind[T](rebind[Float64](a) + rebind[Float64](b))
    return a
