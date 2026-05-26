---
name: distributed-training
description: Use when the user is setting up multi-GPU or multi-node ML training — PyTorch DDP, FSDP, torchrun, accelerate, deepspeed, NCCL, torch.distributed, multi-node srun launchers, gradient accumulation, mixed precision, or checkpoint/resume on a SLURM cluster.
---

# Distributed training (PyTorch + SLURM)

Apply for PyTorch DDP/FSDP setups on multi-GPU and multi-node clusters.
Single-GPU code does not need this skill.

## Pick the right parallelism

| Model fits on one GPU? | Use |
|---|---|
| Yes, batch is the bottleneck | **DDP** (data parallel; one full replica per GPU) |
| No — parameters too big | **FSDP** (shards params, grads, optimizer state across GPUs) |
| Layers are heterogeneous, low arithmetic intensity | **Pipeline parallel** (rare; library-specific) |
| Each layer too big for one GPU | **Tensor parallel** (Megatron / DeepSpeed) |

DDP first, FSDP when you OOM. Skip the heavier options unless you've measured
the bottleneck.

## DDP minimal template

```python
import os, torch
import torch.distributed as dist
from torch.nn.parallel import DistributedDataParallel as DDP

def main():
    dist.init_process_group(backend="nccl")
    local_rank = int(os.environ["LOCAL_RANK"])
    torch.cuda.set_device(local_rank)

    model = build_model().cuda(local_rank)
    model = DDP(model, device_ids=[local_rank])

    sampler = torch.utils.data.distributed.DistributedSampler(dataset)
    loader  = torch.utils.data.DataLoader(dataset, sampler=sampler, ...)

    for epoch in range(num_epochs):
        sampler.set_epoch(epoch)            # critical: reshuffles each epoch
        for batch in loader:
            ...
    dist.destroy_process_group()

if __name__ == "__main__":
    main()
```

The `LOCAL_RANK`/`RANK`/`WORLD_SIZE` env vars are set by `torchrun`; don't
parse `--local-rank` argparse args (deprecated since PyTorch 1.9).

## torchrun launcher under SLURM

Two patterns. Pick **A** for most jobs.

**A. One srun call, `torchrun` per node.**

```bash
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=1          # ONE torchrun per node …
#SBATCH --cpus-per-task=16
#SBATCH --gres=gpu:4                 # … each launches 4 workers (one per GPU)

export MASTER_ADDR=$(scontrol show hostnames "$SLURM_JOB_NODELIST" | head -1)
export MASTER_PORT=29500

srun bash -c '
    torchrun \
        --nnodes=$SLURM_NNODES \
        --nproc-per-node=4 \
        --rdzv-id=$SLURM_JOB_ID \
        --rdzv-backend=c10d \
        --rdzv-endpoint=$MASTER_ADDR:$MASTER_PORT \
        train.py
'
```

**B. srun itself launches each worker** (one task per GPU). Skips torchrun;
useful when torchrun's rendezvous misbehaves.

```bash
#SBATCH --ntasks-per-node=4          # one task PER GPU
#SBATCH --gpus-per-task=1
srun python train.py                 # PyTorch reads SLURM env directly
```

You then need to translate SLURM vars to torch vars inside `train.py`:

```python
os.environ["RANK"]       = os.environ["SLURM_PROCID"]
os.environ["WORLD_SIZE"] = os.environ["SLURM_NTASKS"]
os.environ["LOCAL_RANK"] = os.environ["SLURM_LOCALID"]
```

## NCCL essentials

`backend="nccl"` is required for GPU comms (Gloo is CPU-only and slow). When
things hang or crash:

```bash
export NCCL_DEBUG=INFO            # one-time, very chatty; verify every rank
                                  # logs "NCCL INFO ... CUDA Driver:" early
export NCCL_DEBUG_SUBSYS=ALL
export NCCL_SOCKET_IFNAME=ib0     # force the IB interface if multi-NIC
export NCCL_IB_DISABLE=0          # 1 to fall back to TCP (debug only)
export NCCL_P2P_DISABLE=0         # 1 if peer-to-peer access fails (Ampere bugs)
```

If init hangs, the most common cause is `MASTER_ADDR` resolving differently
on different nodes (DNS lag vs hostname). Use the head-node IP directly if
that happens.

## FSDP at a glance

```python
from torch.distributed.fsdp import FullyShardedDataParallel as FSDP
from torch.distributed.fsdp import MixedPrecision

mp_policy = MixedPrecision(
    param_dtype=torch.bfloat16, reduce_dtype=torch.bfloat16,
    buffer_dtype=torch.bfloat16,
)
model = FSDP(
    model,
    sharding_strategy="FULL_SHARD",      # or "SHARD_GRAD_OP" (ZeRO-2)
    mixed_precision=mp_policy,
    cpu_offload=None,                    # CPUOffload(offload_params=True) if OOM
    device_id=local_rank,
)
```

Save with `FSDP.state_dict_type(model, FULL_STATE_DICT, ...)` and gather to
rank 0; never `torch.save(model.state_dict())` directly under FSDP.

## Mixed precision & gradient accumulation

- `bfloat16` over `float16` on Ampere+: no loss scaling needed, similar speed.
- `torch.amp.autocast("cuda", dtype=torch.bfloat16)` — wrap forward only;
  optimizer step stays in fp32.
- Gradient accumulation: scale loss by `1/accum_steps` before `.backward()`.
  With DDP, wrap the non-final micro-batches in `model.no_sync()` to skip
  all-reduce until the final accumulated step.

## Checkpoint / resume on a wall-clock-limited cluster

```bash
#SBATCH --signal=B:USR1@120                 # SIGUSR1 120s before timeout
```

```python
import signal, sys
def handle_term(signum, frame):
    if rank == 0: save_checkpoint(model, optimizer, step)
    dist.barrier(); dist.destroy_process_group(); sys.exit(0)
signal.signal(signal.SIGUSR1, handle_term)
```

Pair with sbatch `--requeue` and `--array=0-9%1` to chain auto-resume jobs.

## Common pitfalls

- **DDP wrapped before `.cuda()`**: parameters live on CPU, NCCL crashes.
  Order: `model.cuda(local_rank)` → `DDP(model)`.
- **Dataloader workers + DDP**: each DDP rank spawns its own dataloader
  workers. Total CPU workers = ranks × `num_workers`. Tune to total CPUs.
- **Forgot `sampler.set_epoch(epoch)`**: every epoch sees the same shuffle
  → silent dup'd training.
- **BatchNorm**: use `SyncBatchNorm.convert_sync_batchnorm(model)` before
  DDP for cross-rank stats; otherwise stats are per-replica.

## See also

- [[slurm-job]] for `--gres=gpu`, `--ntasks`, `--gpus-per-task`
- [[cuda-kernels]] / [[gpu-profile]] if a kernel is slow within the training step
