A C++ zero initializer of 65,536 elements, translated as one variadic call, kept the Mojo 1.2 compiler busy for more than seven minutes in a build that otherwise took two; a long all-zero initializer is now a zeroed array.

The SWMM6 checkpoint code hashes a file through a stack buffer, `char buffer[1 << 16]{}`. cpp2x writes it into the
C# engine as an array initializer with 65,536 zeros (cs/gen/io_CheckpointFile.cpp.cs), and the first Mojo
translator copied the initializer into the call that makes an array from its elements:

    def F_io__anon_io_CheckpointFile_cpp__prefixHash_CheckpointFile(var f: Ref[CFile], ...) raises -> UInt64:
        var buffer: Ary[Int8] = Ary[Int8].of(Int8(0), Int8(0), Int8(0), ...)   # 65,536 arguments, 589,864 characters

A second one, `float buffer[16384]{}`, became 16,384 `f32_bits(0x00000000)` arguments. Mojo compiles such a call
(each argument an expression, all of them packed into one variadic list) far more slowly than the rest of the
163,000 lines: the whole engine did not finish in 48 minutes. The search for the cause went by halves, with
`mojo/tools/stage.py` replacing every function body after number H by `raise rt_unreachable()` (Mojo compiles only
the functions a program can reach, so a stub also cuts off everything only it calls):

    H = 9388                               133 s
    H = 9394                               stopped at 420 s
    H = 9394, function 9392 stubbed        131 s    (prepareFileCheckpoint, which reaches prefixHash)

Function 9392 newly reaches 26 functions of the checkpoint code, and one of them is long: prefixHash, number 8955,
with the 65,536-argument call (the 16,384-argument one is in validateFileCheckpoint, number 9395). The translator now writes an initializer of
more than 16 elements that are all constant zeros (bit for bit, so -0.0 does not count) as `Ary[T].make(n)`, which
returns a zeroed array as `new T[n]` does (MojoExpr.cs, NewArray and ZeroConst; tools/cs2x/MOJO.md). A long
initializer with other values stays a call of `of`; the longest left is the 385-entry error table.

Lesson: when a compiler stalls on generated code, look for the longest lines first (`awk 'length > 5000'`). A
generated file can hold one expression that is larger than everything else put together.
