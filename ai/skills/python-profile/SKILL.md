---
name: python-profile
description: Use when the user is profiling Python code — invoking cProfile, pyinstrument, py-spy, scalene, line_profiler, memray, tracemalloc, snakeviz, or interpreting .prof / .speedscope / .memray reports, call trees, flame graphs, or per-line CPU and memory breakdowns.
---

# Python profiling (sampling first, then targeted)

Apply when the user asks why Python is slow, where it allocates, or what a
`.prof` / flame graph / `memray` report means.

## The two-tool workflow

1. **First — sampling profiler** for whole-app wall-clock cost.
   - `pyinstrument` when you control the script (low overhead, call-tree view).
   - `py-spy` when the process is already running, in a container, or under
     SLURM (no code change, attaches by PID).
2. **Second — targeted deep-dive** on the 1-3 hot spots found above.
   - `line_profiler` for per-line CPU within a function.
   - `memray` for allocation profiling.
   - `scalene` if you want CPU + memory + GPU-aware in one shot.

Do **not** start with `cProfile`. Deterministic profilers trace every call
and distort small-call-heavy code (NumPy, asyncio, lots of `getattr`).
Keep `cProfile` for a single algorithm or a focused script where you need
exact call counts, not whole-app triage.

## Recording recipes

```bash
# pyinstrument — in-process, prints a call tree on exit
python -m pyinstrument -o report.html -r html script.py

# py-spy — attach to a running process, no code change
# (-fn = full-cmdline match, newest single PID; plain `pgrep my-app` matches
# only the 15-char comm and can return multiple PIDs that break `--pid`)
py-spy record -o flame.svg --pid $(pgrep -fn my-app)
py-spy top  --pid $(pgrep -fn my-app)        # live top-style view
py-spy record -o flame.svg --subprocesses --native -- python script.py

# cProfile + snakeviz — when you actually want call counts
python -m cProfile -o run.prof script.py
snakeviz run.prof                            # browser-based call tree

# line_profiler — decorate hot functions with @profile, then:
kernprof -l -v script.py                     # writes script.py.lprof

# scalene — CPU + memory + GPU; modern scalene uses verb subcommands
scalene run script.py                        # writes scalene-profile.json
scalene view --html                          # writes scalene-profile.html
```

Flags worth knowing:

- `py-spy --subprocesses` — follows `multiprocessing` / `concurrent.futures` workers.
- `py-spy --native` — unwinds C frames so NumPy / PyTorch / Cython aren't `<built-in>`.
- `py-spy --idle` — include threads not actively running Python (filtered by default). Needed when wall time is dominated by `time.sleep` or blocking I/O — py-spy otherwise drops those threads from the sample and the flame graph looks empty.
- `pyinstrument` async attribution is API-only — call `Profiler(async_mode="strict")` from Python; there is no `--async-mode` CLI flag.
- `pyinstrument -o profile.speedscope -r speedscope` — open at `speedscope.app` for flame graphs.

## Memory profiling

```bash
memray run -f -o out.bin script.py           # -f / --force overwrites; without it the second run aborts
memray flamegraph out.bin                    # → memray-flamegraph-out.html
memray tree      out.bin                     # text tree of allocations
memray stats     out.bin                     # peak / total / call sites
memray run --live script.py                  # interactive TUI
memray run -f --trace-python-allocators -o out.bin script.py   # see PyObject mallocs (heavy — output files 5-20× larger; use only when default mode misses small-object allocations)
```

Use `tracemalloc` (stdlib) as the dependency-free fallback for snapshot diffs:

```python
import tracemalloc; tracemalloc.start()
# … warm-up …
before = tracemalloc.take_snapshot()
# … suspect workload …
after = tracemalloc.take_snapshot()
for stat in after.compare_to(before, "lineno")[:20]:
    print(stat)
```

Leak vs high-watermark: a leak's **peak / resident memory** climbs
monotonically across iterations of the same workload (re-run `memray stats`
per iteration and compare, or watch RSS); a high-watermark workload returns
to baseline between iterations. The `total` field in `memray stats` is
cumulative allocations and always grows — don't use it as the leak signal.
Different fixes — eviction policy vs. peak-allocation reduction.

## Async, multiprocess, and native-extension gotchas

- **asyncio**: `cProfile` attributes time to the event-loop machinery, not your
  coroutine. Use `pyinstrument` via the Python API with `Profiler(async_mode="strict")`, or `py-spy`.
- **multiprocessing / `concurrent.futures`**: `py-spy record --subprocesses`
  follows children; `pyinstrument` needs to be started in each worker via
  `Profiler().start()` / `.stop()`.
- **C extensions** (NumPy, pandas, PyTorch, Cython): without `--native`, time
  vanishes into `<built-in method>`. Install debug symbols for the extension
  (`numpy-dbg`, `python3-dbg`) or `py-spy` will still show `<unknown>` frames.
- **PyTorch / CUDA workloads**: Python profilers see the host launch, not the
  kernel. Hand off to `torch.profiler` and [[gpu-profile]] once you've
  confirmed the bottleneck is on the GPU.

## Symptom → likely cause

| Symptom in the report | Likely cause |
|---|---|
| Most time in `<built-in method builtins.exec>` or `_bootstrap._find_and_load` | Import cost dominates — profile after imports complete, or warm up first |
| Time in `_thread._lock.acquire` / `Lock.acquire` | GIL contention or a thread blocked on a C call that didn't release it — try `multiprocessing` or release the GIL in the extension |
| pyinstrument shows huge time in `select` / `epoll_wait` | I/O wait, not CPU — switch to `pyinstrument --show-all` or `py-spy --idle` |
| py-spy shows `<unknown>` frames | Missing debug symbols; install `*-dbg` packages or use a non-stripped Python build |
| cProfile times don't add up to wall time | Blocking I/O outside Python — cProfile only sees Python frames, use a sampling profiler |
| `memray` peak (or process RSS) grows across identical iterations | Real leak — caches without eviction, circular refs holding C objects, or `lru_cache` without `maxsize`. Don't read `total` here — it is cumulative and always grows. |
| `memray` peak huge, returns to baseline | High-watermark workload — load in chunks, use generators, or `dtype=` downcasts in NumPy |
| Hot frame is `numpy.core._methods._sum` on a small array | Per-call NumPy overhead beats vectorization — batch or switch to plain Python for tiny shapes |

## Quick-fire cheat sheet

```bash
# Attach to whatever's pegging the CPU right now (replace `python` with the
# script name if a pylsp / Jupyter kernel might also be running)
py-spy top --pid $(pgrep -fn python)

# One-shot flame graph of a SLURM job: prefer $SLURM_TASK_PID inside the
# task; fall back to pgrep on the compute node from a parent shell
py-spy record -o flame.svg --subprocesses --native \
    --pid "${SLURM_TASK_PID:-$(pgrep -fn python)}"

# Compare two pyinstrument runs side-by-side in speedscope.app
python -m pyinstrument -o a.speedscope -r speedscope before.py
python -m pyinstrument -o b.speedscope -r speedscope after.py
# load both at https://speedscope.app/

# Find which line of which function allocates the most
memray run -f -o m.bin script.py && memray flamegraph m.bin
```

Profile only the interesting block from inside Python:

```python
from pyinstrument import Profiler
with Profiler() as p:
    heavy_work()
print(p.output_text(unicode=True, color=True))
```

## See also

- [[gpu-profile]] — for PyTorch / CUDA, hand off after the Python view
- [[distributed-training]] — profile rank 0 with `py-spy --pid` after `torchrun`
- [[slurm-job]] — `py-spy` needs `ptrace` capability; some CHPC partitions restrict it (check `cat /proc/sys/kernel/yama/ptrace_scope`)
- [[scientific-io]] — if time vanishes into `h5py` / `netCDF4`, the bottleneck is I/O, not Python
- [[cpp-profile]] — when `py-spy --native` shows a C extension as the hot frame, profile the extension as a C/C++ library
