Lua refuses a `goto` that jumps forward into the scope of a local declared between the jump and the label; declare a block's locals at its start when the block has a label.

The C# engine has seven `goto`s (from the C++), and the Lua translator writes `continue` as `goto contN` and some
`break`s as `goto swN`. Lua 5.4 checks at load time that no `goto` jumps into the scope of a local:

```lua
if bad then goto GT_L10 end
local v___b15 = 0        -- declared after the goto ...
::GT_L10::               -- ... and still in scope at the label
```

`gen/engine.lua` did not load: "jumps into the scope of local 'v___b15'" (in UebReference). A label at the very end of
a block is exempt (the rule counts a label followed only by void statements as outside the scopes), which is why the
`continue` labels never tripped it. The translator now declares, at the start of any block that contains a label, every
local the block declares, and writes the later declarations as assignments (`lua/cs2lua_stats.txt`: "locals
predeclared for a label", 4 blocks). A related limit of the same compiler: at most 200 locals per function, which one
static initializer with a 240-element array of initialized objects exceeded; such an array is now built element by
element, reusing the temporaries.
