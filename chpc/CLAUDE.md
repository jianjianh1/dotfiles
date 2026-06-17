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
2. **Every SLURM job needs three flags:** `--partition`, `--account`, `--qos`. Run `mychpc batch` to see valid combinations for this user.
3. **Never unload `chpc/1.0`** -- it is a sticky module required for the CHPC environment.
4. **Scratch is purged every 60 days.** Never store important results only on scratch. Copy outputs back to home or group space.
5. **Keep `$HOME` lean -- never write bulk data to home.** Home is capped at 50GB soft / 70GB hard. Datasets, benchmark output, build artifacts, model checkpoints, and any large generated files belong on scratch (`/scratch/general/vast/$USER`), not under `$HOME` or a repo inside it. When a tool insists on a home path, relocate the heavy directory to scratch and symlink it back. Check `quota -s` / `du -sh ~` before and after large jobs, and clear regenerable caches (`~/.julia/artifacts`, `~/.cache`, `build*/` dirs) when space is tight.

## User's Available SLURM Accounts

### Non-preemptable (guaranteed)

```bash
# GPU -- general (no allocation needed)
--partition=notchpeak-gpu --account=notchpeak-gpu --qos=notchpeak-gpu

# CPU -- shared-short (no allocation, 8h max, 16 cores max, 128GB max, 2 jobs max)
--partition=notchpeak-shared-short --account=notchpeak-shared-short --qos=notchpeak-shared-short

# Owner nodes -- School of Computing
--partition=soc-np --account=soc-np --qos=soc-np
--partition=soc-gpu-np --account=soc-gpu-np --qos=soc-gpu-np

# Owner nodes -- sadayappan group
--partition=sadayappan-np --account=sadayappan-np --qos=sadayappan-np  # NOTE: this is CPU-only via soc-np nodes

# Owner nodes -- College of Engineering
--partition=coestudent-np --account=coe-np --qos=coe-np

# Other clusters (also available)
--partition=kingspeak --account=sadayappan --qos=kingspeak
--partition=lonepeak --account=sadayappan --qos=lonepeak
--partition=kingspeak-gpu --account=kingspeak-gpu --qos=kingspeak-gpu
--partition=lonepeak-gpu --account=lonepeak-gpu --qos=lonepeak-gpu
```

### Preemptable (jobs may be killed, use --requeue and checkpointing)

```bash
# Freecycle -- all notchpeak general nodes
--partition=notchpeak-freecycle --account=sadayappan --qos=notchpeak-freecycle

# GPU guest -- idle owner GPU nodes (wide GPU selection)
--partition=notchpeak-gpu-guest --account=owner-gpu-guest --qos=notchpeak-gpu-guest

# CPU guest -- idle owner nodes
--partition=notchpeak-guest --account=owner-guest --qos=notchpeak-guest

# Granite cluster (newest: AMD Genoa, H100 NVL GPUs)
--partition=granite --account=sadayappan --qos=granite-freecycle
--partition=granite-gpu --account=sadayappan --qos=granite-gpu-freecycle
--partition=granite-gpu-guest --account=sadayappan --qos=granite-gpu-guest
```

## GPU Resources

### General GPU partition (notchpeak-gpu)
- V100 (3/node): notch001-003
- RTX 2080 Ti (2-8/node): notch004, notch086-088, notch271
- P40 (1): notch004
- RTX 3090 (4-8/node): notch293, notch328
- A100 (4): notch293

### SoC GPU owner nodes (soc-gpu-np)
- A6000 (8/node): notch367-368
- A100 (2-8/node): notch369-372

### Request GPUs with:
```bash
--gres=gpu:<type>:<count>
# Types: v100, 2080ti, p40, 3090, a100, a6000, a5500, a40, a800, h100nvl, l40, rtx6000, t4
```

## Job Templates

### Quick CPU job (no allocation needed)
```bash
#!/bin/bash
#SBATCH --job-name=JOB_NAME
#SBATCH --time=HH:MM:SS          # max 08:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=CORES            # max 16
#SBATCH --mem=MEMORY              # max 128G
#SBATCH --account=notchpeak-shared-short
#SBATCH --partition=notchpeak-shared-short
#SBATCH --qos=notchpeak-shared-short
#SBATCH -o slurm-%j.out
#SBATCH -e slurm-%j.err
```

### GPU job (no allocation needed)
```bash
#!/bin/bash
#SBATCH --job-name=JOB_NAME
#SBATCH --time=HH:MM:SS          # max 72:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=CORES
#SBATCH --mem=MEMORY
#SBATCH --gres=gpu:TYPE:COUNT
#SBATCH --account=notchpeak-gpu
#SBATCH --partition=notchpeak-gpu
#SBATCH --qos=notchpeak-gpu
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
#SBATCH --account=soc-np
#SBATCH --partition=soc-np
#SBATCH --qos=soc-np
#SBATCH -o slurm-%j.out
```

### Freecycle job (preemptable, add checkpointing)
```bash
#!/bin/bash
#SBATCH --job-name=JOB_NAME
#SBATCH --time=72:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=CORES
#SBATCH --account=sadayappan
#SBATCH --partition=notchpeak-freecycle
#SBATCH --qos=notchpeak-freecycle
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
- **Process killed on a login node (Claude, python, etc.)**: login nodes cap each user at **8GB mem+swap / 4 cores** in one shared cgroup (Arbiter). When your combined login-node processes exceed 8GB, the kernel OOM-killer reaps the largest one -- confirm with `dmesg | grep CONSTRAINT_MEMCG`. This is why Claude sometimes dies, especially alongside a memory-heavy analysis. Per Critical Rule #1, run Claude *and* any heavy analysis in an interactive allocation, not on the login node: `cnode` (shell alias, defaults to 4 cores/32G/8h on `notchpeak-shared-short`) or `salloc --partition=notchpeak-shared-short --account=notchpeak-shared-short --qos=notchpeak-shared-short --ntasks=4 --mem=32G --time=8:00:00`. Check current usage with `cat /sys/fs/cgroup/memory/user.slice/user-$(id -u).slice/memory.usage_in_bytes`.

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
