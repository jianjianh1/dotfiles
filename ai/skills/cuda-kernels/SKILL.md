---
name: cuda-kernels
description: Use when the user is writing, debugging, or reviewing CUDA kernels — files with .cu/.cuh extensions, __global__/__device__ functions, kernel launch syntax (<<<>>>), shared/global memory, warp behavior, nvcc compilation, or PTX/SASS output.
---

# CUDA kernel development

Apply when generating or reviewing CUDA C/C++ code.

## Minimal kernel skeleton

```cpp
#include <cuda_runtime.h>
#include <cstdio>

#define CUDA_CHECK(call)                                                       \
    do {                                                                       \
        cudaError_t err = (call);                                              \
        if (err != cudaSuccess) {                                              \
            std::fprintf(stderr, "CUDA error %s:%d: %s\n",                     \
                         __FILE__, __LINE__, cudaGetErrorString(err));         \
            std::exit(1);                                                      \
        }                                                                      \
    } while (0)

__global__ void saxpy(int n, float a, const float* __restrict__ x,
                      float* __restrict__ y) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) y[i] = a * x[i] + y[i];
}

int main() {
    constexpr int N = 1 << 20;
    float *dx, *dy;
    CUDA_CHECK(cudaMalloc(&dx, N * sizeof(float)));
    CUDA_CHECK(cudaMalloc(&dy, N * sizeof(float)));
    // … fill dx, dy …
    constexpr int block = 256;
    int grid = (N + block - 1) / block;
    saxpy<<<grid, block>>>(N, 2.0f, dx, dy);
    CUDA_CHECK(cudaGetLastError());        // catches launch failures
    CUDA_CHECK(cudaDeviceSynchronize());   // catches in-kernel asserts
    cudaFree(dx); cudaFree(dy);
}
```

Compile: `nvcc -O3 -arch=sm_<cap> -lineinfo saxpy.cu -o saxpy`. `-lineinfo`
lets `ncu` map metrics back to source lines without hurting performance;
`-G` (full debug) tanks perf and is only for `cuda-gdb`.

## Launch-config rules of thumb

- **Block size**: 128 or 256 threads. Almost never go below 64 (under-uses
  warps) or above 1024 (hard cap, also hurts occupancy).
- **Grid size**: ceil-div, `(N + block - 1) / block`. For grid-stride loops,
  use `min(SMs * 32, ceil-div(N, block))`.
- **Persistent kernels**: write a grid-stride loop and pick grid ≈ SM count ×
  small constant; only when you need cross-block atomics or reuse.

## Memory hierarchy quick reference

| Memory | Latency | Visible to | Use for |
|---|---|---|---|
| Registers | 1 cycle | one thread | scalars, accumulators |
| Shared (`__shared__`) | ~30 cycles | one block | tiling, reductions, bcast |
| L1 / Texture | ~100 | one SM | read-only with locality |
| Global | ~400-600 | all threads | inputs/outputs |
| Constant (`__constant__`) | broadcast | all threads | uniform-access lookup tables |

Shared memory is the #1 optimization. The pattern: load a tile collectively
into shared, `__syncthreads()`, compute, `__syncthreads()`, write out.

## Coalescing & divergence

- **Coalesced access**: thread `t` reads `arr[base + t]`, not `arr[base + t *
  stride]`. The memory controller groups 32 consecutive 4-byte loads into one
  transaction; strided access scales linearly worse.
- **Bank conflicts**: shared-memory arrays are split into 32 banks. Avoid
  `__shared__ float s[32][32]` followed by `s[t][k]` (column access → 32-way
  conflict). Pad to `[32][33]` to skew.
- **Warp divergence**: an `if`/`else` where threads in a warp take different
  branches serializes both. Either restructure to keep warps coherent, or use
  `__ballot_sync` / warp-level primitives.

## Common pitfalls

- **Forgotten `cudaDeviceSynchronize()`**: kernel launches are async; an error
  inside the kernel surfaces at the *next* CUDA call, not the launch.
- **`__syncthreads()` inside a divergent branch**: undefined behavior. Always
  call it in a path executed by all threads in the block.
- **Race on shared memory after load**: missing `__syncthreads()` between
  cooperative load and use.
- **`int` overflow in index math**: `blockIdx.x * blockDim.x + threadIdx.x`
  overflows past ~2 billion; use `size_t` or `int64_t` for big arrays.
- **Atomics on global memory**: serialize. Prefer block-level reductions in
  shared, then one atomic per block.

## See also

- [[gpu-profile]] for `nsys` + `ncu` workflows on the kernel you just wrote
- [[slurm-job]] for getting a GPU node to run on (`--gres=gpu:1`)
- [[distributed-training]] for multi-GPU patterns above the kernel level
