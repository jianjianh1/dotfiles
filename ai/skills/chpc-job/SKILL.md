---
name: chpc-job
description: Use when the user is launching work on a CHPC cluster (notchpeak, kingspeak, lonepeak, granite, ash) and needs the full path — find a runnable allocation, load the right modules, write the sbatch script, then submit and monitor it. Triggers on "what allocation can I use", "which partition/account/qos", "set up modules for", "write and run an sbatch job on CHPC", or "submit this on notchpeak". For generic SLURM mechanics off CHPC, use slurm-job instead.
---

# Running a job on CHPC, end to end

Apply when the user wants to *get something running* on a CHPC cluster, not just
patch one directive. Walk these four steps in order — each feeds the next.

```
[ ] 1. inventory, then choose a runnable allocation (mychpc batch → chpc-allocs)
[ ] 2. choose the right modules     (module spider → load, compiler before MPI)
[ ] 3. write the sbatch script      (seed it with the triple from step 1)
[ ] 4. submit and monitor           (sbatch → squeue --me → seff)
```

Copy that checklist into your reply and tick items off as you go.

## 1. Find a runnable allocation

The **allocation** is the `account` / `partition` / `qos` triple. First get every
current option from CHPC, then compare all options compatible with the job:

```bash
mychpc batch                         # CHPC's complete personalized list
chpc-allocs --quick --format table    # complete inventory with exact partitions
chpc-allocs --show-all 'a100:4@8h'    # every compatible option, including unknown waits
chpc-allocs --best 'a100:4@8h'        # one choice after inspecting the list
```

The helper uses `mychpc batch` for its inventory and `sbatch --test-only` for
wait checks; nothing is submitted. `--best` returns only one option, so do not
use it as the inventory. Data-transfer partitions are not compute options.
If the official command or helper fails, report that completeness could not be
verified. Never fill gaps from saved account examples.
The full request grammar (GPU/CPU atoms, walltime, multi-node) lives in
`docs/chpc-allocs.md`; reuse it, don't re-derive it.

- The helper runs on CHPC's stock Python 3.6.
- If the helper is unavailable, use the `mychpc batch` triples directly;
  wait estimates will be unavailable.

## 2. Choose the right modules

`module spider <name>` is the authoritative search — `module avail` does **not** list
everything. Pin a version, then confirm:

```bash
module spider openmpi          # find versions + what each needs
module load gcc/12 openmpi/4.1 # load compiler FIRST, then MPI (see below)
module list                    # confirm what's active
```

- **Compiler before MPI.** MPI modules (openmpi, mpich, mvapich) only appear after a
  compiler is loaded. `module spider openmpi/<ver>` prints the exact compiler module to
  load first. Loading the MPI module without it is the most common module error here.
- Loading a second version of a module auto-unloads the first. `ml` is shorthand for
  `module load`.
- **Build on a compute node, not the login node.** Compiling against login-node modules
  and running on a compute node causes a runtime mismatch — typically `srun: error:
  PMIX`. Build inside the same `salloc`/job where you'll run.
- Common toolchains (full list in `~/CLAUDE.md`): `gcc`/`intel`/`aocc`/`nvhpc`,
  `openmpi`/`mpich`/`mvapich`, `cuda`/`cudnn`, `python`.

Put `module purge` then your `module load` lines at the top of the job script (step 3),
so the job's environment is reproducible regardless of login-shell state.

## 3. Write the sbatch script

Seed the `#SBATCH` triple from step 1; tune the rest. The full directive catalog is in
[[slurm-job]] — don't reproduce it here.

```bash
#!/usr/bin/env bash
#SBATCH --account=<from one live inventory row>  # all three flags are mandatory
#SBATCH --partition=<from the same row>
#SBATCH --qos=<from the same row>
#SBATCH --job-name=<short-tag>
#SBATCH --time=HH:MM:SS                  # job is killed at the limit, no warning
#SBATCH --nodes=1
#SBATCH --ntasks=1                       # = MPI ranks
#SBATCH --cpus-per-task=4                # = OMP_NUM_THREADS
#SBATCH --mem=16G
#SBATCH --gres=gpu:a100:1                # GPU jobs only; match step 1's request
#SBATCH --output=logs/%x-%j.out
#SBATCH --error=logs/%x-%j.err

set -euo pipefail
module purge
module load gcc/12 openmpi/4.1          # from step 2; compiler before MPI

srun ./a.out                            # always srun under SLURM, never bare mpirun
```

`mkdir -p logs` before submitting — sbatch refuses an invalid output path.

## 4. Submit and monitor

```bash
sbatch run.slurm                        # prints the job id
squeue --me                             # PD = pending, R = running
squeue -j <jobid> --format=%R           # why a PD job waits (Resources, Priority, …)
scontrol show job <jobid>               # full record incl. predicted start
seff <jobid>                            # efficiency report, after it finishes
```

## CHPC guardrails

These live in the always-loaded `~/CLAUDE.md`; don't violate them:

- **Never run compute on a login node** — use `cnode` or `salloc` for interactive work.
- **All three flags** (`--account` `--partition` `--qos`) are required.
- **Bulk I/O and outputs go to `/scratch/general/vast/$USER`**, not `$HOME` (50GB cap)
  — and scratch is purged after 60 days, so copy keepers back.

## See also

- [[slurm-job]] — generic SLURM directive catalog, failure modes, job arrays
- [[gpu-profile]] once the GPU job runs and you want nsys/ncu data
- [[mpi-openmp]] for multi-node MPI rank/thread sizing
- `docs/chpc-allocs.md` (in this repo) — full `chpc-allocs` request grammar and flags
- `~/CLAUDE.md` — the CHPC account table, storage rules, and module list
