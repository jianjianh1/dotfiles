---
name: slurm-job
description: Use when the user is writing, submitting, monitoring, or debugging SLURM batch jobs — keywords include sbatch, srun, squeue, sacct, scontrol, salloc, job array, partition, QoS, or CHPC clusters (notchpeak, kingspeak, lonepeak, granite, ash).
---

# SLURM job authoring

Apply when the user is preparing a job script, picking a partition, diagnosing
a failed job, or asking what command to run on the cluster.

## sbatch directive template

Lead with this skeleton. Tune the values, never re-derive them from scratch:

```bash
#!/usr/bin/env bash
#SBATCH --job-name=<short-tag>          # appears in squeue
#SBATCH --account=<group>               # PI/allocation name
#SBATCH --partition=<partition>         # see "Picking a partition" below
#SBATCH --time=HH:MM:SS                 # wall clock; jobs are killed at the limit
#SBATCH --nodes=1
#SBATCH --ntasks=1                      # = number of MPI ranks
#SBATCH --cpus-per-task=4               # threads per rank (OMP_NUM_THREADS)
#SBATCH --mem=16G                       # or --mem-per-cpu=4G
#SBATCH --output=logs/%x-%j.out         # %x=job name, %j=job id
#SBATCH --error=logs/%x-%j.err
# GPU jobs add:
#SBATCH --gres=gpu:1                    # or gpu:a100:2, gpu:h100:4
# Array jobs add:
#SBATCH --array=0-15%4                  # 16 tasks, ≤4 running concurrently

set -euo pipefail                       # *inside* the job; install.sh is the
                                        # exception that uses set -uo pipefail
module purge
module load <toolchain>                 # e.g. gcc/12 openmpi/4.1 cuda/12

srun ./a.out                            # always srun under SLURM; never bare mpirun
```

Make `logs/` exist (`mkdir -p logs`) before submission — sbatch will refuse if
the output path is invalid.

## Picking a partition (CHPC reference)

| Partition | Use when |
|---|---|
| `notchpeak` (and `notchpeak-shared-short`) | General CPU; short-shared has 8h cap, faster queue |
| `notchpeak-gpu` / `notchpeak-gpu-guest` | A100 / H100 GPUs |
| `kingspeak` / `kingspeak-gpu` | Older CPU/GPU; lower demand |
| `lonepeak` | Memory-fat nodes |
| `granite` | Mixed CPU + GPU |
| `ash` / `ash-shared-short` | Open-queue (no allocation needed); contention varies |

Pick the **lowest-tier partition that fits**; long queues on the big partitions
are the #1 cause of "my job hasn't started yet". Use the
`scripts/chpc-allocs.py` helper (installed as `chpc-allocs` in `~/.local/bin`)
to discover which allocations the user has access to.

## Submitting and monitoring

```bash
sbatch run.slurm                        # submit; prints job id
squeue --me                             # what's mine, pending vs running
squeue -j <jobid>                       # one job
scontrol show job <jobid>               # full record (start time, reason)
scancel <jobid>                         # kill
sacct -j <jobid> --format=JobID,State,Elapsed,MaxRSS,ExitCode
                                        # post-mortem; works after job finishes
```

When a job is stuck in `PD` (pending), check `squeue -j <jobid> --format=%R` —
the reason column explains why (`Resources`, `Priority`, `QOSMaxJobs`, etc.).

## Common failure modes

- **Exit code 9 / OOM**: bump `--mem` or `--mem-per-cpu`. Check actual usage
  with `sacct -j <jobid> --format=JobID,MaxRSS`.
- **`srun: error: PMIX`**: usually a module-mismatch between login node (where
  you compiled) and compute node. Re-build inside an interactive `salloc`.
- **GPU jobs report no CUDA devices**: forgot `--gres=gpu:N` or
  `CUDA_VISIBLE_DEVICES` got nulled by `module purge`.
- **Job killed at TIMEOUT**: SLURM does not warn; add a checkpoint or request
  a `--signal=B:USR1@60` pre-kill signal.

## Interactive sessions

```bash
salloc --account=<group> --partition=<part> --time=1:00:00 \
       --nodes=1 --ntasks=1 --cpus-per-task=4 --gres=gpu:1
# Drops you onto a compute node; same module / env workflow as in a script.
```

Use `salloc` (not `srun --pty bash`) — the latter ties the shell to a single
task and breaks `srun` inside the session.

## See also

- [[chpc-job]] for the CHPC find-alloc → modules → write → submit workflow end to end
- [[gpu-profile]] when the job runs CUDA and the user wants nsys/ncu data
- [[mpi-openmp]] for multi-node MPI sizing
- [[distributed-training]] for PyTorch DDP/FSDP launchers wrapped by srun
- `scripts/chpc-allocs.py` (in this repo) for allocation discovery
