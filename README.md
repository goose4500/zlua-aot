# zlua-aot

A hybrid LuaJIT 2.x / Lua 5.1 AOT compiler written in Zig 0.16. It conservatively lowers eligible scalar-numeric chunks and annotated numeric functions to native machine code while routing dynamic operations through the complete LuaJIT compatibility backend.

The numeric backend emits no Lua source, bytecode, or VM dependency. Dynamic programs retain functions, closures, tables, metatables, varargs, coroutines, errors and binary C modules through LuaJIT.

The selected backend is reported as `native-numeric`, `hybrid-functions`, or `luajit-fallback`. Native eligibility deliberately fails closed whenever the compiler cannot prove that direct C `double` operations preserve the supported Lua semantics.

An initial mixed program can annotate a global numeric function:

```lua
--@aot-number
function square_add(x, y)
    return x * x + y
end

print({ result = square_add(4, 2) })
```

The generated Lua C wrapper checks the exact argument count and number types. A failed guard calls the preserved original Lua function.

## Build a program

```sh
chmod +x zlua-aot
./zlua-aot examples/full.lua full native-cpu
./full hello
```

Options:

```text
./zlua-aot INPUT.lua OUTPUT [native-cpu|baseline]
```

- `native-cpu` uses `-O3 -march=native -flto`, appropriate for the local Surface Pro 11 ARM64 CPU.
- `baseline` creates a less machine-specific executable.
- The Zig emitter is cached under `$XDG_CACHE_HOME/zlua-aot`.

## Runtime compatibility

Generated programs dynamically resolve the Lua 5.1 C ABI from, in order:

1. `libluajit-5.1.so.2`
2. `libluajit-5.1.so`
3. `libluajit.so`

LuaJIT is required only for programs selecting the fallback backend. `RTLD_GLOBAL` is used so Lua C modules loaded by `require` can resolve the expected Lua API symbols. Script arguments are exposed through the Lua 5.1 global `arg` table.

## Examples

- `examples/full.lua` exercises closures, varargs, tables, metamethods, iteration and coroutines.
- `examples/numeric.lua` is a small whole-chunk numeric workload.
- `examples/hybrid.lua` calls a guarded native function from dynamic Lua and tests its Lua fallback.

## Architecture roadmap

1. **Compatibility backend (complete):** complete language and C-module behavior through system LuaJIT.
2. **Frontend (in progress):** the Zig lexer and recursive-descent parser cover Lua 5.1 syntax and produce an allocator-owned, source-spanned AST. Semantic analysis tracks lexical scopes, declarations and parameters; resolves every name as local, upvalue or global; marks captured symbols; handles initializer visibility and function boundaries; and validates `break`/vararg context. Hierarchical typed expression nodes remain next.
3. **Typed native numeric IR (complete initial pass):** eligible chunks are parsed into allocator-owned symbol, statement, unary-expression and precedence-aware binary-expression nodes. Every IR value is proven numeric before recursive native emission; unsupported input produces no partial output.
4. **Function kernels (initial vertical slice):** `--@aot-number` global functions with a numeric return expression lower to native implementations and guarded Lua C wrappers. Dynamic callers remain in LuaJIT, and failed guards invoke the preserved Lua body. Locals and control flow remain future extensions.
5. **Deoptimization bridge:** fall back to LuaJIT when specialization guards fail.
6. **Profile-guided builds:** collect representative types and specialize for Surface Pro 11 ARM64.
7. **Shared-library mode:** export specialized functions through a LuaJIT FFI/C ABI.

A complete custom runtime, garbage collector, standard library and Lua C API would be a separate multi-year implementation. Reusing LuaJIT gives this project real-world correctness and module compatibility while optimization work proceeds incrementally.

## Current limitations

- Linux/WSL only because the launcher currently uses `dlopen`.
- Dynamic fallback programs require LuaJIT; native-numeric programs do not.
- Fallback source is compiled by LuaJIT when the executable starts; bytecode caching is not implemented yet.
- Whole-chunk lowering supports conservative scalar arithmetic. Mixed function lowering currently accepts parameters and one numeric return expression; function locals and control flow are not yet supported.
- Cross-compiling with `native-cpu` is inappropriate; use `baseline` for portable builds.
