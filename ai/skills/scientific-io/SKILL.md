---
name: scientific-io
description: Use when the user is reading/writing scientific data — HDF5 (.h5, .hdf5), NetCDF (.nc), Zarr (.zarr), parallel I/O (MPI-IO, collective vs independent), chunking, compression filters, Darshan profiling, or asking which format to use.
---

# Scientific data formats & parallel I/O

Apply for HPC data layout, format choice, and I/O performance.

## Picking a format

| Format | Best for | Avoid when |
|---|---|---|
| **HDF5** | Single-file hierarchies, mixed datatypes, parallel-write via MPI-IO | Many small writes from many processes (metadata contention) |
| **NetCDF-4** | Climate/geo conventions (CF), strong tooling (ncview, cdo) | Arbitrary-shape graphs; it's array-of-named-arrays |
| **Zarr** | Cloud / object stores, many-process append, Python-first | Single-file dependency expectations (it's a directory tree) |
| **ADIOS2** | Streaming, in-situ analysis, very large parallel writes | Small datasets, anything ecosystem-driven |
| **Parquet** | Tabular analytics, columnar reads | N-D arrays (use HDF5/Zarr) |

**Default to HDF5** for structured N-D scientific data on a parallel
filesystem. Switch to Zarr if the target is object storage or if you need
many concurrent appenders.

## HDF5 chunking & compression

Two chunking rules:

1. **Chunk shape should match read patterns.** A `(time, lat, lon)` dataset
   read time-series-by-grid-point wants chunks like `(1000, 1, 1)`; read
   map-at-a-time wants `(1, lat, lon)`. The wrong chunk shape can make reads
   100× slower.
2. **Chunk size: 1–16 MB.** Smaller wastes metadata; larger loses random-read
   locality.

```python
import h5py
with h5py.File("out.h5", "w") as f:
    f.create_dataset(
        "field",
        shape=(1000, 720, 1440),
        chunks=(1, 720, 1440),     # one map per chunk
        dtype="f4",
        compression="gzip",        # or "lzf" (faster, less ratio)
        compression_opts=4,        # gzip level; 4 is a good default
        shuffle=True,              # cheap, helps gzip a lot on floats
    )
```

`shuffle=True` + `gzip` typically gets 2-3× better ratio than gzip alone for
float arrays — it transposes byte planes before compressing.

## Parallel HDF5 (MPI-IO)

```python
from mpi4py import MPI
import h5py

comm = MPI.COMM_WORLD
rank, size = comm.rank, comm.size

with h5py.File("out.h5", "w", driver="mpio", comm=comm) as f:
    dset = f.create_dataset("field", (size * 1024,), dtype="f8")
    dset[rank * 1024:(rank + 1) * 1024] = my_chunk
```

- **Collective writes** (default with `driver="mpio"`) all ranks write at
  once; MPI-IO aggregates into large filesystem-friendly transactions.
- **Independent writes** (per-rank file handles) are simpler but pulverize
  Lustre/GPFS metadata. Only use for embarrassingly parallel "rank N writes
  rank-N.h5" patterns.
- **Compression is incompatible with parallel-mode writes** in stock HDF5.
  Write uncompressed, then `h5repack -f GZIP=4` in a postprocess step.

## NetCDF tips

- Use NetCDF-4 (built on HDF5), not classic — chunking and compression need it.
- `nccopy -d 4 -c "time/1,lat/180,lon/360" in.nc out.nc` rechunks an existing
  file without rewriting your code.
- For climate workflows, follow CF conventions: standard variable names,
  units strings, `coordinates` attributes. `cdo` and `xarray` rely on them.

## Zarr quickstart

```python
import zarr
import numpy as np

z = zarr.open(
    "out.zarr",
    mode="w",
    shape=(1000, 720, 1440),
    chunks=(1, 720, 1440),
    dtype="f4",
    compressor=zarr.Blosc(cname="zstd", clevel=3, shuffle=zarr.Blosc.SHUFFLE),
)
z[0] = np.random.rand(720, 1440).astype("f4")
```

Zarr v3 supports sharding (group many chunks per file) — turn it on for
object-store backends to avoid the `N×M` small-file penalty.

## Diagnosing I/O bottlenecks

```bash
# Darshan: lightweight always-on tracing on most HPC systems.
# Already linked in if you see "darshan" in the loaded modules.
ls $DARSHAN_LOG_DIR/$USER/<year>/
darshan-job-summary.pl <log>.darshan      # PDF summary
darshan-parser <log>.darshan | head       # text dump
```

What to look for:

- **Time spent in `write()` ≫ compute time** → I/O-bound; check chunking,
  compression, collective vs independent.
- **Many small operations (`POSIX_WRITES` count high, mean size low)** →
  buffer up or use HDF5/NetCDF instead of raw fwrite.
- **Read amplification (`POSIX_BYTES_READ` ≫ data size)** → chunk shape
  mismatch, reading more than you need.

For per-process diagnosis, `strace -c -e trace=write,read,open ./app`
quickly shows where the syscalls go.

## Stripe count (Lustre)

```bash
lfs setstripe -c 16 -S 1M output_dir/   # 16-way striping, 1 MB stripe
lfs getstripe file.h5                   # verify
```

Large parallel HDF5 writes get a huge boost from striping. One-file-per-rank
patterns hate striping (every rank's file gets spread, contending on OSTs).

## See also

- [[slurm-job]] — `--mem` budget must include I/O buffers
- [[mpi-openmp]] — parallel HDF5 uses MPI-IO under the hood
- Pair Darshan with Score-P when I/O is only one part of a larger runtime bottleneck.
