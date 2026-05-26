---
name: gpu-profile
description: Use when the user is profiling GPU code — invoking nsys (Nsight Systems), ncu (Nsight Compute), nvprof, or interpreting .nsys-rep / .ncu-rep reports, timelines, kernel metrics, occupancy, or roofline data.
---

# GPU profiling (Nsight Systems & Compute)

Apply when the user wants to record or read GPU traces.

## The two-tool workflow

1. **`nsys` (Nsight Systems) — system timeline.** Use first. Tells you which
   kernels run, how long, whether the CPU/GPU overlap, and whether you're
   memory- or compute-bound at the whole-app level.
2. **`ncu` (Nsight Compute) — single-kernel deep dive.** Use second, on the
   1-3 hottest kernels nsys identified. Gives roofline, achieved occupancy,
   memory throughput, warp stall reasons.

Don't start with `ncu` — it's slow (replays each kernel many times) and
shows you nothing about whether the kernel even matters.

## Recording with nsys

```bash
# Inside the SLURM job script, after module load cuda:
nsys profile \
    --output=profile.${SLURM_JOB_ID:-out} \
    --force-overwrite=true \
    --trace=cuda,nvtx,osrt \
    --cuda-memory-usage=true \
    --gpu-metrics-device=all \
    --gpu-metrics-set=base \
    --capture-range=cudaProfilerApi \
    ./a.out
```

- `--trace=cuda,nvtx,osrt`: CUDA API + your NVTX ranges + OS runtime.
- `--gpu-metrics-device=all` only on Volta+; samples SM activity at ~10 kHz.
- `--capture-range=cudaProfilerApi`: skip the warm-up phase by wrapping the
  region of interest in `cudaProfilerStart()` / `cudaProfilerStop()`. Without
  this, the report covers everything including warm-up.

For long runs, add `--duration=60 --delay=30` to capture 60s starting 30s in.
Reports balloon past 1 GB quickly — keep `--duration` short.

Open the `.nsys-rep` in the Nsight Systems GUI, or `nsys stats profile.nsys-rep
--report cuda_gpu_kern_sum` for a CLI summary of the hottest kernels.

## Recording with ncu

```bash
ncu \
    --target-processes=all \
    --set=full \
    --launch-skip=10 --launch-count=1 \
    --kernel-name=regex:saxpy \
    --export=kernel_profile \
    ./a.out
```

- `--set=full` is comprehensive but slow; use `--set=basic` or
  `--set=roofline` first.
- `--launch-skip=N --launch-count=M`: profile only some launches (kernels
  warm up and the first launch is often atypical).
- `--kernel-name=regex:…`: filter to specific kernels, otherwise everything
  gets the slow replay.

Read in the Nsight Compute GUI, or `ncu --import kernel_profile.ncu-rep`.

## Interpreting metrics

| Symptom in nsys timeline | Likely cause |
|---|---|
| Huge gaps between kernels | CPU bottleneck or sync-on-every-launch |
| Kernel time ≫ memcpy time, GPU busy ~100% | Compute-bound (good if intended) |
| Many short kernels back-to-back | Kernel-launch overhead — fuse or use CUDA Graphs |
| `cudaMemcpy` interleaved with kernels | Missing `cudaMemcpyAsync` + streams |
| One stream, idle SMs | No overlap — multiple streams or graphs |

In ncu, the headline numbers:

- **Compute (SM) Throughput** vs **Memory Throughput** — the bigger one wins.
  Memory-bound? Coalesce, use shared memory, reduce footprint. Compute-bound?
  Increase ILP, use Tensor Cores, reduce work.
- **Achieved Occupancy** below 50% on memory-bound code is *fine*. Below 25%
  on compute-bound usually isn't — check register pressure (`--ptxas-options=-v`
  at compile time, or the "Launch Stats" section in ncu).
- **Warp State** breakdown shows what stalls warps: `Stall Long Scoreboard`
  = global memory latency, `Stall MIO Throttle` = shared-memory pressure,
  `Stall Wait` = sync barriers.

## Roofline at a glance

`ncu --set=roofline` plots arithmetic intensity (FLOPs/byte) vs achieved
GFLOPs. The kernel lands either:

- **Under the slanted line** = memory-bound (move along the line to gain).
- **Under the flat line** = compute-bound (need more arithmetic per byte or
  better instructions, e.g. FMA / Tensor Cores).
- **On the ridge** = balanced; you've extracted what the hardware gives you.

## Quick-fire cheat sheet

```bash
# What kernels are hot?
nsys stats <rep>.nsys-rep --report cuda_gpu_kern_sum --format csv

# What does kernel X actually do?
ncu --set=basic --kernel-name=regex:^myKernel$ ./a.out

# Where do warps stall?
ncu --section WarpStateStats ./a.out
```

## See also

- [[cuda-kernels]] for the kernel you'll be optimizing
- [[slurm-job]] — nsys/ncu both need a GPU node; submit with `--gres=gpu:1`
- [[hpc-perf]] for non-GPU profiling (perf, gprof, Score-P, HPCToolkit)
