#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
workloads="$root/benchmarks/workloads"
mode=${1:-quick}
build_mode=${BENCH_BUILD_MODE:-native-cpu}
output=${BENCH_OUTPUT:-}

case "$mode" in
  quick|full) ;;
  *) echo "usage: benchmarks/run.sh [quick|full]" >&2; exit 2 ;;
esac
case "$build_mode" in
  native-cpu|baseline) ;;
  *) echo "BENCH_BUILD_MODE must be native-cpu or baseline" >&2; exit 2 ;;
esac
command -v zig >/dev/null || { echo "zig is required" >&2; exit 127; }
command -v hyperfine >/dev/null || { echo "hyperfine is required" >&2; exit 127; }

scratch=$(mktemp -d "${TMPDIR:-/tmp}/zlua-bench.XXXXXX")
trap 'rm -rf "$scratch"' EXIT INT TERM

if [[ -n "$output" ]]; then
  mkdir -p "$(dirname -- "$output")"
  exec > >(tee "$output") 2>&1
fi

printf '# zlua-aot benchmark run\n\n'
printf -- '- Date: %s\n' "$(date --iso-8601=seconds)"
printf -- '- Kernel: `%s`\n' "$(uname -a)"
printf -- '- Zig: `%s`\n' "$(zig version)"
printf -- '- Mode: `%s`\n' "$mode"
printf -- '- C build mode: `%s`\n\n' "$build_mode"

# Compile the Zig emitter once. Rebuilding it for every workload would measure
# the shell wrapper rather than the generated programs' runtime behavior.
emitter="$scratch/zlua-emit"
zig build-exe "$root/src/main.zig" -O ReleaseFast -femit-bin="$emitter"

compile_program() {
  local source=$1
  local binary=$2
  local c_source="$scratch/$(basename "$binary").c"
  "$emitter" "$source" "$c_source"
  if [[ "$build_mode" == native-cpu ]]; then
    zig cc -O3 -march=native -flto "$c_source" -ldl -o "$binary"
  else
    zig cc -O2 "$c_source" -ldl -o "$binary"
  fi
}

for name in call-luajit call-hybrid arithmetic-luajit arithmetic-hybrid startup-native startup-luajit; do
  compile_program "$workloads/$name.lua" "$scratch/$name"
done

verify_pair() {
  local left=$1 right=$2 left_output right_output
  left_output=$("$scratch/$left")
  right_output=$("$scratch/$right")
  if [[ "$left_output" != "$right_output" ]]; then
    printf 'output mismatch: %s=%q, %s=%q\n' "$left" "$left_output" "$right" "$right_output" >&2
    exit 1
  fi
  printf -- '- `%s` and `%s`: `%s`\n' "$left" "$right" "$left_output"
}

printf '## Correctness check\n\n'
verify_pair call-luajit call-hybrid
verify_pair arithmetic-luajit arithmetic-hybrid
verify_pair startup-native startup-luajit

printf '\n## Runtime\n\n'
if [[ "$mode" == full ]]; then
  warmup=10; runs=50; startup_warmup=20; startup_runs=500
else
  warmup=3; runs=10; startup_warmup=5; startup_runs=50
fi
hyperfine -N --warmup "$warmup" --runs "$runs" "$scratch/call-luajit" "$scratch/call-hybrid"
hyperfine -N --warmup "$warmup" --runs "$runs" "$scratch/arithmetic-luajit" "$scratch/arithmetic-hybrid"
hyperfine -N --warmup "$startup_warmup" --runs "$startup_runs" "$scratch/startup-native" "$scratch/startup-luajit"

printf '\n## Artifact sizes\n\n```text\n'
for name in call-luajit call-hybrid arithmetic-luajit arithmetic-hybrid startup-native startup-luajit; do
  printf '%-20s %8d bytes\n' "$name" "$(stat -c %s "$scratch/$name")"
done
printf '```\n'

if [[ "$mode" == full ]]; then
  printf '\n## Build latency\n\n'
  printf 'Each command includes rebuilding the Zig emitter and compiling generated C.\n\n```text\n'
  for name in startup-native call-hybrid call-luajit; do
    /usr/bin/time -f "$name elapsed=%e s user=%U s system=%S s max-rss=%M KB" \
      "$root/zlua-aot" "$workloads/$name.lua" "$scratch/build-$name" "$build_mode" >/dev/null
  done
  printf '```\n'
fi
