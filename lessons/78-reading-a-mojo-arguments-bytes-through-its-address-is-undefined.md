Reading a Mojo value's bytes through the address of an argument or a local gave LLVM an undefined value, and LLVM then deleted the whole path that used it: the engine's open() became one call to "out of memory".

The first whole-engine build of the Mojo port stopped every model at once with `out of memory`, after 3,469 calls of
`GC_malloc` that had all succeeded. The machine code of `F___swmm_engine_open` (gdb, `x/30i`) showed why: after the
eight-byte `GC_malloc` for a lambda's cell came the call that prints the message, with no test of the result in
between. LLVM had kept only the branch where the allocation failed, so it had proved every other path undefined.
The cause was how the runtime turned an object reference into a C# `object` and back:

    def rt_box[T: Elem](x: T) -> Obj:
        comptime if T.IS_REF:
            return Obj(P[Int](unsafe_from_address=Int(rt_addr(x)))[])    # x's bytes, read through its address

    def rt_unbox[T: Elem](o: Obj) -> T:
        comptime if T.IS_REF:
            var a = o.a
            return P[T](unsafe_from_address=Int(rt_addr(a)))[]           # a's bytes, read as a T

`rt_addr` makes an untracked pointer (`Pointer(to=x)` turned into an integer and back). Mojo does not count that as
a use of the stack slot, so the store of `a` may be dropped and the load reads undefined memory; after inlining, the
engine handle that `swmm_engine_open` unboxes was undefined, the first field load through it was undefined
behaviour, and LLVM removed the path. The same pattern wrote garbage into the binary results file: `R.fwriteI1`
passed `rt_addr(b)` of a local copy of the value to the runtime's `fwrite`, and the `.out` file's first word was 13,
not the magic number 516114522. `find_first_not_of(' ')` searched for a byte that was never stored, and the report
gained three blank lines. It is the hazard of swmm5-ports lessons/42 again, in new places.

The fixes: `Ref` and `Obj` give their address through two trait methods (`e_word`, `e_of_word`), so boxing is a
field read; and every runtime function that needs a local's bytes in memory (the binary writes, a one-byte stream
write, a one-character search, the bitwise equality and null tests of the containers) puts the value in a slot on
the runtime's own stack (`rt_salloc`, memory LLVM cannot see into) and gives the slot back before returning.

Lesson: in Mojo, never take the address of an argument or a local to read or pass its bytes. Copy the value into
memory the compiler does not own first. A whole function collapsing to its error exit is the sign of undefined
behaviour upstream, not of the error itself.
