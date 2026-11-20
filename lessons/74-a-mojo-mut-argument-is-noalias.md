A Mojo `mut` argument is a `noalias` pointer to LLVM, so it cannot stand for a C# `ref`: the C# engine may reach the same variable another way during the call.

The obvious translation of a C# `ref double x` parameter into Mojo 1.2 is `mut x: Float64`: the caller passes the
variable itself, and Mojo, which tracks where every reference points, keeps the caller's stack slot honest. A
ten-line probe showed why it cannot be used:

    @no_inline
    def upd(mut a: Float64, q: P[Float64]) raises -> Float64:
        a = 1.0
        q[] = 2.0          # q points at the same variable as a
        return a

    var x = 0.0
    var q = P[Float64](unsafe_from_address=Int(Pointer(to=x)))
    print(upd(x, q))       # prints 1.0; C# and C++ give 2.0

The unoptimised LLVM IR (`mojo build --emit llvm -O0`) declares the parameter `ptr noalias noundef nonnull %0`: Mojo
promises LLVM that nothing else in the function touches what `a` refers to (its own exclusivity rule for mutable
references). With that promise LLVM turned the argument into a copy in and a copy out (the optimised function is
renamed `..._REMOVED_ARG` and returns the new value of `a` in a register), so the write through `q` was lost.
C# makes no such promise: the generated engine passes `ref this.field` to methods that also read and write
`this.field`, and `ref a[i]` and `ref a[j]` with `i == j`.

So the Mojo port passes every C# `ref` as a raw pointer (`P[T]`, Mojo's `Pointer` with an untracked origin, which
carries no `noalias`), and a local whose address is taken lives where a raw pointer to it is safe: on a stack of the
runtime's own (`rt_salloc`, a block of memory the function takes at entry and gives back at every return), or in a
collected cell when a lambda captures it. A raw pointer to a Mojo stack slot is not safe either: Mojo marks a call
`tail` when the slot's address is one of its arguments as an untracked pointer, and LLVM then reads the slot after
the call as if the callee had not written it (swmm5-ports lessons/42, the same compiler). Runtime methods keep Mojo's
`mut self` (a method's own object), but no runtime function takes a C# `ref` as `mut`.

What to take from it: in a language that reasons about aliasing, read the IR of one call before trusting its
by-reference convention to mean what the source language means. "Mutable reference" in Mojo means "the only way to
this memory for the duration of the call"; in C# and C++ it means only "the address of this memory".
