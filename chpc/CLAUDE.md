# CLAUDE.md -- Notchpeak HPC Agent Guide

## Environment

- **Cluster:** University of Utah CHPC Notchpeak
- **Hostname:** notchpeak1 or notchpeak2 (login nodes)
- **User:** u1446071
- **Group:** sadayappan
- **Scheduler:** SLURM 24.11.5
- **Module system:** Lmod 8.6
- **Home:** `/uufs/chpc.utah.edu/common/home/u1446071`
- **Scratch:** `/scratch/general/vast/u1446071` (preferred), `/scratch/general/lustre/u1446071`, `/scratch/general/nfs1/u1446071`

## Critical Rules

1. **NEVER run computation on login nodes.** Login nodes have a 4-core/8GB limit enforced by Arbiter. Always use `salloc`, `srun`, or `sbatch` to run on compute nodes.
2. **Every SLURM job needs three flags:** `--partition`, `--account`, `--qos`. Run `mychpc batch` for every allocation or job choice; its live list is authoritative. Inspect every option before choosing one.
3. **Never unload `chpc/1.0`** -- it is a sticky module required for the CHPC environment.
4. **Scratch is purged every 60 days.** Never store important results only on scratch. Copy outputs back to home or group space.
5. **Keep `$HOME` lean -- never write bulk data to home.** Home is capped at 50GB soft / 70GB hard. Datasets, benchmark output, build artifacts, model checkpoints, and any large generated files belong on scratch (`/scratch/general/vast/$USER`), not under `$HOME` or a repo inside it. When a tool insists on a home path, relocate the heavy directory to scratch and symlink it back. Check `quota -s` / `du -sh ~` before and after large jobs, and clear regenerable caches (`~/.julia/artifacts`, `~/.cache`, `build*/` dirs) when space is tight.

## Find the current allocation

```bash
mychpc batch                              # every combination available to this user
chpc-allocs --quick --format table         # the same triples, with partition shown
chpc-allocs --show-all 'a100:1@8h'         # assess every compatible GPU option
```

Use the exact account, partition, and QoS from one live row. `--best` is a final
selection shortcut, not an inventory. Guest and freecycle jobs may be preempted;
use checkpointing and `--requeue` when those options are suitable. Data-transfer
partitions are not compute options. If `mychpc batch` is unavailable, say the
inventory may be incomplete rather than using a saved account list.

## GPU Resources

GPU models and node counts change. Query the live hardware list, then check
which matching partitions appear in your `mychpc batch` inventory:

```bash
chpc-allocs --list-gpus
chpc-allocs --show-all 'gpu:1@8h'
```

Request a GPU type exposed by the chosen partition:

```bash
--gres=gpu:<type>:<count>
```

## Job Templates

### Short CPU job
```bash
#!/bin/bash
#SBATCH --job-name=JOB_NAME
#SBATCH --time=HH:MM:SS          # within the chosen QoS limit
#SBATCH --nodes=1
#SBATCH --ntasks=CORES
#SBATCH --mem=MEMORY
#SBATCH --account=<from mychpc batch>
#SBATCH --partition=<from the same mychpc batch row>
#SBATCH --qos=<from the same mychpc batch row>
#SBATCH -o slurm-%j.out
#SBATCH -e slurm-%j.err
```

### GPU job
```bash
#!/bin/bash
#SBATCH --job-name=JOB_NAME
#SBATCH --time=HH:MM:SS          # within the chosen QoS limit
#SBATCH --nodes=1
#SBATCH --ntasks=CORES
#SBATCH --mem=MEMORY
#SBATCH --gres=gpu:TYPE:COUNT
#SBATCH --account=<from mychpc batch>
#SBATCH --partition=<from the same mychpc batch row>
#SBATCH --qos=<from the same mychpc batch row>
#SBATCH -o slurm-%j.out
#SBATCH -e slurm-%j.err
```

### Owner node job (group priority)
```bash
#!/bin/bash
#SBATCH --job-name=JOB_NAME
#SBATCH --time=HH:MM:SS
#SBATCH --nodes=1
#SBATCH --ntasks=CORES
#SBATCH --account=<from mychpc batch>
#SBATCH --partition=<from the same mychpc batch row>
#SBATCH --qos=<from the same mychpc batch row>
#SBATCH -o slurm-%j.out
```

### Freecycle job (preemptable, add checkpointing)
```bash
#!/bin/bash
#SBATCH --job-name=JOB_NAME
#SBATCH --time=72:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=CORES
#SBATCH --account=<from mychpc batch>
#SBATCH --partition=<from the same mychpc batch row>
#SBATCH --qos=<from the same mychpc batch row>
#SBATCH --requeue
#SBATCH --signal=B:USR1@120
#SBATCH -o slurm-%j.out
```

## Module Usage

```bash
module spider <name>           # search for software
module load <name>/<version>   # load it
module list                    # see what's loaded
```

### Common modules
- Compilers: `gcc`, `intel`, `aocc`, `nvhpc`, `llvm`
- MPI: `openmpi`, `mpich`, `mvapich` (load compiler first)
- CUDA: `cuda/12.5.0`, `cudnn/9.2.0.82-12-gpu`
- Python: `python/3.10.3` (alias: `python3`)
- Containers: `charliecloud`, `singularity`

## Storage

| Location | Quota/Size | Purge | Use For |
|----------|-----------|-------|---------|
| `$HOME` (~50GB) | 50GB soft / 70GB hard | None | Code, scripts, configs |
| `/scratch/general/vast/$USER` | 1 PB shared | 60 days | Large I/O, datasets |
| `/scratch/general/lustre/$USER` | 700 TB shared | 60 days | Parallel I/O |
| `/scratch/local/$USER/$SLURM_JOB_ID` | Node-local | Job end | Fastest I/O |

`$HOME` is small and quota-enforced -- keep only code/scripts/configs there. Bulk data goes to scratch (see Critical Rule #5). To free a home path a tool wrote to, `mv` the heavy dir to `/scratch/general/vast/$USER/...` and `ln -s` it back; the relative path keeps resolving.

## Workflow for Submitting Jobs

1. Write a SLURM script with the correct `--account`/`--partition`/`--qos` triple
2. Use `sbatch script.sh` to submit
3. Monitor with `squeue --me`
4. Check results in the `-o` output file
5. After completion, use `seff <jobid>` to check efficiency

## Common Troubleshooting

- **Job pending with `Priority`**: normal queue wait, be patient
- **Job pending with `Resources`**: nodes are full, consider smaller request
- **Invalid account error**: run `mychpc batch` and use exact triple shown
- **AMD vs Intel**: use `--constraint="skl|csl"` if code needs AVX-512; AMD Rome nodes don't have it
- **Memory errors**: default is 2GB/core; specify `--mem=XG` explicitly
- **MKL on AMD**: set `export MKL_DEBUG_CPU_TYPE=5` for better performance
- **Process killed on a login node (Claude, python, etc.)**: login nodes cap each user at **8GB mem+swap / 4 cores** in one shared cgroup (Arbiter). When your combined login-node processes exceed 8GB, the kernel OOM-killer reaps the largest one. Confirm with `dmesg | grep CONSTRAINT_MEMCG`. Run heavy work in an interactive allocation: choose a live triple from `mychpc batch`, then pass its exact values to `salloc` with suitable `--ntasks`, `--mem`, and `--time`. Check current usage with `cat /sys/fs/cgroup/memory/user.slice/user-$(id -u).slice/memory.usage_in_bytes`.

## Useful Commands

```bash
mychpc batch                    # show valid account/partition/qos combos
squeue --me                     # your jobs
scancel <jobid>                 # cancel job
seff <jobid>                    # job efficiency report
sacct -j <jobid>                # accounting details
sinfo -p <partition>            # partition status
scontrol show job <jobid>       # full job info
quota -s                        # disk quota
```
