# zlua-aot

A whole-program LuaJIT 2.x / Lua 5.1 compiler driver written in Zig 0.16. It packages a Lua program into a native ARM64 executable, loads the system LuaJIT runtime, initializes the standard libraries and runs the embedded chunk.

This design provides complete LuaJIT language behavior now—including functions, closures, tables, metatables, varargs, coroutines, errors and binary C modules—while leaving room for later native specialization of proven numeric kernels.

> **Honest status:** packaging is ahead-of-time, but Lua execution still uses LuaJIT at runtime. It is not yet ahead-of-time machine-code lowering. Calling this distinction out is important: complete dynamic Lua semantics require a runtime, and LuaJIT provides the selected authoritative behavior.

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

LuaJIT must therefore be installed on the target machine. `RTLD_GLOBAL` is used so Lua C modules loaded by `require` can resolve the expected Lua API symbols. Script arguments are exposed through the Lua 5.1 global `arg` table.

## Examples

- `examples/full.lua` exercises closures, varargs, tables, metamethods, iteration and coroutines.
- `examples/numeric.lua` is a small numeric workload.

## Architecture roadmap

1. **Compatibility backend (complete):** complete language and C-module behavior through system LuaJIT.
2. **Frontend (in progress):** the Zig lexer and recursive-descent parser cover Lua 5.1 syntax and produce an allocator-owned, source-spanned AST. Semantic analysis tracks lexical scopes, declarations and parameters; resolves every name as local, upvalue or global; marks captured symbols; handles initializer visibility and function boundaries; and validates `break`/vararg context. Hierarchical typed expression nodes remain next.
3. **Typed IR:** flow-sensitive types, escape analysis and guards.
4. **Native kernels:** lower stable numeric functions to optimized Zig/LLVM code.
5. **Deoptimization bridge:** fall back to LuaJIT when specialization guards fail.
6. **Profile-guided builds:** collect representative types and specialize for Surface Pro 11 ARM64.
7. **Shared-library mode:** export specialized functions through a LuaJIT FFI/C ABI.

A complete custom runtime, garbage collector, standard library and Lua C API would be a separate multi-year implementation. Reusing LuaJIT gives this project real-world correctness and module compatibility while optimization work proceeds incrementally.

## Current limitations

- Linux/WSL only because the launcher currently uses `dlopen`.
- LuaJIT remains a runtime dependency.
- Embedded source is compiled by LuaJIT when the executable starts; bytecode caching is not implemented yet.
- Cross-compiling with `native-cpu` is inappropriate; use `baseline` for portable builds.
