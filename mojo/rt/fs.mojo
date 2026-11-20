# fs.mojo - std::filesystem as the engine uses it (paths, existence, sizes, removal, renaming), after
# zig/rt/fs.zig and cs/runtime/Fs.cs, over glibc's stat, unlink, rmdir, rename and getcwd.
# Written by Claude (Anthropic) for the SWMM6 ports; see ../README.md and ../../AI-USE.md.

from std.ffi import external_call
from rt.core import *
from rt.crt import *
from rt.str import *
from rt.cont import *


comptime K_NOTFOUND = Int32(-1)
comptime K_REGULAR = Int32(1)
comptime K_DIRECTORY = Int32(2)


def kind_of(path: Ref[Str]) -> Int32:
    var st = gc_atomic_bytes(256)
    if external_call["stat", Int32](path[].cstr().p, st) != 0:
        return K_NOTFOUND
    var mode = st.unsafe_bitcast[UInt32]()[unsafe_offset=6] & 0o170000
    if mode == 0o040000:
        return K_DIRECTORY
    if mode == 0o100000:
        return K_REGULAR
    return 3


def size_of_file(path: Ref[Str]) -> Int64:
    var st = gc_atomic_bytes(256)
    if external_call["stat", Int32](path[].cstr().p, st) != 0:
        return -1
    var mode = st.unsafe_bitcast[UInt32]()[unsafe_offset=6] & 0o170000
    if mode != 0o100000:
        return -1
    return st.unsafe_bitcast[Int64]()[unsafe_offset=6]


struct ErrorCode(EStruct):
    var v: Int32

    @staticmethod
    def new_() raises -> Ref[ErrorCode]:
        return Ref[ErrorCode](gc_new[ErrorCode]())

    def Bool_(self) raises -> Bool:
        return self.v != 0

    def value(self) raises -> Int32:
        return self.v

    def clear(mut self) raises:
        self.v = 0


struct FileStatus(EStruct):
    var kind: Int32
    comptime IS_CLASS = True
    comptime LIB = True

    @staticmethod
    def of(path: Ref[Str]) -> Ref[FileStatus]:
        var s = Ref[FileStatus](gc_new[FileStatus]())
        s[].kind = kind_of(path)
        return s

    @staticmethod
    def __clone(x: Ref[FileStatus]) raises -> Ref[FileStatus]:
        var s = Ref[FileStatus](gc_new[FileStatus]())
        s[].kind = x[].kind
        return s

    def type_(self) raises -> Int32:
        return self.kind

    def Clone(self) raises -> Ref[FileStatus]:
        var s = Ref[FileStatus](gc_new[FileStatus]())
        s[].kind = self.kind
        return s


struct FsPath(EStruct):
    var p: Ref[Str]
    comptime IS_CLASS = True
    comptime LIB = True

    @staticmethod
    def of(s: Ref[Str]) -> Ref[FsPath]:
        var x = Ref[FsPath](gc_new[FsPath]())
        x[].p = Str.of_bytes(s[].b.p, Int(s[].n))
        return x

    @staticmethod
    def of_bytes(b: P[UInt8], n: Int) -> Ref[FsPath]:
        var x = Ref[FsPath](gc_new[FsPath]())
        x[].p = Str.of_bytes(b, n)
        return x

    @staticmethod
    def new_() raises -> Ref[FsPath]:
        return FsPath.of_bytes(rt_null[UInt8](), 0)

    @staticmethod
    def new_(s: Ref[Str]) raises -> Ref[FsPath]:
        return FsPath.of(s)

    @staticmethod
    def new_(s: CPtr) raises -> Ref[FsPath]:
        return FsPath.of(Str.new_(s))

    @staticmethod
    def __new() raises -> Ref[FsPath]:
        return FsPath.new_()

    @staticmethod
    def __clone(x: Ref[FsPath]) raises -> Ref[FsPath]:
        return FsPath.of(x[].p)

    @staticmethod
    def __assign(d: Ref[FsPath], x: Ref[FsPath]) raises:
        d[].p = Str.__clone(x[].p)

    @staticmethod
    def __moveFrom(d: Ref[FsPath], x: Ref[FsPath]) raises:
        d[].MoveFrom(x)

    @staticmethod
    def __less(a: Ref[FsPath], b: Ref[FsPath]) raises -> Bool:
        return a[].compare(b) < 0

    def Clone(self) raises -> Ref[FsPath]:
        return FsPath.of(self.p)

    def clear(mut self) raises:
        self.p = Str.new_()

    def Assign(mut self, o: Ref[FsPath]) raises:
        self.p = Str.__clone(o[].p)

    def Assign(mut self, s: Ref[Str]) raises:
        self.p = Str.__clone(s)

    def MoveFrom(mut self, o: Ref[FsPath]) raises:
        self.p = o[].p
        o[].p = Str.new_()

    def compare(self, o: Ref[FsPath]) raises -> Int32:
        return bytes_cmp(self.p[].b.p, Int(self.p[].n), o[].p[].b.p, Int(o[].p[].n))

    def CompareTo(self, o: Ref[FsPath]) raises -> Int32:
        return self.compare(o)

    def string(self) raises -> Ref[Str]:
        return Str.__clone(self.p)

    def generic_string(self) raises -> Ref[Str]:
        return Str.__clone(self.p)

    def native(self) raises -> Ref[Str]:
        return Str.__clone(self.p)

    def c_str(self) raises -> CPtr:
        return self.p[].cstr()

    def empty(self) raises -> Bool:
        return self.p[].n == 0

    def is_absolute(self) raises -> Bool:
        return self.p[].n > 0 and self.p[].b.p[] == 47

    def is_relative(self) raises -> Bool:
        return not self.is_absolute()

    def last_slash(self) -> Int:
        var i = Int(self.p[].n) - 1
        while i >= 0:
            if self.p[].b.p[unsafe_offset=i] == 47:
                return i
            i -= 1
        return -1

    def filename(self) raises -> Ref[FsPath]:
        var i = self.last_slash()
        return FsPath.of_bytes(padd(self.p[].b.p, i + 1), Int(self.p[].n) - i - 1)

    def parent_path(self) raises -> Ref[FsPath]:
        var i = self.last_slash()
        if i < 0:
            return FsPath.new_()
        if i == 0:
            return FsPath.of(Str.of_lit("/"))
        var j = i
        while j > 0 and self.p[].b.p[unsafe_offset=j - 1] == 47:
            j -= 1
        return FsPath.of_bytes(self.p[].b.p, 1 if j == 0 else j)

    def _ext_at(self) raises -> Int:
        """where the extension of the file name starts (its length when there is none)"""
        var f = self.filename()
        var s = f[].p
        var n = Int(s[].n)
        if (n == 1 and s[].b.p[] == 46) or (n == 2 and s[].b.p[] == 46 and s[].b.p[unsafe_offset=1] == 46):
            return n
        var i = n - 1
        while i > 0:
            if s[].b.p[unsafe_offset=i] == 46:
                return i
            i -= 1
        return n

    def stem(self) raises -> Ref[FsPath]:
        var f = self.filename()
        return FsPath.of_bytes(f[].p[].b.p, f[].ext_at_())

    def ext_at_(self) raises -> Int:
        return self._ext_at()

    def extension(self) raises -> Ref[FsPath]:
        var f = self.filename()
        var k = f[]._ext_at()
        return FsPath.of_bytes(padd(f[].p[].b.p, k), Int(f[].p[].n) - k)

    def replace_extension(mut self, ext: Ref[FsPath]) raises -> Ref[FsPath]:
        var e = self.extension()
        var keep = Int(self.p[].n) - Int(e[].p[].n)
        var out = Str.of_bytes(self.p[].b.p, keep)
        if not ext.isnull() and ext[].p[].n > 0:
            if ext[].p[].b.p[] != 46:
                out[].push_back(46)
            _ = out[].append(ext[].p)
        self.p = out
        return Ref[FsPath](rt_addr(self))

    def replace_extension(mut self, ext: Ref[Str]) raises -> Ref[FsPath]:
        return self.replace_extension(FsPath.of(ext))

    def Join(self, o: Ref[FsPath]) raises -> Ref[FsPath]:
        if o[].is_absolute():
            return FsPath.__clone(o)
        var n = Int(self.p[].n)
        if n == 0:
            return FsPath.__clone(o)
        var out = Str.of_bytes(self.p[].b.p, n)
        if self.p[].b.p[unsafe_offset=n - 1] != 47 and o[].p[].n > 0:
            out[].push_back(47)
        _ = out[].append(o[].p)
        return FsPath.of(out)

    def Join(self, o: Ref[Str]) raises -> Ref[FsPath]:
        return self.Join(FsPath.of(o))

    def Join(self, o: CPtr) raises -> Ref[FsPath]:
        return self.Join(FsPath.new_(o))

    def lexically_normal(self) raises -> Ref[FsPath]:
        return FsPath.of(normal_path(self.p))


def normal_path(s: Ref[Str]) raises -> Ref[Str]:
    var n = Int(s[].n)
    if n == 0:
        return Str.new_()
    var b = s[].b.p
    var absolute = b[] == 47
    var starts = List[Int]()
    var lens = List[Int]()
    var i = 0
    while i <= n:
        var j = i
        while j < n and b[unsafe_offset=j] != 47:
            j += 1
        var l = j - i
        var dot = l == 1 and b[unsafe_offset=i] == 46
        var dotdot = l == 2 and b[unsafe_offset=i] == 46 and b[unsafe_offset=i + 1] == 46
        if l == 0 or dot:
            pass
        elif dotdot and len(lens) > 0 and not (lens[len(lens) - 1] == 2 and b[unsafe_offset=starts[len(starts) - 1]] == 46 and b[unsafe_offset=starts[len(starts) - 1] + 1] == 46):
            _ = starts.pop()
            _ = lens.pop()
        elif dotdot and absolute:
            pass
        else:
            starts.append(i)
            lens.append(l)
        i = j + 1
    var out = Str.new_()
    if absolute:
        out[].push_back(47)
    for k in range(len(starts)):
        if k > 0:
            out[].push_back(47)
        out[].append_bytes(padd(b, starts[k]), lens[k])
    if b[unsafe_offset=n - 1] == 47 and len(starts) > 0:
        out[].push_back(47)
    if out[].n == 0:
        out[].push_back(46)
    return out


def full_path(p: Ref[Str]) raises -> Ref[Str]:
    if p[].n > 0 and p[].b.p[] == 47:
        return normal_path(p)
    var cwd = gc_atomic_bytes(4096).unsafe_bitcast[Int8]()
    if Int(external_call["getcwd", P[Int8]](cwd, Int(4096))) == 0:
        return normal_path(p)
    var out = Str.new_(CPtr(cwd))
    out[].push_back(47)
    _ = out[].append(p)
    return normal_path(out)


struct Fs:
    @staticmethod
    def exists(p: Ref[FsPath]) raises -> Bool:
        return kind_of(p[].p) != K_NOTFOUND

    @staticmethod
    def exists(p: Ref[FsPath], ec: Ref[ErrorCode]) raises -> Bool:
        return kind_of(p[].p) != K_NOTFOUND

    @staticmethod
    def exists(s: Ref[FileStatus]) raises -> Bool:
        return s[].kind != K_NOTFOUND

    @staticmethod
    def is_regular_file(p: Ref[FsPath]) raises -> Bool:
        return kind_of(p[].p) == K_REGULAR

    @staticmethod
    def is_regular_file(s: Ref[FileStatus]) raises -> Bool:
        return s[].kind == K_REGULAR

    @staticmethod
    def is_directory(p: Ref[FsPath]) raises -> Bool:
        return kind_of(p[].p) == K_DIRECTORY

    @staticmethod
    def is_directory(s: Ref[FileStatus]) raises -> Bool:
        return s[].kind == K_DIRECTORY

    @staticmethod
    def file_size(p: Ref[FsPath]) raises -> UInt64:
        var n = size_of_file(p[].p)
        return UInt64(0) if n < 0 else UInt64(Int(n))

    @staticmethod
    def file_size(p: Ref[FsPath], ec: Ref[ErrorCode]) raises -> UInt64:
        var n = size_of_file(p[].p)
        if n >= 0:
            ec[].v = 0
            return UInt64(Int(n))
        ec[].v = Int32(21) if kind_of(p[].p) == K_DIRECTORY else Int32(2)
        return UInt64(0xFFFFFFFFFFFFFFFF)

    @staticmethod
    def remove(p: Ref[FsPath], ec: Ref[ErrorCode]) raises -> Bool:
        ec[].v = 0
        var k = kind_of(p[].p)
        if k == K_REGULAR or k == 3:
            if external_call["unlink", Int32](p[].p[].cstr().p) != 0:
                ec[].v = 13
                return False
            return True
        if k == K_DIRECTORY:
            if external_call["rmdir", Int32](p[].p[].cstr().p) != 0:
                ec[].v = 13
                return False
            return True
        return False

    @staticmethod
    def remove(p: Ref[FsPath]) raises -> Bool:
        if kind_of(p[].p) != K_REGULAR:
            return False
        return external_call["unlink", Int32](p[].p[].cstr().p) == 0

    @staticmethod
    def rename(a: Ref[FsPath], b: Ref[FsPath], ec: Ref[ErrorCode]) raises:
        if external_call["rename", Int32](a[].p[].cstr().p, b[].p[].cstr().p) != 0:
            ec[].v = Int32(2) if kind_of(a[].p) == K_NOTFOUND else Int32(13)
            return
        ec[].v = 0

    @staticmethod
    def create_hard_link(target: Ref[FsPath], link: Ref[FsPath], ec: Ref[ErrorCode]) raises:
        """as the other ports have it: an existing link is EEXIST, otherwise a copy of the target"""
        if kind_of(link[].p) == K_REGULAR:
            ec[].v = 17
            return
        var src = fopen(target[].p[].cstr().p, rt_lit("rb").p)
        if isnull(src):
            ec[].v = 2
            return
        var dst = fopen(link[].p[].cstr().p, rt_lit("wb").p)
        if isnull(dst):
            _ = fclose(src)
            ec[].v = 2
            return
        var buf = gc_atomic_bytes(65536)
        while True:
            var n = fread(buf, 1, 65536, src)
            if n == 0:
                break
            _ = fwrite(buf, 1, n, dst)
        _ = fclose(src)
        _ = fclose(dst)
        ec[].v = 0

    @staticmethod
    def weakly_canonical(p: Ref[FsPath]) raises -> Ref[FsPath]:
        return FsPath.of(full_path(p[].p))

    @staticmethod
    def weakly_canonical(p: Ref[FsPath], ec: Ref[ErrorCode]) raises -> Ref[FsPath]:
        ec[].v = 0
        return FsPath.of(full_path(p[].p))

    @staticmethod
    def equivalent(a: Ref[FsPath], b: Ref[FsPath]) raises -> Bool:
        return Str.__eqv(full_path(a[].p), full_path(b[].p))

    @staticmethod
    def symlink_status(p: Ref[FsPath]) raises -> Ref[FileStatus]:
        return FileStatus.of(p[].p)

    @staticmethod
    def symlink_status(p: Ref[FsPath], ec: Ref[ErrorCode]) raises -> Ref[FileStatus]:
        ec[].v = 0
        return FileStatus.of(p[].p)

    @staticmethod
    def status(p: Ref[FsPath]) raises -> Ref[FileStatus]:
        return FileStatus.of(p[].p)
