# `chpc-allocs`

Source: [`chpc-allocs.py`](../chpc-allocs.py) (installed to `~/.local/bin/chpc-allocs` by `setup.sh`).

Show your CHPC SLURM allocations and predict queue wait time for hypothetical jobs. A "wait check" here is a non-mutating `sbatch --test-only` probe — nothing is actually submitted.

Requires **Python 3.7+**. CHPC's system `/usr/bin/python3` is 3.6 on some nodes; `module load python/3.10.3` first if `chpc-allocs` exits with the version-guard error.

---

## Common entry points

| Command | What it does |
|---------|--------------|
| `chpc-allocs` | Print a short quickstart. |
| `chpc-allocs a100:4` | Wait check: a single `a100 × 4` job. |
| `chpc-allocs cpu:32` | Wait check: 32-core CPU job. |
| `chpc-allocs a100:4 cpu:32` | Two alternatives (space ≡ `+` ≡ OR). |
| `chpc-allocs 'a100:4*cpu:32'` | Combine into one job (`*` ≡ AND; quote where shells glob). |
| `chpc-allocs --best a100:4` | Lowest-wait runnable triple as a paste-ready `#SBATCH` block. |
| `chpc-allocs --quick` | Allocations only, no wait checks (fast). |
| `chpc-allocs --explain a100:4` | Preview which filters/checks would run; no `sbatch` calls. |
| `chpc-allocs --list-gpus` | Cluster-wide GPU inventory from `sinfo`. |
| `chpc-allocs --list-cpus 'cpu:32*genoa'` | CPU inventory narrowed to Genoa hosts. |

---

## Request grammar

Tokens separated by spaces or `+` are alternatives (OR). Tokens joined by `*` combine into one job (AND, binds tighter than `+`).

| Token | Meaning |
|-------|---------|
| `a100:4` | Specific GPU type × 4 (resolves to actual GRES, e.g. `h100nvl` for `h100`). |
| `cpu:32` | 32 cores per node. |
| `gpu:4` | Any GPU × 4. |
| `32` | Shorthand for `cpu:32`. |
| `2n` | 2 nodes. |
| `<req>@30m`, `<req>@12h` | Walltime suffix. |
| `intel`, `amd`, `skl`, `genoa`, `rome`, `milan`, `zen4`, … | CPU vendor / microarch atom (filters rows + passes `--constraint`). |
| `ampere`, `hopper`, `ada`, `sm80`, `sm_89`, … | GPU generation / SM atom (filters rows + pins `--gres` type). |
| `gpu:1,sm_min=80` | Comma-separated `key=value`: any GPU with compute capability ≥ 8.0. |
| `cores=…`, `total=…`, `mem=…`, `time=…`, `gpus=…`, `nodes=…`, `vendor=…`, `arch=…`, `gen=…`, `sm=…` | Long-form keys (accepted anywhere a comma list is). |

**Multi-node rule:** when a node count is given (`2n` or `nodes=2`), `cpu:N` and `cores=N` are **per node**; use `total:N` or `total=N` for an explicit job-wide total.

Combined examples: `a100:4*intel+h100:1@30m`, `'2n*a100:4@12h'`, `'a100:4*cpu:32+h100:1'`.

---

## Filtering

Name filters are case-insensitive substring matches, repeatable, OR-joined. Hardware narrowing happens implicitly from the request — a row whose hardware can't run any checked request is dropped.

| Flag | Effect |
|------|--------|
| `--cluster NAME`, `--account NAME`, `--qos NAME` | Repeatable substring filters. |
| `--default-only` | Default QOS per association only. |
| `--freecycle-only` / `--exclude-freecycle` | Toggle preemptable / no-fairshare rows. |
| `--guest-only` / `--exclude-guest` | Toggle owner-node guest rows. |
| `--reservation` | Only QOS that require a reservation. |
| `--min-wall DUR` | Minimum MaxWall (e.g. `24:00:00`, `7d`, `unlimited`). |
| `--fairshare-min F`, `--usage-max F` | Drop rows by FairShare / RawUsage (needs `sshare` data). |
| `--all-visible` | Search every association readable by your permissions. Omits user names; may be slow; disables sshare enrichment. |

---

## Output

Default: **table on a TTY, JSON when piped or redirected** (a stderr notice fires on the auto-switch).

| Flag | Effect |
|------|--------|
| `--format {table,csv,json}` | Force a format. |
| `--sort KEYS` | Comma-separated sort keys (case-insensitive). Categories: time (`wait`, `request`, `wall`), quality (`premium`, `vendor`, `default`, `tags`), identity (`cluster`, `account`, `qos`), score (`priority`, `fairshare`, `usage`). |
| `--reverse` | Reverse the sort. |
| `--no-json-help` | Strip the JSON `_help` legend. |
| `--legend` | Append a short key under the table. |
| `--full` | Keep every walltime row (skip the uniform-wait collapse). |
| `--show-all` | Don't hide marginal rows (`?` waits, scheduler rejections). |
| `--best` | Print only the lowest-wait runnable triple as a paste-ready `#SBATCH` block. |
| `--sbatch` | Emit a `#SBATCH` block per allocation row. Requires a REQUEST. |
| `--pivot` | Pivot layout: rows = (cluster, account, qos), columns = request labels, cells = wait times. Table only. |

---

## Speed knobs

Each query can be skipped independently; `--quick` is the everything-off macro.

| Flag | Skips |
|------|-------|
| `--no-wait` | The `sbatch --test-only` probe. |
| `--no-availability` | Live `sinfo` capacity. |
| `--no-usage` | `sshare` fairshare/usage. |
| `--quick` | All three. |
| `--explain` | Run filters and preview the planned wait checks, then exit. |
| `-v`, `--verbose` | Narrate dropped rows + wait-check progress to stderr. Wait-check failures print a full traceback. |
| `-q`, `--quiet` | Suppress all informational stderr. Errors still print. |
| `--self-test` | Internal parser/format tests; no SLURM queries. CI uses this. |

---

## Examples

```bash
# When can my a100x4 job run?
chpc-allocs a100:4

# Best (lowest-wait) option as a ready-to-paste sbatch block.
chpc-allocs --best a100:4

# Two alternatives, 12-hour walltime.
chpc-allocs 'a100:4+cpu:32@12h'

# One combined 12-hour job needing BOTH a100x4 and cpu:32.
chpc-allocs 'a100:4*cpu:32@12h'

# All my allocations as CSV, no wait checks.
chpc-allocs --quick --format csv > allocs.csv

# 2 nodes, 64 cores total (the explicit form).
chpc-allocs '2n,total:64'

# Cluster GPU inventory, filtered to partitions exposing an a100.
chpc-allocs --list-gpus a100:1

# Preview what a query would do without hitting the scheduler.
chpc-allocs --explain a100:4+cpu:32
```

---

## When something looks off

- **`wait: ?`** — the scheduler returned an ambiguous result or `--no-wait` was set. Re-run with `-v` to see the full reason.
- **`wait: None` with `wait-check-error`** — an exception was raised during the `sbatch --test-only` probe. A one-line `[chpc-allocs] wait-check raised for …` should print to stderr; re-run with `-v` for the full traceback.
- **No rows** — name filters intersect to empty, or your hardware request can't run on any QOS you have access to. Try `--explain` to see what was filtered out, or drop `--cluster`/`--account`/`--qos` flags.
- **`CommandError: command not found: sacctmgr/sinfo/sshare`** — load the SLURM client module on this node, or run from a CHPC login node. The script doesn't auto-`module load`.
- **`requires Python 3.7+`** — `module load python/3.10.3` and re-run.
