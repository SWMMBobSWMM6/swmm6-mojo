# C# to Mojo: how tools/cs2x/Cs2Mojo.cs maps the generated engine

The Mojo engine is written from the verified C# engine (`cs/gen`, 480/480 against the SWMM6 reference) by a translator
written for it: Roslyn's semantic model, one IOperation tree per method, printed as Mojo 1.2.0. It is a new back end
(`Cs2Mojo.cs` for the driver, names, types and declarations, `MojoFn.cs` for statements, `MojoExpr.cs` for
expressions) whose structure follows the Zig back end (`Cs2Zig.cs` and its companions: classes as structs with a type
id, virtual calls on the type id, lambdas as functions with a context); the runtime (`mojo/rt`) is written in Mojo for
this port, with the C library's printf, strtod, sscanf and stdio carried over from the SWMM5 Mojo port.

    tools/cs2x/build_mojo.sh && dotnet tools/cs2x/bin/cs2mojo.dll cs mojo/gen

writes `mojo/gen/engine.mojo` (one module), `mojo/cs2mojo_runtime.txt` (every runtime member the engine uses, with
the Mojo name it became) and `mojo/cs2mojo_todo.txt` (untranslated constructs: none). It reads `cs/gen` and the
engine's hand-written partial classes `cs/runtime/Hand_*.cs`; the rest of `cs/runtime` is read for its types only.
`mojo/make_primes.sh` writes `mojo/rt/primes.mojo` (libstdc++'s bucket counts) from `cs/runtime/PrimeList.cs`.

## What Mojo 1.2 does not have, and what stands for it

Each of these was found by a probe of a few lines before the translator was written (see `../../lessons/74`, `75`
and swmm5-ports lessons/42 and 43):

- **No classes and no inheritance.** A C# class is a struct; a reference to it is `Ref[T]` (rt/core.mojo), a struct
  holding a raw pointer whose `[]` is the object (`x[].field`), null at address 0. A derived struct's first field is
  its base, `__base`, so an upcast or a downcast is the same address seen as another type (`x.cast[T_Base]()`); the
  root of a hierarchy has a type id `__tid` (numbered from 1000 in the order of the sorted type names), and
  `__tid_parent` and `__isA` are the generated tables for `is`, `as` and catch clauses.
- **No global variables** ("global variables are not supported"). The engine's static fields are the fields of one
  struct, `GS`, and the runtime's state another, `RTS`; both are mapped at fixed addresses at start-up
  (`mmap(MAP_FIXED_NOREPLACE)`), so `gs()[].G_x` is a load from a constant address and no function needs an extra
  parameter. Both blocks are registered with the collector as roots.
- **No function values in struct fields** ("struct fields do not support trait types"). A delegate is `Dlg`, a
  context pointer and a number. Every lambda and method group gets a number, and each Mojo signature a dispatcher
  `__callN(d, args...)` that tests the number and calls the function; a call of a delegate is a call of its
  signature's dispatcher. A runtime function that takes a delegate (`Algo.find_if`, `StdAlgo.Sort`, `Std.call_once`,
  `Defer.dispose_`) takes the dispatcher as a compile-time parameter: `StdAlgo.Sort[T, __call17](a, b, e, cmp)`. The
  runtime's `Less<T>.Fn` is the number -1, which the runtime compares with the element order itself. A container
  constructed with a lambda that makes a C array element (`() => Arr.Make<double>(4)`) is given the length instead.
  Dispatchers and virtual-call functions are `@no_inline`, so that their targets are not copied into every call.
- **The whole engine at Mojo's default -O3 needs more memory than the machine has** (lessons/77): `mojo/build.sh`
  builds at -O2, which needs about a third as much and changes no result.
- **A value's bytes may not be read through the address of a Mojo argument or local** (lessons/78): LLVM may
  never have stored them. The runtime copies such a value onto its own stack first, and boxes a reference through
  `e_word` / `e_of_word`.
- **Mojo's runtime reserves 1 GB regions at random addresses before `main`** (lessons/79), so the two fixed blocks
  (static fields, runtime state) are mapped first thing in `rt_init`, and the program starts itself again if one of
  the addresses is taken.
- **A call with tens of thousands of arguments stalls the compiler** (lessons/75). A C# array initializer of more
  than 16 elements that are all constant zeros (C++ `char buffer[1 << 16]{}`) becomes `Ary[T].make(n)`, a zeroed
  array, and not a call of `Ary[T].of` with every element.
- **No switch, no labelled break, no goto, no block expressions.** A switch is a chain of `if`/`elif`; when a case
  leaves early with `break`, the chain is inside a one-pass `while True:`, and a `continue` that passes through it
  sets a flag, breaks, and continues after it. A `for` repeats its increment before every `continue`; a `do`/`while`
  tests its condition at the bottom and before every `continue`. The one function with `goto` (the UEB reference
  snow model) is a loop over a program counter with its locals declared at the top. An assignment, a compound
  assignment or an increment used as a value, and an object initializer (`new X { a = 1 }`), is a call of a small
  generated function (`__hN`).
- **`mut` arguments are `noalias`** (lessons/74), so a C# `ref` is a raw pointer `P[T]`, and a local whose address
  is taken (passed by ref, bound to a ref local, assigned inside an expression) lives on the runtime's own stack:
  `rt_salloc[T]()` at function entry, given back (`rt_set_sp`) at every return and at every catch. A raw pointer to a
  Mojo stack slot would not be safe either (swmm5-ports lessons/42). A local captured by a lambda lives in a collected
  cell, as in the Zig port.

## Values

- `double`, `float`, the integer types, `bool`, `char`: `Float64`, `Float32`, `Int32`..., `Bool`, `UInt16`. Mojo's
  `+ - *` on fixed-width integers wrap, as C# (unchecked) does; `/` and `%` on signed integers are `rt_idiv` and
  `rt_irem` (Mojo's `//` floors, C# truncates); `%` on doubles is glibc's `fmod`; shifts mask the count
  (`rt_shl`...). Integer and float conversions are `.cast[DType.x]()`; double to integer is `rt_d2int32` and its kin,
  as .NET 8 on x86-64 converts (`cvttsd2si`: NaN and out-of-range values give the minimum), and to `ulong` as the C++
  reference does (lessons/44).
- A double literal is `Float64(<shortest round-trip decimal>)` (Mojo rounds a decimal literal once, as C# does; checked
  on 3,011 values for the SWMM5 port); NaN, the infinities, -0.0 and subnormals are `f64_bits(0x...)`; a float literal
  is always `f32_bits(0x...)` (Mojo's `Float32(1e-45)` is 0).
- An array `T[]` is `Ary[T]`, a value struct of a pointer and a length (a null array has a null pointer): copying it
  copies the reference, as in C#. `string` (only literals and messages) is `CStr`; a string with bytes above 127 is
  written as hexadecimal and decoded at run time (`rt_hex`), because Mojo stores `"\xb3"` as UTF-8. `object` is `Obj`
  (an address; a reference keeps its identity, a value is boxed in a collected cell).
- The runtime's C# structs (`CPtr`, `Ptr<T>`, `Iter<T>`, `MIt<E>`, `CSpan<T>`) are Mojo value structs; its classes
  (`Str`, `Vec<T>`, `UMap<K, V>`, ...) are structs reached through `Ref`. CPtr's indexer is C#'s: it reads a byte as
  a signed char into an `int` and writes the low byte (`p.get(i)`, `p.set(i, v)`).
- Enums are integer aliases with one compile-time constant per member.

## Statements and calls

- Every engine function `raises`. A throw stores the exception object in the runtime's state and raises a Mojo
  `Error` (`raise rt_throw(e)`); `try`/`catch`/`finally` are Mojo's own, a catch clause testing the stored object's
  type id and re-raising when no clause matches. The C++ standard exceptions are runtime kinds 1 to 13, .NET's from
  100.
- Value parameters are `var` parameters (C# may assign them); ref parameters are pointers. Methods are top-level
  functions `<Type>__<method>` with `this: Ref[T]` first, with the parameter-type suffix of the Zig port when a type
  has several methods of one name; free functions are `F_<namespace>__<name>`.
- Runtime calls keep C#'s names and use Mojo's overloading: an instance method is `x[].m(...)` (a runtime class) or
  `x.m(...)` (a runtime struct), a static member `Type.m(...)` with the method's type arguments, a constructor
  `Type.new_(...)`. A ref-returning runtime member returns a pointer, dereferenced with `[]` where the C# reads it.
- `foreach` over an array is an index loop; over a runtime enumeration (`Items()`) a `while it.next():` loop.

## Containers and the element protocol

Mojo has no reflection, but 1.2 has `comptime if conforms_to(T, Trait)` and `comptime if T == Int32`, with the
trait's methods usable inside such a branch. Every engine and runtime class conforms to `EStruct` (how a container
makes, clones, assigns, moves, disposes, compares and hashes it; the defaults are null, identity and address, and the
translator writes the overrides the C# class has: `Clone`, `Assign`, `MoveFrom`, `Dispose`, `CompareTo`), every
non-numeric element type to `ElemOps`, and `elem_copy`, `elem_make`, `elem_eq`, `elem_less` and `elem_hash` dispatch on
the type at compile time, as the Zig runtime does with `@typeInfo`. The engine's own hasher and key-equal of an
`unordered_map<string, V, CiHash, CiEqual>` conform to `KeyHash` and `KeyEq`.

## Memory

The runtime allocates with the Boehm collector (the system's `libgc.so.1`, linked with `-Xlinker`): `GC_malloc` for
anything that may hold a pointer, `GC_malloc_atomic` (zeroed by the runtime) for arrays of numbers. Nothing is freed
by hand. The two fixed blocks and the runtime's stack are registered as roots.
