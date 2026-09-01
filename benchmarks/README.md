# Benchmarks

This suite measures where zlua-aot provides value and where native specialization currently loses to LuaJIT. It intentionally keeps correctness, runtime, build latency, and artifact size separate.

## Run

Requirements: Zig, `hyperfine`, and `libluajit-5.1.so.2` (or another library name supported by the launcher).

```sh
# Short local feedback run
./benchmarks/run.sh quick

# Stable runtime samples plus build-latency measurements
./benchmarks/run.sh full

# Save a machine-specific report
BENCH_OUTPUT=benchmarks/results/my-machine.md ./benchmarks/run.sh full

# Use portable C compiler settings instead of -march=native
BENCH_BUILD_MODE=baseline ./benchmarks/run.sh full
```

Do not compare reports without checking their CPU, kernel, Zig version, build mode, and thermal/power conditions. WSL scheduling noise is especially visible in sub-millisecond startup measurements.

## Workloads

### `call-{luajit,hybrid}.lua`

Calls `square_add(x, y) = x*x+y` five million times. This isolates the cost of crossing the Lua/C API boundary for a tiny kernel. The files differ only by the AOT annotation.

### `arithmetic-{luajit,hybrid}.lua`

Calls a fifteen-term arithmetic kernel one million times. This tests whether more native arithmetic can amortize the wrapper, guard, conversion, and trace-exit cost.

### `startup-{native,luajit}.lua`

Runs the same tiny scalar calculation through standalone numeric C and the LuaJIT launcher. The LuaJIT input contains an empty `do end` block solely to make it ineligible for the current whole-chunk numeric subset.

## Methodology

- Paired programs must print identical output before timing begins.
- Runtime artifacts use identical C optimization settings.
- Hybrid and unannotated comparisons use the same generated launcher and installed LuaJIT shared library.
- `hyperfine --shell=none` avoids shell startup overhead.
- The Zig emitter is built once for runtime measurements.
- Full-mode build measurements deliberately invoke the public `zlua-aot` command and therefore include emitter and generated-C compilation.
- Reported LuaJIT speed is not automatically zlua-aot speed: the fallback path delegates optimization to LuaJIT.

These are controlled microbenchmarks, not a claim about all Lua applications. As the native subset gains loops and control flow, add coarse-grained kernels that perform substantial work per Lua-to-native transition.

## Recorded results

Machine-specific historical reports live in [`results/`](results/). They are committed as evidence of project progress, not universal performance guarantees.
