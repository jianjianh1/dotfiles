---
name: cpp-profile
description: Use when the user is profiling C or C++ code on Linux — invoking perf (record/report/stat/top/annotate/c2c), callgrind / KCachegrind, heaptrack, valgrind massif, gprof, HPCToolkit, Score-P, Tracy, uftrace, or generating flame graphs with stackcollapse-perf / flamegraph.pl / inferno. Covers compile-flag setup (-O2 -g -fno-omit-frame-pointer), DWARF vs frame-pointer unwinding, perf_event_paranoid, and reading hardware-counter reports.
---

# C/C++ profiling on Linux (perf first, then targeted)

Apply when the user asks why a native binary is slow, what `perf record`
output means, or how to read a flame graph or callgrind file.

## Compile for profiling, first

Non-negotiable for any meaningful profile:

```
-O2 -g -fno-omit-frame-pointer
```

- `-O2` keeps the program close to production behavior. `-O0` profiles a
  *different* program — inliner off, no register allocation, allocator
  patterns differ. Avoid unless you're debugging correctness.
- `-g` ships DWARF debug info so symbols and source lines resolve. Strip
  later for shipping; keep for profiling.
- `-fno-omit-frame-pointer` lets `perf --call-graph fp` walk the stack
  cheaply. Without it, you need DWARF unwinding (slower, larger captures).
  Caveat: this flag only helps if **every library on the call stack** was
  built with frame pointers. On Rocky/Alma/RHEL 8-9 (most enterprise HPC,
  CHPC included) glibc and libstdc++ still ship without them, so
  `--call-graph fp` truncates at the first libc frame. Fedora 38+ reversed
  the distro default but that has not propagated to enterprise images. On
  those hosts, prefer `--call-graph dwarf,N` as the default.
- `-O3` is fine but aggressive inlining hides hot functions in their
  callers. If frames vanish, fall back to `-O2` or `-fno-inline-functions`
  on the suspect translation unit only.

`gprof` (with `-pg`) is largely superseded by `perf` and is here only
because some HPC sites still ship it. Don't recommend it as a default.

## The two-tool workflow

1. **First — `perf record` + flame graph** on the whole binary. Sampling,
   1-3 % overhead, no code change beyond debug info.
2. **Second — `callgrind` or `perf annotate`** on the hot function found in
   step 1. Callgrind gives exact instruction counts via KCachegrind; `perf
   annotate <symbol>` overlays sample counts on disassembly.

Don't start with callgrind — it slows the program 20-100× and you'll
profile a workload that no longer resembles production.

## `perf` recipes

```bash
# Record (frame-pointer build)
perf record -F 999 -g --call-graph fp -o perf.data -- ./a.out

# Record (no frame pointers — e.g. vendor binary, distro libs)
perf record -F 999 -g --call-graph dwarf,16384 -o perf.data -- ./a.out

# Read the report
perf report -i perf.data                      # TUI, sortable
perf annotate -i perf.data symbol_name        # source/asm overlay

# Hardware counters — no profile, just totals
perf stat -e cycles,instructions,cache-references,cache-misses,branch-misses ./a.out
perf stat -e LLC-loads,LLC-load-misses ./a.out

# Live attach (-fn = full-cmdline match, newest single PID; plain `pgrep my-app`
# matches the 15-char comm and can return multiple PIDs that break `-p`)
perf top -p $(pgrep -fn my-app)

# Flame graph pipeline (install once: git clone https://github.com/brendangregg/FlameGraph
# and add to PATH — these scripts are not packaged on most distros)
perf script -i perf.data | stackcollapse-perf.pl | flamegraph.pl > flame.svg
# Or the Rust port (cargo install inferno; no Perl dep):
perf script -i perf.data | inferno-collapse-perf | inferno-flamegraph > flame.svg

# Compare two runs
perf diff before.data after.data
```

Notes:

- `-F 999` (not 1000) avoids beat-frequency aliasing with periodic timers.
  Drop to `-F 99` for many-rank MPI jobs (>16 ranks) — aggregate sample
  rate scales with ranks, and per-rank `perf.data` files at 999 Hz routinely
  hit 1-2 GB each, filling scratch and triggering "lost samples" on the ring
  buffer.
- `--call-graph dwarf,16384` raises the per-sample stack-copy size; default
  8 KB truncates deep C++ template stacks. For very deep stacks (Eigen,
  Kokkos, RAJA) you may need up to `,65528`, at ~4-8× larger `perf.data`.
- On shared nodes `perf record` may fail with "permission denied" — check
  `cat /proc/sys/kernel/perf_event_paranoid`. Kernel semantics:
  `-1` = unrestricted, `0` = no raw tracepoints, `1` = no kernel-symbol
  resolution, `2` = no kernel profiling (typical default, **does** allow
  user-space CPU sampling). Debian and Ubuntu ship a downstream patch where
  `3` (Debian default) or `4` (Ubuntu 22.04+ default) blocks unprivileged
  `perf_event_open` entirely — that's the most common EACCES cause on those
  distros. Don't lower the system value
  yourself; ask the sysadmin or run on a less restrictive partition.

## Callgrind + KCachegrind

```bash
valgrind --tool=callgrind --collect-jumps=yes --dump-instr=yes ./a.out
kcachegrind callgrind.out.<pid>
```

- Slowdown 20-100× — use on a tiny representative workload.
- Skip warm-up with `--instr-atstart=no` and bracket the region with
  `CALLGRIND_START_INSTRUMENTATION` / `CALLGRIND_STOP_INSTRUMENTATION`
  (from `<valgrind/callgrind.h>`).
- Use for **exact call counts** and **cycle-accurate instruction cost**
  per call site — the two things sampling can't give you.

## Cache and microarchitecture

```bash
# Cache behavior with real hardware counters
perf stat -e cache-references,cache-misses,LLC-loads,LLC-load-misses ./a.out

# Cache simulation when counters aren't available (containers, VMs)
valgrind --tool=cachegrind ./a.out
cg_annotate cachegrind.out.<pid>

# False sharing across cores
perf c2c record ./a.out
perf c2c report
```

## Memory profiling

- **`heaptrack`** — default recommendation for allocation profiling.
  ```bash
  heaptrack ./a.out                            # writes heaptrack.a.out.<pid>.zst (or .gz on systems without zstd)
  heaptrack_gui    heaptrack.a.out.<pid>.zst   # interactive
  heaptrack_print --print-flamegraph flame.txt heaptrack.a.out.<pid>.zst
  flamegraph.pl < flame.txt > heap-flame.svg
  ```
- **`valgrind --tool=massif`** — heap snapshots over time, shows peak
  growth shape:
  ```bash
  valgrind --tool=massif --time-unit=B ./a.out
  ms_print massif.out.<pid>
  ```
- **`valgrind --tool=memcheck`** is for *correctness* (leaks, invalid
  reads), not performance. Don't reach for it when asked "why is memory
  high?" — use heaptrack or massif.
- **AddressSanitizer** (`-fsanitize=address`) detects bugs at runtime; not
  a profiler.

## HPC-specific tooling

For codes that span MPI ranks, OpenMP threads, or GPU offload, single-node
`perf` runs out of structure. Use:

- **HPCToolkit** — sampling, scales to thousands of MPI ranks.
  ```bash
  hpcrun -e CPUTIME -o measurements ./a.out
  hpcstruct ./a.out
  hpcprof -S a.out.hpcstruct -I ./src/+ measurements
  hpcviewer hpctoolkit-a.out-database
  ```
- **Score-P + Scalasca / Vampir / Cube** — instrumented MPI/OpenMP
  profiling and tracing. Wrap the compile line:
  ```bash
  scorep mpicxx -O2 -g -fopenmp -o a.out main.cpp
  scalasca -analyze srun -n 64 ./a.out
  ```
- **TAU** — alternative to Score-P, still used on some sites.
- **Tracy** — frame-by-frame instrumentation, very low overhead; great for
  long-running simulations where you want to see per-iteration cost.
- **uftrace** — function-call tracing with `-pg` or `-finstrument-functions`;
  useful when you want exact call sequences and callgrind is too slow. Scope
  with `--filter` / `--depth=N` — full instrumentation hooks every call and
  can be slower than callgrind on heavily-templated C++ (Eigen, Kokkos),
  with traces that grow into the tens of GB.

## Symptom → likely cause

| Symptom in the report | Likely cause |
|---|---|
| Top sample in `__memcpy_avx_unaligned` or `__memset_avx2` | Memory-bound — check access patterns, consider `restrict`, blocking, or in-place ops |
| High `cache-misses` per instruction, low `instructions/cycle` | Poor locality — tile loops, transpose matrices, use AoSoA |
| `perf` shows `[unknown]` or huge anonymous frames | Missing frame pointers or stripped symbols — recompile with `-fno-omit-frame-pointer -g`, or use `--call-graph dwarf` |
| Massive `branch-misses` rate (> 5 %) | Unpredictable branch — sort input, branchless code, or `__builtin_expect` if the bias is real |
| Hot function in `perf` is a small inlined helper | Inlining merged it with its caller — try `-fno-inline-functions-called-once` on the TU to see real attribution |
| `heaptrack` shows flat allocation rate but huge peak | One big allocation, not a leak — look at object lifetime, not count |
| Callgrind hot function never appears in `perf` | Function is fast but called billions of times — perf samples can't catch it; switch to callgrind, uftrace, or Tracy |
| `perf c2c` reports HITM events | False sharing — pad structs to a cache line (`alignas(64)`) or split per-thread state |
| `perf stat` shows IPC < 0.5 on compute kernel | Front-end or memory stall — check `perf stat -e stalled-cycles-frontend,stalled-cycles-backend` |
| MPI program: rank 0 fast, others slow in `MPI_Wait` | Load imbalance — profile each rank with HPCToolkit or per-rank `srun bash -c 'perf record -o perf.${SLURM_PROCID}.data ./a.out'` (the `bash -c` defers `$SLURM_PROCID` expansion until each task's shell) |

## Quick-fire cheat sheet

```bash
# Live top of a running PID
perf top -p $(pgrep -fn my-app)

# Flame graph in one pipeline (swap `fp` for `dwarf,16384` on enterprise distros
# where glibc/libstdc++ lack frame pointers — see "Compile for profiling")
perf record -F 999 -g --call-graph fp -- ./a.out && \
  perf script | stackcollapse-perf.pl | flamegraph.pl > flame.svg

# Diff before/after an optimization
perf record -o before.data -- ./a.out-old
perf record -o after.data  -- ./a.out-new
perf diff before.data after.data

# Per-rank profile under SLURM (bash -c defers $SLURM_PROCID expansion to each
# task's shell; without it the parent expands once and every task clobbers the
# same file)
srun bash -c 'perf record -F 99 -g -o perf.${SLURM_PROCID}.data -- ./a.out'

# Check whether perf can sample at all (≤ 2 on most distros; Debian/Ubuntu
# ship 3 or 4 — needs a sysadmin to lower)
cat /proc/sys/kernel/perf_event_paranoid

# Allocation flame graph (heaptrack writes .zst on modern distros, .gz otherwise)
heaptrack ./a.out && \
  heaptrack_print --print-flamegraph fg.txt heaptrack.a.out.*.zst && \
  flamegraph.pl < fg.txt > heap-flame.svg
```

## See also

- [[mpi-openmp]] — for MPI rank profiling, use Score-P or per-rank `srun bash -c 'perf record -o perf.${SLURM_PROCID}.data ...'`
- [[gpu-profile]] — `perf` only sees the host; if the C++ binary launches CUDA, hand off to nsys/ncu
- [[cuda-kernels]] — when the hot spot turns out to be on the device, not in C++
- [[slurm-job]] — submitting profiling runs; reserve enough memory for `perf.data` and `heaptrack` output (both can hit gigabytes)
- [[python-profile]] — symmetrical Python case; useful when `py-spy --native` points back at a C extension
