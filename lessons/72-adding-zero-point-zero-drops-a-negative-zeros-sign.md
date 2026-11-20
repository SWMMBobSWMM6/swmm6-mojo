Writing `x + 0.0` to make a Lua number a float turns -0.0 into +0.0; use `x * 1.0`, or nothing where the value is a float already.

In Lua 5.4 an integer and a float are different subtypes, and some library functions behave differently on integers
(`math.fmod(7, 2)` is an integer remainder, `math.fmod(7.0, 2)` C's fmod). The Lua runtime's first `LibM_fmod` made
sure of floats with

```lua
function LibM_fmod(x, y) return m_fmod(x + 0.0, y + 0.0) end
```

which is wrong for a negative zero: in IEEE arithmetic (round to nearest) `-0.0 + 0.0` is `+0.0`, so `fmod(-0.0, 1.0)`
came back `+0.0` where glibc gives `-0.0`. The libm test vectors (`lua/test/mkextra.c`) found it: 26 of 21,156 fmod
cases, all with x = -0.0. `x * 1.0` keeps the sign of every float, zero included, and converts an integer; the
translator's own `(x + 0.0)`, which it writes where a C# int becomes a double, is safe, since an integer has no
negative zero.
