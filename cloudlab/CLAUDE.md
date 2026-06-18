# CLAUDE.md -- CloudLab Bare-Metal Agent Guide

You are on a **CloudLab** node: a bare-metal machine you provisioned as part of an
*experiment* on the Emulab/CloudLab testbed. This is **not** an HPC cluster -- there is no
SLURM, no Lmod, no shared batch queue. You have **passwordless root**, the node is yours
exclusively, and **local disk is wiped when the experiment ends**. Read the Critical Rules
before doing anything that writes data.

## Environment

- **Testbed:** CloudLab (federated Emulab). Clusters: Utah, Wisconsin, Clemson, APT, etc.
- **OS:** typically Ubuntu (bare metal; you have full root via passwordless `sudo`).
- **No scheduler / no modules:** run processes directly. `sbatch`, `srun`, `module` do not
  exist here. Multi-node work is driven by SSH/`mpirun`/`pdsh`/ansible across your nodes.

### Discover your context (nothing is hardcoded -- find it at runtime)

```bash
hostname                    # node.<experiment>.<project>.<cluster>.cloudlab.us
                            # (use plain `hostname`; `hostname -f` returns the PHYSICAL node, e.g. ms0815.utah.cloudlab.us)
whoami                      # your testbed username == $USER; home is /users/$USER
geni-get slice_urn          # urn:...:<project>+slice+<experiment>
geni-get manifest           # full rspec: every node, its hardware type, and the LAN links
ls -d /proj/*/              # your project's shared NFS space: /proj/<Project>
getent hosts node1 node2    # experiment LAN names resolve via /etc/hosts (see below)
df -h                       # actual disk layout on THIS node type (varies a lot)
```

## Critical Rules

1. **Local storage is ephemeral -- it is destroyed when the experiment is terminated or
   expires.** The root disk (`/`) and any node-local scratch (`/local`) do **not** survive.
   Save anything you want to keep to `/proj/<Project>` (NFS, persists) or copy it off-node
   (`scp`, `git push`, `rsync`) **before** the experiment ends. Treat every local file as
   disposable.
2. **Watch the expiration clock.** Experiments expire on a deadline (often ~16 h by default)
   and the nodes -- with their disks -- are reclaimed at that moment. Extend the experiment
   from the CloudLab web portal *before* it lapses. `geni-get` does not reliably expose the
   expiry on every node, so confirm it on the portal, not from the shell.
3. **You have passwordless root, but installs vanish on reprovision.** Anything you
   `apt install` or build lives only on this disk. For anything you want to be reproducible,
   put it in a setup script under `/proj/<Project>` (or bake it into the profile), not
   ad-hoc on the node. Don't assume a fresh node will have what this one has.
4. **No SLURM, no Lmod.** Don't reach for `sbatch`/`srun`/`squeue`/`module load`. Compilers
   and tools come from the OS (`apt`), from `/share` (NFS-mounted prebuilt software), or
   from what you install. To run on many nodes, loop over them with SSH (Multi-node below).
5. **`/proj` and `/users` are shared NFS -- keep heavy I/O off them.** Benchmark output,
   build trees, and hot datasets belong on node-local disk (`/local`, or a dataset/blockstore
   mount), not on NFS. Writing bulk data over NFS is slow and pollutes shared space. Stage
   inputs to local disk, compute locally, then copy *final* results back to `/proj`.

## Storage

Run `df -h` and `mount` on the actual node -- layout varies by hardware type. Typical map:

| Location | Backing | Persists? | Use for |
|----------|---------|-----------|---------|
| `/users/$USER` (home) | NFS *or* node-local -- **varies by node/cluster** | **Verify with `df -h ~`; don't assume** | dotfiles, small scripts, configs |
| `/proj/<Project>` | NFS, shared by project | Across experiments (reliable) | code, final results, datasets to keep |
| `/share` | NFS, shared (rw) | Testbed-wide | prebuilt software the testbed ships |
| `/` (root disk) | node-local | **No -- wiped on terminate** | OS, installed packages |
| `/local` | node-local scratch | **No -- wiped on terminate** | hot I/O, benchmark output, build trees |
| blockstore / `extrafs` | node-local or remote dataset | depends on profile | large local datasets (mount per profile) |

`/proj/<Project>` is the reliable persistent, shared store; node-local disk (`/`, `/local`)
is fast but disposable. Home (`/users/$USER`) is NFS on some clusters and node-local on
others -- run `df -h ~` to check, and never count on it surviving re-instantiation. The
whole game is: compute on local disk, copy keepers to `/proj` or off-node before expiry.

## Multi-node workflow (distributed systems)

A multi-node experiment wires all nodes onto a private experiment LAN. On each node,
`/etc/hosts` maps the LAN names, and passwordless SSH between nodes is preconfigured
(shared key in `~/.ssh`).

```bash
# Enumerate your nodes (LAN short names like node0, node1, ...; the IPs are the
# 10.x experiment network, NOT the public control interface). Use grep -o to pull
# the bare nodeN token -- field 2 of /etc/hosts is "nodeN-link-1", not "nodeN":
grep -oE '\bnode[0-9]+\b' /etc/hosts | sort -u
# Or authoritatively from the manifest. client_id also tags interfaces (node0:eth1)
# and links (link-1), so filter to node ids:
geni-get manifest | grep -oE 'client_id="node[0-9]+"'

# Fan out a command to every node:
for n in node1 node2 node3; do ssh "$n" 'hostname; nproc'; done

# MPI across nodes (no scheduler -- pass the host list yourself):
mpirun --host node1,node2,node3 -np 3 ./my_app
# or with a hostfile; or use pdsh/ansible for config fan-out.
```

- The `10.10.x.x` (or similar) addresses are the **experiment LAN** -- use these for
  inter-node traffic and benchmarking, not the public `*.cloudlab.us` control interface.
- Pick one node as the head/coordinator; the rest are workers. There is no master node
  concept enforced by the testbed -- it's whatever your code decides.

## Perf / systems research notes

Bare metal + root is the whole point -- you can do things shared clusters forbid:

- **`perf` works fully.** You're root, so `perf record/stat/top`, hardware counters, and PMU
  access aren't gated by a low `perf_event_paranoid`. Set it if needed:
  `sudo sysctl kernel.perf_event_paranoid=-1`.
- **CPU is yours.** Set the frequency governor (`sudo cpupower frequency-set -g performance`),
  disable turbo, or toggle SMT/hyperthreading for stable measurements.
- **NUMA & pinning:** inspect with `numactl -H` / `lscpu`; pin with `numactl --cpunodebind`
  or `taskset -c`. Bare metal means topology is real, not virtualized.
- **Caches:** drop page cache between runs with
  `sync; echo 3 | sudo tee /proc/sys/vm/drop_caches`.
- For deeper profiling, this repo ships `cpp-profile` and `gpu-profile` skills -- use them.

## Common operations

```bash
geni-get slice_urn          # which experiment/project am I in
geni-get manifest           # full topology rspec (nodes, types, links)
sudo <anything>             # passwordless root
hostname                    # full node/experiment/project/cluster name (plain hostname, NOT -f)
df -h ; mount               # real storage layout on this node
```

- **Provisioning lifecycle is portal-driven:** instantiate, extend, and terminate
  experiments from the CloudLab web portal (or `geni-lib`/`cloudlab` API if scripted).
  There is no node-side command to extend the clock.
- **The profile's git repo** (if the profile ships one) is checked out at
  `/local/repository` on each node -- that's where profile setup scripts live.

## Troubleshooting

- **`command not found` for `sbatch`/`srun`/`module`/`mychpc`:** expected -- this is not an
  HPC cluster. Use `apt`, `/share`, or install it. (If you think you're on CHPC, you're not:
  check `hostname`.)
- **Node unreachable / wedged:** reboot it from the web portal (or `sudo reboot` if you can
  still log in). A reboot keeps the disk; **terminate** destroys it.
- **`/` full:** something wrote bulk data to the root disk. Move it to `/local` or
  `/proj/<Project>`; check with `du -xhd1 / | sort -h`.
- **Experiment about to expire:** extend it on the portal *now*, and copy anything you need
  off local disk -- expiry reclaims the nodes and wipes their disks.
- **NFS feels slow:** you're doing hot I/O on `/proj` or `/users`. Move the working set to
  node-local disk and only copy results back.
- **Lost work after re-instantiating:** local disk does not persist across experiments. Only
  `/users` and `/proj` survive -- put anything reusable there.
