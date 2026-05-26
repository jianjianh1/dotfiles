---
name: mpi-openmp
description: Use when the user is writing or debugging MPI, OpenMP, or hybrid MPI+OpenMP code — keywords include MPI_Init, MPI_Comm, MPI_Bcast/Reduce/Allreduce, MPI_Send/Recv, ranks, communicators, deadlock, pragma omp, OMP_NUM_THREADS, affinity, NUMA, srun/mpirun, hybrid programming.
---

# MPI & OpenMP parallel programming

Apply for both pure-MPI and hybrid MPI+OpenMP work. CPU-side parallelism;
distributed ML uses [[distributed-training]] instead.

## MPI program skeleton

```c
#include <mpi.h>
#include <stdio.h>

int main(int argc, char **argv) {
    int provided;
    /* Use MPI_THREAD_FUNNELED if only the main thread calls MPI;
       MPI_THREAD_SERIALIZED if any thread can but not concurrently;
       MPI_THREAD_MULTIPLE if multiple threads can — slowest, rarely needed. */
    MPI_Init_thread(&argc, &argv, MPI_THREAD_FUNNELED, &provided);

    int rank, size;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);

    /* … work … */

    MPI_Finalize();
    return 0;
}
```

Always check `provided >= requested`; some MPIs silently downgrade.

## Communication patterns: pick the right primitive

| Need | Primitive | Cost |
|---|---|---|
| One→all of same data | `MPI_Bcast` | O(log P) tree |
| All→one combine | `MPI_Reduce` | O(log P) |
| All→all combine | `MPI_Allreduce` | O(log P) — but synchronizes |
| Distinct piece to each | `MPI_Scatter` / `MPI_Scatterv` | O(P) latency |
| Gather distinct pieces | `MPI_Gather` / `MPI_Gatherv` | O(P) |
| Pairwise, known partner | `MPI_Send` + `MPI_Recv` | direct |
| Pairwise, unknown order | `MPI_Isend` / `MPI_Irecv` + `Waitall` | needed for halo exchange |

**Always prefer collectives over hand-rolled loops of point-to-point.** A
single `MPI_Allreduce` is faster *and* clearer than `O(P)` `MPI_Send`s in a
ring.

## Avoiding deadlocks

The textbook deadlock:

```c
// rank 0 and rank 1 both do this, blocking send first
MPI_Send(buf, n, MPI_DOUBLE, partner, 0, comm);
MPI_Recv(buf, n, MPI_DOUBLE, partner, 0, comm, &status);  // never reaches
```

`MPI_Send` is allowed to block until a matching `Recv`. Fix patterns:

1. **`MPI_Sendrecv`** — atomically pair, no deadlock.
2. **Even/odd schedule** — even ranks send-then-recv, odd ranks recv-then-send.
3. **Non-blocking** — `MPI_Isend` + `MPI_Irecv` + `MPI_Waitall`. Best for halo
   exchanges; lets the MPI runtime schedule.

## Hybrid MPI+OpenMP

Typical layout: one MPI rank per NUMA domain (often per socket), OpenMP
threads inside the rank.

```bash
# Slurm: 2 nodes × 2 ranks/node × 16 threads/rank = 64 threads total
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=2
#SBATCH --cpus-per-task=16
export OMP_NUM_THREADS=$SLURM_CPUS_PER_TASK
export OMP_PROC_BIND=close
export OMP_PLACES=cores
srun --cpu-bind=cores ./hybrid_app
```

`OMP_PROC_BIND=close` keeps threads adjacent (good for shared L2/L3);
`OMP_PROC_BIND=spread` distributes across NUMA nodes (good for memory-bound
where you want bandwidth). `OMP_PLACES=cores` pins to physical cores; use
`threads` only on apps that benefit from SMT (rare for HPC).

Verify binding with `srun --cpu-bind=verbose,cores ./hybrid_app | head` — it
prints the actual mask per rank.

## OpenMP pragma cheat sheet

```c
#pragma omp parallel for schedule(static) reduction(+:sum)
for (int i = 0; i < n; ++i) sum += a[i] * b[i];

#pragma omp parallel for collapse(2)              // flatten 2 nested loops
for (int i = 0; i < ni; ++i)
    for (int j = 0; j < nj; ++j) work(i, j);

#pragma omp parallel for schedule(dynamic, 64)    // for irregular workloads
for (int i = 0; i < n; ++i) variable_cost(i);

#pragma omp simd                                  // hint vectorization
for (int i = 0; i < n; ++i) c[i] = a[i] + b[i];
```

- `schedule(static)` is the default — equal chunks, no overhead. Use
  `dynamic` only when iteration cost varies a lot; chunk size 64-256 keeps
  scheduling overhead bounded.
- `reduction(+:sum)` is essential — without it, you get a data race or
  serialized atomics.
- `firstprivate`, `lastprivate`, `shared` to control variable scoping in
  the parallel region.

## Debugging tips

- **Attach gdb to one rank**: `srun -N1 -n1 --ntasks=1 xterm -e gdb -p $(pgrep
  -n a.out)`, or compile with `-g` and use `MPI_Abort(MPI_COMM_WORLD, rank)`
  to halt a specific rank for inspection.
- **`MPI_Errhandler_set(comm, MPI_ERRORS_RETURN)`** — by default MPI aborts
  on error. Setting this gives you an error code to inspect instead.
- **Print from rank 0 only** to keep logs readable:
  `if (rank == 0) printf(...);`
- **Race conditions in OpenMP**: build with `-fsanitize=thread` (gcc/clang)
  for development runs. ThreadSanitizer finds most races.

## See also

- [[slurm-job]] for sbatch with `--ntasks` / `--cpus-per-task`
- [[hpc-perf]] for scaling studies (strong vs weak) and profiling MPI apps
- [[scientific-io]] if the bottleneck is I/O rather than compute or comm
