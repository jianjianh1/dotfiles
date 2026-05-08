#!/usr/bin/env python3
"""
Find CHPC SLURM allocations and QOS choices for the current user.

The default mode only queries associations for the invoking user. Use
--all-visible to search broader account/QOS metadata your normal permissions
can read; user names are never displayed in that mode.
"""

import argparse
import csv
import fnmatch
import json
import os
import re
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from io import StringIO
from typing import Dict, Iterable, List, Optional, Sequence, Set, Tuple


ASSOC_FIELDS = [
    "Cluster",
    "Account",
    "User",
    "Partition",
    "QOS",
    "DefaultQOS",
]

QOS_FIELDS = [
    "Name",
    "Priority",
    "MaxWall",
    "MaxTRESPU",
    "MaxTRESPA",
    "MaxTRESPerJob",
    "GrpTRES",
    "GrpTRESMins",
    "Flags",
]

SHARE_FIELDS = [
    "Account",
    "User",
    "RawShares",
    "NormShares",
    "RawUsage",
    "EffectvUsage",
    "FairShare",
    "LevelFS",
    "TRESRunMins",
]

DEFAULT_SORT = ("cluster", "account", "qos")


class QOSInfo:
    def __init__(
        self,
        name,
        priority="",
        max_wall="",
        max_tres_pu="",
        max_tres_pa="",
        max_tres_per_job="",
        grp_tres="",
        grp_tres_mins="",
        flags="",
    ):
        self.name = name
        self.priority = priority
        self.max_wall = max_wall
        self.max_tres_pu = max_tres_pu
        self.max_tres_pa = max_tres_pa
        self.max_tres_per_job = max_tres_per_job
        self.grp_tres = grp_tres
        self.grp_tres_mins = grp_tres_mins
        self.flags = flags


class ShareInfo:
    def __init__(
        self,
        account,
        user="",
        raw_shares="",
        norm_shares="",
        raw_usage="",
        effective_usage="",
        fairshare="",
        level_fs="",
        tres_run_mins="",
    ):
        self.account = account
        self.user = user
        self.raw_shares = raw_shares
        self.norm_shares = norm_shares
        self.raw_usage = raw_usage
        self.effective_usage = effective_usage
        self.fairshare = fairshare
        self.level_fs = level_fs
        self.tres_run_mins = tres_run_mins


class AllocationRow:
    def __init__(
        self,
        cluster,
        account,
        user,
        partition,
        qos,
        default_qos,
        qos_info=None,
        share_info=None,
        tags=(),
        gpu_types=(),
        cpu_features=(),
    ):
        self.cluster = cluster
        self.account = account
        self.user = user
        self.partition = partition
        self.qos = qos
        self.default_qos = default_qos
        self.qos_info = qos_info if qos_info is not None else QOSInfo("")
        self.share_info = share_info
        self.tags = tags
        self.gpu_types = gpu_types
        self.cpu_features = cpu_features
        self.free_nodes = ""
        self.free_cpus = ""
        self.free_gpus = ""
        self.wait_seconds: Optional[int] = None

    @property
    def is_default(self) -> bool:
        return bool(self.default_qos) and self.qos == self.default_qos

    def to_dict(
        self,
        wide: bool = False,
        include_avail: bool = False,
        include_wait: bool = True,
    ) -> Dict[str, str]:
        data = {
            "cluster": self.cluster,
            "account": self.account,
            "qos": self.qos,
            "default": "yes" if self.is_default else "",
            "wall": self.qos_info.max_wall,
            "priority": self.qos_info.priority,
            "fairshare": self.share_info.fairshare if self.share_info else "",
            "usage": self.share_info.raw_usage if self.share_info else "",
            "tags": ",".join(self.tags),
        }
        if wide:
            data.update(
                {
                    "partition": self.partition,
                    "gpu_types": ",".join(self.gpu_types),
                    "cpu_features": ",".join(self.cpu_features),
                    "default_qos": self.default_qos,
                    "max_tres_per_user": self.qos_info.max_tres_pu,
                    "max_tres_per_account": self.qos_info.max_tres_pa,
                    "max_tres_per_job": self.qos_info.max_tres_per_job,
                    "grp_tres": self.qos_info.grp_tres,
                    "grp_tres_mins": self.qos_info.grp_tres_mins,
                    "flags": self.qos_info.flags,
                    "raw_shares": self.share_info.raw_shares if self.share_info else "",
                    "norm_shares": self.share_info.norm_shares if self.share_info else "",
                    "effective_usage": self.share_info.effective_usage if self.share_info else "",
                    "level_fs": self.share_info.level_fs if self.share_info else "",
                    "tres_run_mins": self.share_info.tres_run_mins if self.share_info else "",
                }
            )
        if include_avail:
            if include_wait:
                data["wait"] = _format_wait(self.wait_seconds)
            data["free_nodes"] = self.free_nodes
            data["free_cpus"] = self.free_cpus
            data["free_gpus"] = self.free_gpus
        return data


class CommandError(RuntimeError):
    pass


DESCRIPTION = """\
Find CHPC SLURM account/QOS allocations and recommended SBATCH triples for
the current user. Cross-references your account/QOS associations (sacctmgr)
with live cluster GPU inventory (sinfo --clusters=all).

Filter values for --cluster/--account/--qos/--gpu-type are matched as
case-insensitive substrings, so --cluster NOTCH matches notchpeak.
"""

EPILOG = """\
Examples:
  chpc-allocs                              # all of your allocations
  chpc-allocs --cluster notchpeak --gpu    # GPU rows on notchpeak only
  chpc-allocs --gpu-type a100 --sbatch     # a100 + a100_80gb_pcie + MIG slices
  chpc-allocs --gpu-type 'h*'              # any Hopper / H-series
  chpc-allocs --gpu-type h100nvl --no-freecycle --no-guest
  chpc-allocs --cpu-type emr               # Intel Emerald Rapids partitions
  chpc-allocs --cpu-type gen --gpu-type h100nvl --sbatch
  chpc-allocs                              # default: ranked by predicted wait time
  chpc-allocs --gpus a100:4 --cpus 16 --time 4:00:00  # tune probe to your job
  chpc-allocs --wait-for a100:4            # focused: a100x4 wait across allocs
  chpc-allocs --wait-for cpu:32            # focused: 32-core CPU wait
  chpc-allocs --no-wait                    # skip sbatch --test-only probe (faster)
  chpc-allocs --no-avail                   # skip live sinfo too (legacy view)
  chpc-allocs --sort cluster,qos           # restore alphabetical ordering
  chpc-allocs --gpu-type a100              # only a100-bearing rows + live free counts
  chpc-allocs --list-gpus                  # cluster/partition GPU inventory (free/total)
  chpc-allocs --list-cpus                  # cluster/partition feature inventory + free
  chpc-allocs --wide --format csv > allocs.csv
  chpc-allocs --min-wall 7-00:00:00        # only QOS allowing >= 1 week jobs
  chpc-allocs --all-visible --account sadayappan
"""


def _lower_choice(value: str) -> str:
    return value.lower()


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=DESCRIPTION,
        epilog=EPILOG,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--cluster", action="append", metavar="NAME",
        help="Filter by cluster name (substring, case-insensitive). Repeatable; matches any.",
    )
    parser.add_argument(
        "--account", action="append", metavar="NAME",
        help="Filter by account name (substring, case-insensitive). Repeatable; matches any.",
    )
    parser.add_argument(
        "--qos", action="append", metavar="NAME",
        help="Filter by QOS name (substring, case-insensitive). Repeatable; matches any.",
    )
    parser.add_argument(
        "--default-only", action="store_true",
        help="Show only the rows where this QOS is the default for its association.",
    )
    parser.add_argument(
        "--gpu", action="store_true",
        help="Show rows whose SLURM metadata mentions GPU. Coarse — for specific hardware use --gpu-type.",
    )
    parser.add_argument(
        "--cpu", action="store_true",
        help="Show rows whose SLURM metadata does NOT mention GPU. Mutually exclusive with --gpu.",
    )
    parser.add_argument(
        "--gpu-type", action="append", metavar="PATTERN",
        help="Filter to allocations on partitions exposing this GPU type. "
        "Glob-style: a bare value like 'a100' is auto-wrapped to *a100* (matches "
        "a100 + MIG variants). Use explicit globs for prefix/suffix matches: "
        "'h*' (Hopper), '*nvl', 'rtx*'. Case-insensitive; repeatable; matches "
        "any. See --list-gpus.",
    )
    parser.add_argument(
        "--cpu-type", action="append", metavar="PATTERN",
        help="Filter by sinfo Features (CPU/node architecture tokens), e.g. "
        "skl, csl, mil (notchpeak), gen (Genoa), emr (Emerald Rapids). "
        "Same glob rules as --gpu-type. Repeatable; matches any. See --list-cpus.",
    )
    parser.add_argument(
        "--list-gpus", action="store_true",
        help="Print cluster/partition -> GPU type:count inventory from sinfo and exit. "
        "Independent of your allocations.",
    )
    parser.add_argument(
        "--list-cpus", action="store_true",
        help="Print cluster/partition -> features inventory from sinfo and exit. "
        "Independent of your allocations.",
    )
    parser.add_argument(
        "--freecycle", action="store_true",
        help="Show only freecycle (preemptable, no fairshare cost) rows.",
    )
    parser.add_argument(
        "--no-freecycle", action="store_true",
        help="Hide freecycle rows. Mutually exclusive with --freecycle.",
    )
    parser.add_argument(
        "--guest", action="store_true",
        help="Show only guest (preemptable, runs on idle owner nodes) rows.",
    )
    parser.add_argument(
        "--no-guest", action="store_true",
        help="Hide guest rows. Mutually exclusive with --guest.",
    )
    parser.add_argument(
        "--reservation", action="store_true",
        help="Show only QOS that require a reservation.",
    )
    parser.add_argument(
        "--min-wall", metavar="DURATION",
        help="Minimum MaxWall. Accepts HH:MM:SS, D-HH:MM:SS, Nd, or 'unlimited'. "
        "Examples: 12:00:00, 3-00:00:00, 14d.",
    )
    parser.add_argument(
        "--fairshare-min", type=float, metavar="FLOAT",
        help="Drop rows whose FairShare is below this value (requires sshare data).",
    )
    parser.add_argument(
        "--usage-max", type=float, metavar="FLOAT",
        help="Drop rows whose RawUsage exceeds this value (requires sshare data).",
    )
    parser.add_argument(
        "--format", type=_lower_choice, choices=("table", "csv", "json"),
        default="table", metavar="{table,csv,json}",
        help="Output format (case-insensitive). Default: table.",
    )
    parser.add_argument(
        "--wide", action="store_true",
        help="Show extra columns including partition, gpu_types, TRES limits, and flags.",
    )
    parser.add_argument(
        "--sort", default=None, metavar="KEYS",
        help="Comma-separated sort keys (case-insensitive). Valid: "
        "wait, cluster, account, qos, default, wall, priority, fairshare, "
        "usage, tags. Default sort is 'wait,cluster,qos' when wait is "
        "available, else 'cluster,account,qos'.",
    )
    parser.add_argument(
        "--reverse", action="store_true",
        help="Reverse the sort order.",
    )
    parser.add_argument(
        "--no-usage", action="store_true",
        help="Skip the sshare lookup (faster, but FairShare/Usage columns will be empty).",
    )
    parser.add_argument(
        "--no-avail", action="store_true",
        help="Skip the live availability sinfo call; omits the free_nodes/"
        "free_cpus/free_gpus columns. Default is to include them. In table "
        "mode they replace priority/fairshare/usage/default/tags (use --wide "
        "to bring those back).",
    )
    # Hidden no-op kept for backward compatibility — availability is now the default.
    parser.add_argument(
        "--avail", action="store_true", help=argparse.SUPPRESS,
    )
    parser.add_argument(
        "--no-wait", action="store_true",
        help="Skip the sbatch --test-only probe; omits the 'wait' column. "
        "Default behavior runs one probe per allocation in parallel (~1s).",
    )
    parser.add_argument(
        "--cpus", type=int, metavar="N", default=1,
        help="CPUs per task for the wait probe (default: 1). Increasing this "
        "yields a more realistic 'wait' for jobs that need many cores.",
    )
    parser.add_argument(
        "--mem", metavar="SIZE",
        help="Memory request for the wait probe (e.g. 16G, 128G). Default: unset.",
    )
    parser.add_argument(
        "--nodes", type=int, metavar="N", default=1,
        help="Node count for the wait probe (default: 1).",
    )
    parser.add_argument(
        "--gpus", metavar="SPEC",
        help="GPU shape for the wait probe. Forms: 'a100:4' (type+count), "
        "'4' (any type, that count), 'a100' (1 of that type). Default on GPU "
        "rows is 'gpu:1'; CPU rows are unaffected. Rows whose gpu_types don't "
        "include the requested type skip the probe (wait shows '?').",
    )
    parser.add_argument(
        "--time", metavar="DURATION", default="00:01:00",
        help="Wall time for the wait probe (HH:MM:SS, D-HH:MM:SS, or Nd). "
        "Default: 00:01:00. Larger values bias toward partitions with "
        "long-running headroom.",
    )
    parser.add_argument(
        "--wait-for", metavar="SPEC",
        help="Shorthand: focus the run on a specific job shape. "
        "'a100:4' -> --gpus a100:4 + --gpu-type a100; "
        "'gpu:4'  -> --gpus 4 + --gpu; "
        "'cpu:32' -> --cpus 32 + --cpu; "
        "'32'     -> same as cpu:32.",
    )
    parser.add_argument(
        "--sbatch", action="store_true",
        help="Emit '#SBATCH --account=... --qos=...' blocks for each matching allocation, "
        "instead of a table.",
    )
    parser.add_argument(
        "--all-visible", action="store_true",
        help="Search every association you can read (omits user names). May be slow on "
        "large clusters and disables sshare enrichment.",
    )
    parser.add_argument(
        "--self-test", action="store_true",
        help="Run internal parser/format tests and exit. Does not query SLURM.",
    )
    return parser


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    return _build_parser().parse_args(argv)


def require_tool(name: str) -> str:
    path = shutil.which(name)
    if not path:
        raise CommandError(f"required command not found on PATH: {name}")
    return path


def run_command(args: Sequence[str]) -> str:
    try:
        result = subprocess.run(
            args,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
        )
    except OSError as exc:
        raise CommandError(f"failed to run {args[0]}: {exc}") from exc
    if result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip() or "unknown error"
        raise CommandError(f"{args[0]} failed: {message}")
    return result.stdout


def split_parsable(output: str, field_count: int) -> List[List[str]]:
    rows = []
    for line in output.splitlines():
        line = line.rstrip("\n")
        if not line.strip():
            continue
        if line.endswith("|"):
            line = line[:-1]
        fields = line.split("|")
        if len(fields) < field_count:
            fields.extend([""] * (field_count - len(fields)))
        rows.append(fields[:field_count])
    return rows


def show_associations(user: Optional[str], all_visible: bool) -> List[AllocationRow]:
    sacctmgr = require_tool("sacctmgr")
    args = [
        sacctmgr,
        "show",
        "association",
    ]
    if user and not all_visible:
        args.extend(["where", f"user={user}"])
    args.extend(["format=" + ",".join(ASSOC_FIELDS), "-n", "-P"])

    rows = []
    for fields in split_parsable(run_command(args), len(ASSOC_FIELDS)):
        cluster, account, assoc_user, partition, qos_list, default_qos = [x.strip() for x in fields]
        if not cluster or not account:
            continue
        qoses = [q.strip() for q in qos_list.split(",") if q.strip()]
        if not qoses and default_qos:
            qoses = [default_qos]
        if not qoses:
            qoses = [""]
        for qos in qoses:
            rows.append(
                AllocationRow(
                    cluster=cluster,
                    account=account,
                    user="" if all_visible else assoc_user,
                    partition=partition,
                    qos=qos,
                    default_qos=default_qos,
                )
            )

    return dedupe_rows(rows)


def dedupe_rows(rows: Iterable[AllocationRow]) -> List[AllocationRow]:
    seen = set()
    result = []
    for row in rows:
        key = (row.cluster, row.account, row.qos, row.default_qos, row.partition)
        if key in seen:
            continue
        seen.add(key)
        result.append(row)
    return result


def show_qos(names: Iterable[str]) -> Dict[str, QOSInfo]:
    unique_names = sorted({name for name in names if name})
    if not unique_names:
        return {}
    sacctmgr = require_tool("sacctmgr")
    info: Dict[str, QOSInfo] = {}

    chunk_size = 80
    for index in range(0, len(unique_names), chunk_size):
        chunk = unique_names[index : index + chunk_size]
        args = [
            sacctmgr,
            "show",
            "qos",
            "where",
            "name=" + ",".join(chunk),
            "format=" + ",".join(QOS_FIELDS),
            "-n",
            "-P",
        ]
        for fields in split_parsable(run_command(args), len(QOS_FIELDS)):
            qos = QOSInfo(
                name=fields[0].strip(),
                priority=fields[1].strip(),
                max_wall=fields[2].strip(),
                max_tres_pu=fields[3].strip(),
                max_tres_pa=fields[4].strip(),
                max_tres_per_job=fields[5].strip(),
                grp_tres=fields[6].strip(),
                grp_tres_mins=fields[7].strip(),
                flags=fields[8].strip(),
            )
            if qos.name:
                info[qos.name] = qos
    return info


def show_usage(user: str) -> Dict[str, ShareInfo]:
    sshare = require_tool("sshare")
    args = [
        sshare,
        "-h",
        "-P",
        "-U",
        "-u",
        user,
        "-o",
        ",".join(SHARE_FIELDS),
    ]
    shares: Dict[str, ShareInfo] = {}
    for fields in split_parsable(run_command(args), len(SHARE_FIELDS)):
        share = ShareInfo(
            account=fields[0].strip(),
            user=fields[1].strip(),
            raw_shares=fields[2].strip(),
            norm_shares=fields[3].strip(),
            raw_usage=fields[4].strip(),
            effective_usage=fields[5].strip(),
            fairshare=fields[6].strip(),
            level_fs=fields[7].strip(),
            tres_run_mins=fields[8].strip(),
        )
        if share.account:
            shares[share.account] = share
    return shares


def _split_gres_entries(gres: str) -> List[str]:
    """Split a GRES string on commas, ignoring commas inside parentheses.

    Needed because GresUsed can contain `(IDX:0,2-3)` where the IDX list itself
    holds commas — naive `gres.split(",")` would shred those.
    """
    parts: List[str] = []
    depth = 0
    buf: List[str] = []
    for ch in gres:
        if ch == "(":
            depth += 1
            buf.append(ch)
        elif ch == ")":
            depth = max(0, depth - 1)
            buf.append(ch)
        elif ch == "," and depth == 0:
            parts.append("".join(buf))
            buf = []
        else:
            buf.append(ch)
    if buf:
        parts.append("".join(buf))
    return parts


def parse_gres_per_type(gres: str) -> Dict[str, int]:
    """Parse a GRES string (Gres or GresUsed) into {gpu_type: count}.

    Handles untyped 'gpu:8' (mapped to '_any_'), typed 'gpu:a100:8(IDX:0-7)'
    (parenthetical flags stripped), and entries with commas inside parens.
    Non-gpu entries (nsight, mps, ...) are ignored.
    """
    bucket: Dict[str, int] = {}
    if not gres or gres == "(null)":
        return bucket
    for entry in _split_gres_entries(gres):
        entry = entry.strip().lower()
        if not entry.startswith("gpu"):
            continue
        parts = entry.split(":")
        if len(parts) == 2:
            gtype, count = "_any_", parts[1]
        elif len(parts) >= 3:
            gtype, count = parts[1], parts[2]
        else:
            continue
        count = count.split("(")[0]
        try:
            bucket[gtype] = bucket.get(gtype, 0) + int(count)
        except ValueError:
            bucket.setdefault(gtype, 0)
    return bucket


def parse_gres_line(line: str) -> Tuple[str, str, Dict[str, int]]:
    """Parse one `sinfo --clusters=all -h -O 'Cluster:|,PartitionName:|,Gres:1024'`
    line into (cluster, partition, {type: count}).
    """
    fields = line.split("|", 2)
    if len(fields) < 3:
        return "", "", {}
    cluster, partition, gres = (fields[0].strip(), fields[1].strip(), fields[2].strip())
    if not partition:
        return cluster, partition, {}
    return cluster, partition, parse_gres_per_type(gres)


def parse_cpus_state(value: str) -> Tuple[int, int]:
    """Parse SLURM CPUsState 'alloc/idle/other/total' into (free, total).

    'free' is the idle component. Returns (0, 0) on malformed input.
    """
    parts = (value or "").strip().split("/")
    if len(parts) != 4:
        return 0, 0
    try:
        return int(parts[1]), int(parts[3])
    except ValueError:
        return 0, 0


# State suffixes per `man sinfo`: * not responding, ~ powered off, # powering up,
# $ in reservation, @ pending reboot, ! powering down, ^ reboot issued, + planned,
# - pending reboot (some versions). We treat any base==idle/mix as free, but a
# trailing '*' (not responding) blocks job dispatch so it's never free.
_NODE_STATE_SUFFIX_CHARS = "*~#$@!^+-"


def is_free_node_state(state: str) -> bool:
    s = (state or "").strip().lower()
    if not s or s.endswith("*"):
        return False
    base = s.rstrip(_NODE_STATE_SUFFIX_CHARS)
    return base in {"idle", "mix"}


class PartitionAvail:
    """Live capacity for one (cluster, partition): nodes/cpus/gpus as (free, total)."""

    def __init__(self) -> None:
        self.nodes_free = 0
        self.nodes_total = 0
        self.cpus_free = 0
        self.cpus_total = 0
        self.gpus: Dict[str, List[int]] = {}  # type -> [free, total]

    def add_gpu(self, gtype: str, free: int, total: int) -> None:
        slot = self.gpus.setdefault(gtype, [0, 0])
        slot[0] += free
        slot[1] += total


def _strip_partition_marker(name: str) -> str:
    """Sinfo marks a cluster's default partition with a trailing '*'."""
    return name[:-1] if name.endswith("*") else name


def show_partition_availability() -> Dict[str, Dict[str, PartitionAvail]]:
    """Return {cluster: {partition: PartitionAvail}} from a single per-node sinfo.

    Counts nodes_total/cpus_total/gpus_total from configured capacity (every
    listed node), but only credits a node's idle CPUs/GPUs as 'free' when the
    node state is idle or mix (and not '*'/non-responding).
    """
    sinfo = require_tool("sinfo")
    args = [
        sinfo,
        "--clusters=all",
        "-h",
        "-N",
        "-O",
        "Cluster:|,NodeHost:|,Partition:|,StateCompact:|,CPUsState:|,Gres:1024|,GresUsed:1024|",
    ]
    result: Dict[str, Dict[str, PartitionAvail]] = {}
    try:
        output = run_command(args)
    except CommandError:
        return result
    for line in output.splitlines():
        if not line.strip():
            continue
        # The Gres/GresUsed columns are 1024-wide so the line is fixed-width;
        # split off the first 5 pipe-fields, the rest is the two GRES blobs.
        fields = line.split("|")
        if len(fields) < 7:
            continue
        cluster = fields[0].strip()
        node = fields[1].strip()
        partition = _strip_partition_marker(fields[2].strip())
        state = fields[3].strip()
        cpus_state = fields[4].strip()
        gres_total = fields[5].strip()
        gres_used = fields[6].strip()
        if not cluster or not partition or not node:
            continue
        free_node = is_free_node_state(state)
        cpus_idle, cpus_total = parse_cpus_state(cpus_state)
        gpu_total = parse_gres_per_type(gres_total)
        gpu_used = parse_gres_per_type(gres_used)

        bucket = result.setdefault(cluster, {}).setdefault(partition, PartitionAvail())
        bucket.nodes_total += 1
        bucket.cpus_total += cpus_total
        if free_node:
            bucket.nodes_free += 1
            bucket.cpus_free += cpus_idle
        for gtype, total in gpu_total.items():
            used = gpu_used.get(gtype, 0)
            free = max(0, total - used) if free_node else 0
            bucket.add_gpu(gtype, free, total)
    return result


class ProbeShape:
    """Shape of the hypothetical job used for `sbatch --test-only` wait probing.

    Defaults reproduce the historical behavior: 1 node, 1 CPU, 1-minute wall,
    `--gres=gpu:1` on GPU rows, no GRES on CPU rows. When the user supplies
    flags (--cpus/--mem/--nodes/--gpus/--time), this carries them into the
    probe so the predicted wait reflects the actual job they intend to run.
    """

    def __init__(
        self,
        nodes: int = 1,
        cpus: int = 1,
        mem: Optional[str] = None,
        gpu_type: Optional[str] = None,
        gpu_count: Optional[int] = None,
        time: str = "00:01:00",
    ) -> None:
        self.nodes = nodes
        self.cpus = cpus
        self.mem = mem
        self.gpu_type = gpu_type.lower() if gpu_type else None
        self.gpu_count = gpu_count
        self.time = time

    def gres_for(self, row: "AllocationRow") -> Optional[str]:
        """Return the --gres value for this row, or None to omit the flag."""
        if "gpu" not in row.tags:
            return None
        count = self.gpu_count if self.gpu_count is not None else 1
        if self.gpu_type:
            return f"gpu:{self.gpu_type}:{count}"
        return f"gpu:{count}"

    def to_sbatch_args(self, row: "AllocationRow") -> List[str]:
        args = ["-N", str(self.nodes), "-n", str(self.cpus), "-t", self.time]
        if self.mem:
            args.append(f"--mem={self.mem}")
        gres = self.gres_for(row)
        if gres:
            args.append(f"--gres={gres}")
        return args

    def should_skip(self, row: "AllocationRow") -> bool:
        """True when this shape can't possibly run on this row (skip the probe)."""
        gpu_requested = self.gpu_type is not None or self.gpu_count is not None
        if not gpu_requested:
            return False
        if "gpu" not in row.tags:
            return True
        if self.gpu_type and row.gpu_types:
            # Empty row.gpu_types just means metadata wasn't loaded.
            return not any_glob_match(row.gpu_types, [self.gpu_type])
        return False


def _parse_positive_int(text: str, error: str) -> int:
    if not text or not text.isdigit() or int(text) <= 0:
        raise CommandError(error)
    return int(text)


def parse_gpu_spec(spec: str) -> Tuple[Optional[str], int]:
    """Parse a --gpus value into (gpu_type, count).

    Forms:
      'a100:4' -> ('a100', 4)
      '4'      -> (None, 4)       # any GPU type
      'a100'   -> ('a100', 1)
    """
    err = f"invalid --gpus spec: {spec!r}"
    s = (spec or "").strip().lower()
    if not s:
        raise CommandError(err)
    if ":" in s:
        type_, _, count = s.partition(":")
        type_ = type_.strip()
        if not type_:
            raise CommandError(err)
        return (type_, _parse_positive_int(count.strip(), err))
    if s.isdigit():
        return (None, _parse_positive_int(s, err))
    return (s, 1)


def apply_wait_for_shorthand(args: argparse.Namespace) -> None:
    """Translate `--wait-for SPEC` into the matching probe-shape + filter flags.

    Forms:
      cpu:N or bare N  -> --cpus N + --cpu
      gpu:N            -> --gpus N + --gpu       (any GPU type)
      TYPE[:N]         -> --gpus TYPE[:N] + adds TYPE to --gpu-type
    """
    spec = getattr(args, "wait_for", None)
    if not spec:
        return
    s = spec.strip().lower()
    err = f"invalid --wait-for spec: {spec!r}"
    if not s:
        raise CommandError(err)
    if s.startswith("cpu:") or s.isdigit():
        args.cpus = _parse_positive_int(s[4:] if s.startswith("cpu:") else s, err)
        args.cpu = True
        return
    if s.startswith("gpu:"):
        args.gpus = str(_parse_positive_int(s[4:], err))
        args.gpu = True
        return
    try:
        gtype, _count = parse_gpu_spec(s)
    except CommandError:
        raise CommandError(err) from None
    args.gpus = s
    args.gpu_type = (args.gpu_type or []) + [gtype]


# Matches the relevant part of `sbatch --test-only`'s stderr line:
# "sbatch: Job 12345 to start at 2026-05-08T03:00:00 using 1 processors on nodes ..."
_TEST_ONLY_RE = re.compile(r"to start at (\S+)")


def parse_test_only_stderr(text: str) -> Optional[datetime]:
    """Extract the predicted start datetime from `sbatch --test-only` stderr.

    Returns None when SLURM produced an allocation failure or unexpected output.
    """
    match = _TEST_ONLY_RE.search(text or "")
    if not match:
        return None
    try:
        return datetime.strptime(match.group(1), "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        return None


def _format_wait(seconds: Optional[int]) -> str:
    """Render a wait-time delta compactly. None → '?'; 0 → 'now'; etc."""
    if seconds is None:
        return "?"
    if seconds <= 60:
        return "now"
    minutes = seconds // 60
    if minutes < 60:
        return f"{minutes}m"
    hours, minutes = divmod(minutes, 60)
    if hours < 24:
        if minutes:
            return f"{hours}h{minutes}m"
        return f"{hours}h"
    days, hours = divmod(hours, 24)
    if hours:
        return f"{days}d{hours}h"
    return f"{days}d"


def predict_wait(
    row: "AllocationRow",
    timeout: float = 10.0,
    shape: Optional[ProbeShape] = None,
) -> Optional[int]:
    """Return seconds-until-start for a probe job shaped like `shape`
    (default: 1 CPU + 1 GPU on GPU rows + 1-minute wall), or None if SLURM
    rejects the probe / can't predict.

    Iterates through `_candidate_partitions(row)` because some QOS names don't
    match the partition (e.g. `granite-freecycle` QOS lives on `granite`
    partition; the existing helper produces both candidates in order).
    """
    if shape is None:
        shape = ProbeShape()
    if shape.should_skip(row):
        return None
    sbatch = shutil.which("sbatch")
    if not sbatch or not row.account or not row.qos:
        return None
    candidates = [c for c in _candidate_partitions(row) if c]
    if not candidates:
        return None
    for partition in candidates:
        args = [
            sbatch,
            "--test-only",
            "-M", row.cluster,
            "-A", row.account,
            "-p", partition,
            "-q", row.qos,
        ]
        args.extend(shape.to_sbatch_args(row))
        args.append("--wrap=true")
        try:
            result = subprocess.run(
                args,
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                universal_newlines=True,
                timeout=timeout,
            )
        except (OSError, subprocess.TimeoutExpired):
            return None
        # `--test-only` prints to stderr regardless of success.
        start = parse_test_only_stderr(result.stderr) or parse_test_only_stderr(result.stdout)
        if start is not None:
            delta = (start - datetime.now()).total_seconds()
            return max(0, int(delta))
    return None


def predict_wait_times(
    rows: List["AllocationRow"],
    max_workers: int = 8,
    shape: Optional[ProbeShape] = None,
) -> None:
    """Populate `row.wait_seconds` for every row, in parallel."""
    if not rows or shutil.which("sbatch") is None:
        return
    if shape is None:
        shape = ProbeShape()
    with ThreadPoolExecutor(max_workers=max_workers) as pool:
        futures = {pool.submit(predict_wait, row, shape=shape): row for row in rows}
        for future in as_completed(futures):
            row = futures[future]
            try:
                row.wait_seconds = future.result()
            except Exception:
                row.wait_seconds = None


def show_partition_gpus() -> Dict[str, Dict[str, Dict[str, int]]]:
    """Return {cluster: {partition: {gpu_type: count}}} from sinfo across all clusters."""
    sinfo = require_tool("sinfo")
    args = [sinfo, "--clusters=all", "-h", "-O", "Cluster:|,PartitionName:|,Gres:1024"]
    result: Dict[str, Dict[str, Dict[str, int]]] = {}
    try:
        output = run_command(args)
    except CommandError:
        return result
    for line in output.splitlines():
        cluster, partition, bucket = parse_gres_line(line)
        if not cluster or not partition or not bucket:
            continue
        per_cluster = result.setdefault(cluster, {})
        existing = per_cluster.setdefault(partition, {})
        for gtype, count in bucket.items():
            existing[gtype] = existing.get(gtype, 0) + count
    return result


# QOS suffixes that don't appear on the corresponding partition name on CHPC
# (e.g. QOS 'granite-gpu-freecycle' -> partition 'granite-gpu').
_QOS_SUFFIXES = ("-freecycle", "-guest", "-res")


def _candidate_partitions(row: "AllocationRow") -> List[str]:
    candidates: List[str] = []
    if row.partition:
        candidates.append(row.partition)
    if row.qos:
        candidates.append(row.qos)
        for suffix in _QOS_SUFFIXES:
            if row.qos.endswith(suffix):
                stripped = row.qos[: -len(suffix)]
                if stripped and stripped not in candidates:
                    candidates.append(stripped)
    return candidates


def resolve_row_gpu_types(
    row: "AllocationRow",
    partition_gpus: Dict[str, Dict[str, Dict[str, int]]],
) -> Tuple[str, ...]:
    per_cluster = partition_gpus.get(row.cluster, {})
    seen: Dict[str, None] = {}
    for candidate in _candidate_partitions(row):
        for gtype in per_cluster.get(candidate, {}):
            seen[gtype] = None
    return tuple(sorted(seen))


def format_gpu_summary(
    partition_avail: Dict[str, Dict[str, PartitionAvail]],
) -> str:
    """Render cluster/partition GPU inventory as 'gtype:free/total'."""
    pairs: List[Tuple[str, str, Dict[str, List[int]]]] = []
    for cluster, parts in partition_avail.items():
        for partition, bucket in parts.items():
            if bucket.gpus:
                pairs.append((cluster, partition, bucket.gpus))
    if not pairs:
        return "(no GPU partitions found)"
    cluster_w = max(len(c) for c, _, _ in pairs)
    partition_w = max(len(p) for _, p, _ in pairs)
    lines = []
    for cluster, partition, gpus in sorted(pairs):
        rendered = ", ".join(
            f"{gtype}:{free}/{total}"
            for gtype, (free, total) in sorted(gpus.items())
        )
        lines.append(f"{cluster.ljust(cluster_w)}  {partition.ljust(partition_w)}  {rendered}")
    return "\n".join(lines)


def parse_features_line(line: str) -> Tuple[str, str, Set[str]]:
    """Parse `sinfo --clusters=all -h -O 'Cluster:|,PartitionName:|,Features:1024'`.

    Returns (cluster, partition, set-of-lowercased-feature-tokens). Empty set
    when the partition has no features ((null) or blank).
    """
    fields = line.split("|", 2)
    if len(fields) < 3:
        return "", "", set()
    cluster, partition, feats = (f.strip() for f in fields)
    if not cluster or not partition or not feats or feats == "(null)":
        return cluster, partition, set()
    return cluster, partition, {t.strip().lower() for t in feats.split(",") if t.strip()}


def show_partition_features() -> Dict[str, Dict[str, Set[str]]]:
    """Return {cluster: {partition: {feature, ...}}} from sinfo across all clusters."""
    sinfo = require_tool("sinfo")
    args = [sinfo, "--clusters=all", "-h", "-O", "Cluster:|,PartitionName:|,Features:1024"]
    result: Dict[str, Dict[str, Set[str]]] = {}
    try:
        output = run_command(args)
    except CommandError:
        return result
    for line in output.splitlines():
        cluster, partition, feats = parse_features_line(line)
        if not cluster or not partition or not feats:
            continue
        bucket = result.setdefault(cluster, {}).setdefault(partition, set())
        bucket |= feats
    return result


def resolve_row_features(
    row: "AllocationRow",
    partition_features: Dict[str, Dict[str, Set[str]]],
) -> Tuple[str, ...]:
    per_cluster = partition_features.get(row.cluster, {})
    seen: Set[str] = set()
    for cand in _candidate_partitions(row):
        seen |= per_cluster.get(cand, set())
    return tuple(sorted(seen))


def format_cpu_summary(
    partition_features: Dict[str, Dict[str, Set[str]]],
    partition_avail: Optional[Dict[str, Dict[str, PartitionAvail]]] = None,
) -> str:
    """Render cluster/partition feature inventory; appends node/cpu free/total
    when availability data is provided."""
    if not partition_features:
        return "(no partition features found)"
    pairs: List[Tuple[str, str, Set[str]]] = []
    for cluster in partition_features:
        for partition, feats in partition_features[cluster].items():
            pairs.append((cluster, partition, feats))
    if not pairs:
        return "(no partition features found)"
    cluster_w = max(len(c) for c, _, _ in pairs)
    partition_w = max(len(p) for _, p, _ in pairs)

    def _avail_for(cluster: str, partition: str) -> str:
        if partition_avail is None:
            return ""
        bucket = partition_avail.get(cluster, {}).get(partition)
        if bucket is None:
            return ""
        return f"  nodes:{bucket.nodes_free}/{bucket.nodes_total} cpus:{bucket.cpus_free}/{bucket.cpus_total}"

    lines = []
    for cluster, partition, feats in sorted(pairs):
        rendered = ",".join(sorted(feats))
        lines.append(
            f"{cluster.ljust(cluster_w)}  {partition.ljust(partition_w)}  "
            f"{rendered}{_avail_for(cluster, partition)}"
        )
    return "\n".join(lines)


def attach_metadata(
    rows: List[AllocationRow],
    include_usage: bool,
    user: str,
    partition_gpus: Optional[Dict[str, Dict[str, Dict[str, int]]]] = None,
    partition_features: Optional[Dict[str, Dict[str, Set[str]]]] = None,
    partition_avail: Optional[Dict[str, Dict[str, PartitionAvail]]] = None,
) -> None:
    qos_info = show_qos(row.qos for row in rows)
    share_info = {} if include_usage is False else show_usage(user)
    partition_gpus = partition_gpus or {}
    partition_features = partition_features or {}
    for row in rows:
        row.qos_info = qos_info.get(row.qos, QOSInfo(row.qos))
        row.share_info = share_info.get(row.account)
        row.gpu_types = resolve_row_gpu_types(row, partition_gpus)
        row.cpu_features = resolve_row_features(row, partition_features)
        row.tags = classify(row)
        if partition_avail is not None:
            attach_row_availability(row, partition_avail)


def attach_row_availability(
    row: AllocationRow,
    partition_avail: Dict[str, Dict[str, PartitionAvail]],
) -> None:
    """Roll up live availability across this row's candidate partitions."""
    per_cluster = partition_avail.get(row.cluster, {})
    nodes_free = nodes_total = 0
    cpus_free = cpus_total = 0
    gpus: Dict[str, List[int]] = {}
    seen_partitions: Set[str] = set()
    matched = False
    for cand in _candidate_partitions(row):
        bucket = per_cluster.get(cand)
        if bucket is None or cand in seen_partitions:
            continue
        seen_partitions.add(cand)
        matched = True
        nodes_free += bucket.nodes_free
        nodes_total += bucket.nodes_total
        cpus_free += bucket.cpus_free
        cpus_total += bucket.cpus_total
        for gtype, (free, total) in bucket.gpus.items():
            slot = gpus.setdefault(gtype, [0, 0])
            slot[0] += free
            slot[1] += total
    if not matched:
        return
    row.free_nodes = f"{nodes_free}/{nodes_total}"
    row.free_cpus = f"{cpus_free}/{cpus_total}"
    if gpus:
        row.free_gpus = ", ".join(
            f"{gtype}:{free}/{total}"
            for gtype, (free, total) in sorted(gpus.items())
        )


def classify(row: AllocationRow) -> Tuple[str, ...]:
    haystack = " ".join(
        [
            row.cluster,
            row.account,
            row.qos,
            row.default_qos,
            row.partition,
            row.qos_info.max_tres_pu,
            row.qos_info.max_tres_pa,
            row.qos_info.max_tres_per_job,
            row.qos_info.grp_tres,
            row.qos_info.flags,
        ]
    ).lower()
    tags = []
    if "gpu" in haystack or "gres/gpu" in haystack:
        tags.append("gpu")
    else:
        tags.append("cpu")
    if "freecycle" in haystack or "noreserve" in haystack:
        tags.append("freecycle")
    if "guest" in haystack:
        tags.append("guest")
    if "requiresreservation" in haystack or "reservation" in haystack:
        tags.append("reservation")
    if row.is_default:
        tags.append("default")
    return tuple(tags)


_GLOB_META = ("*", "?", "[")


def _to_glob(pattern: str) -> str:
    """Lowercase a pattern; wrap as *pat* if no glob meta-chars are present."""
    p = pattern.lower()
    if not any(c in p for c in _GLOB_META):
        return f"*{p}*"
    return p


def any_glob_match(values: Iterable[str], patterns: Iterable[str]) -> bool:
    """True if any value matches any pattern (case-insensitive, fnmatch)."""
    globs = [_to_glob(p) for p in patterns]
    if not globs:
        return False
    for value in values:
        v = value.lower()
        if any(fnmatch.fnmatchcase(v, g) for g in globs):
            return True
    return False


def parse_wall_seconds(value: str) -> Optional[int]:
    value = (value or "").strip().lower()
    if not value:
        return None
    if value in {"none", "unlimited", "infinite"}:
        return 10**15
    if value.endswith("d") and value[:-1].isdigit():
        return int(value[:-1]) * 86400
    day_part = 0
    time_part = value
    if "-" in value:
        day_text, time_part = value.split("-", 1)
        if not day_text.isdigit():
            return None
        day_part = int(day_text)
    parts = time_part.split(":")
    if not all(part.isdigit() for part in parts):
        return None
    if len(parts) == 3:
        hours, minutes, seconds = map(int, parts)
    elif len(parts) == 2:
        hours = 0
        minutes, seconds = map(int, parts)
    elif len(parts) == 1:
        hours = int(parts[0])
        minutes = 0
        seconds = 0
    else:
        return None
    return day_part * 86400 + hours * 3600 + minutes * 60 + seconds


def parse_float(value: str) -> Optional[float]:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def matches_any(value: str, patterns: Optional[List[str]]) -> bool:
    if not patterns:
        return True
    lower = value.lower()
    return any(pattern.lower() in lower for pattern in patterns)


def filter_rows(rows: List[AllocationRow], args: argparse.Namespace) -> List[AllocationRow]:
    min_wall = parse_wall_seconds(args.min_wall) if args.min_wall else None
    if args.min_wall and min_wall is None:
        raise CommandError(f"invalid --min-wall value: {args.min_wall}")

    result = []
    for row in rows:
        tags = set(row.tags)
        if not matches_any(row.cluster, args.cluster):
            continue
        if not matches_any(row.account, args.account):
            continue
        if not matches_any(row.qos, args.qos):
            continue
        if args.default_only and not row.is_default:
            continue
        if args.gpu and "gpu" not in tags:
            continue
        if args.cpu and "gpu" in tags:
            continue
        if args.gpu_type and not any_glob_match(row.gpu_types, args.gpu_type):
            continue
        if args.cpu_type and not any_glob_match(row.cpu_features, args.cpu_type):
            continue
        if args.freecycle and "freecycle" not in tags:
            continue
        if args.no_freecycle and "freecycle" in tags:
            continue
        if args.guest and "guest" not in tags:
            continue
        if args.no_guest and "guest" in tags:
            continue
        if args.reservation and "reservation" not in tags:
            continue
        if min_wall is not None:
            wall = parse_wall_seconds(row.qos_info.max_wall)
            if wall is None or wall < min_wall:
                continue
        if args.fairshare_min is not None:
            fairshare = parse_float(row.share_info.fairshare if row.share_info else "")
            if fairshare is None or fairshare < args.fairshare_min:
                continue
        if args.usage_max is not None:
            usage = parse_float(row.share_info.raw_usage if row.share_info else "")
            if usage is None or usage > args.usage_max:
                continue
        result.append(row)
    return result


_WAIT_SENTINEL = 10**12  # sorts unknown waits to the end (still < float('inf') headaches)


def sort_rows(rows: List[AllocationRow], sort_spec: str, reverse: bool) -> List[AllocationRow]:
    keys = [key.strip().lower() for key in sort_spec.split(",") if key.strip()] or list(DEFAULT_SORT)
    allowed = {
        "cluster",
        "account",
        "qos",
        "default",
        "wall",
        "priority",
        "fairshare",
        "usage",
        "tags",
        "wait",
    }
    unknown = [key for key in keys if key not in allowed]
    if unknown:
        raise CommandError("unknown sort key(s): " + ", ".join(unknown))

    def key_for(row: AllocationRow) -> Tuple[object, ...]:
        values = []
        data = row.to_dict()
        for key in keys:
            if key == "wait":
                values.append(_WAIT_SENTINEL if row.wait_seconds is None else row.wait_seconds)
            elif key == "wall":
                values.append(parse_wall_seconds(row.qos_info.max_wall) or -1)
            elif key in {"priority", "fairshare", "usage"}:
                values.append(parse_float(data.get(key, "")) if parse_float(data.get(key, "")) is not None else -1.0)
            elif key == "default":
                values.append(0 if row.is_default else 1)
            else:
                values.append(data.get(key, ""))
        return tuple(values)

    return sorted(rows, key=key_for, reverse=reverse)


_AVAIL_COMPACT_HIDE = ("default", "priority", "fairshare", "usage", "tags")


def _empty_columns(wide: bool, include_avail: bool, include_wait: bool = True) -> List[str]:
    return list(
        AllocationRow("", "", "", "", "", "")
        .to_dict(wide=wide, include_avail=include_avail, include_wait=include_wait)
        .keys()
    )


def _select_table_columns(all_columns: List[str], wide: bool, include_avail: bool) -> List[str]:
    """Pick which columns the table renderer should display.

    `to_dict()` produces every key for CSV/JSON consumers; the table view drops
    columns that crowd the layout. In `--avail` mode (without `--wide`),
    priority/fairshare/usage/default/tags are hidden so free_nodes/free_cpus/
    free_gpus have room to breathe.
    """
    if include_avail and not wide:
        return [c for c in all_columns if c not in _AVAIL_COMPACT_HIDE]
    return list(all_columns)


def _wrap_gpu_list(text: str, width: int) -> List[str]:
    """Wrap a 'gtype:f/t, gtype:f/t, ...' string to fit within `width` chars per line.

    Splits on commas (preserving order), greedily packs tokens, and adds a
    trailing ',' to every non-final line so the continuation is unambiguous.
    Single tokens that exceed `width` go on their own line (no truncation).
    """
    if not text:
        return [""]
    tokens = [t.strip() for t in text.split(",") if t.strip()]
    if not tokens:
        return [""]
    lines: List[str] = []
    current: List[str] = []
    current_len = 0
    for tok in tokens:
        sep_cost = 2 if current else 0  # ", "
        # Reserve 1 char for the trailing ',' that closes a non-final line.
        if current and current_len + sep_cost + len(tok) + 1 > width:
            lines.append(", ".join(current) + ",")
            current = [tok]
            current_len = len(tok)
        else:
            current.append(tok)
            current_len += sep_cost + len(tok)
    if current:
        lines.append(", ".join(current))
    return lines


def table_output(
    rows: List[AllocationRow],
    wide: bool,
    include_avail: bool = False,
    include_wait: bool = True,
    *,
    tty: Optional[bool] = None,
    term_width: Optional[int] = None,
) -> str:
    records = [
        row.to_dict(wide=wide, include_avail=include_avail, include_wait=include_wait)
        for row in rows
    ]
    all_columns = (
        list(records[0].keys())
        if records
        else _empty_columns(wide, include_avail, include_wait)
    )
    columns = _select_table_columns(all_columns, wide, include_avail)

    if tty is None:
        tty = sys.stdout.isatty()
    if term_width is None:
        term_width = shutil.get_terminal_size((120, 24)).columns

    # Wrap free_gpus only when it's the rightmost column AND we're rendering for a tty.
    wrap_target: Optional[str] = None
    if (
        include_avail
        and columns
        and columns[-1] == "free_gpus"
        and tty
        and any(record.get("free_gpus") for record in records)
    ):
        wrap_target = "free_gpus"

    base_widths = {
        column: max(
            len(column),
            max((len(record.get(column, "")) for record in records), default=0),
        )
        for column in columns
    }

    if wrap_target:
        prefix_cols = columns[:-1]
        prefix_width = sum(base_widths[c] for c in prefix_cols) + 2 * len(prefix_cols)
        wrap_width = max(40, term_width - prefix_width)
        wrapped_cells = [_wrap_gpu_list(r.get(wrap_target, ""), wrap_width) for r in records]
        target_w = max(
            len(wrap_target),
            max(
                (max(len(line) for line in cell) for cell in wrapped_cells if cell),
                default=0,
            ),
        )
        widths = {**base_widths, wrap_target: target_w}
    else:
        wrapped_cells = None
        widths = base_widths

    header = "  ".join(column.upper().ljust(widths[column]) for column in columns)
    rule = "  ".join("-" * widths[column] for column in columns)
    lines = [header, rule]
    # When any record wraps onto continuation lines, separate records with a
    # blank line so the eye can tell where one row ends and the next begins.
    separate_records = bool(
        wrap_target and any(len(cell) > 1 for cell in (wrapped_cells or []))
    )
    for index, record in enumerate(records):
        if separate_records and index > 0:
            lines.append("")
        if wrap_target:
            cell_lines = wrapped_cells[index] or [""]
            prefix_cols = columns[:-1]
            prefix = "  ".join(record.get(c, "").ljust(widths[c]) for c in prefix_cols)
            sep = "  " if prefix else ""
            lines.append(prefix + sep + cell_lines[0])
            indent = " " * (
                sum(widths[c] for c in prefix_cols) + 2 * len(prefix_cols)
            )
            for cont in cell_lines[1:]:
                lines.append(indent + cont)
        else:
            lines.append(
                "  ".join(record.get(c, "").ljust(widths[c]) for c in columns)
            )
    if not records:
        lines.append("(no matching allocations)")
    return "\n".join(lines)


def csv_output(
    rows: List[AllocationRow],
    wide: bool,
    include_avail: bool = False,
    include_wait: bool = True,
) -> str:
    records = [
        row.to_dict(wide=wide, include_avail=include_avail, include_wait=include_wait)
        for row in rows
    ]
    columns = (
        list(records[0].keys())
        if records
        else _empty_columns(wide, include_avail, include_wait)
    )
    stream = StringIO()
    writer = csv.DictWriter(stream, fieldnames=columns, lineterminator="\n")
    writer.writeheader()
    writer.writerows(records)
    return stream.getvalue().rstrip("\n")


def json_output(
    rows: List[AllocationRow],
    wide: bool,
    include_avail: bool = False,
    include_wait: bool = True,
) -> str:
    return json.dumps(
        [
            row.to_dict(wide=wide, include_avail=include_avail, include_wait=include_wait)
            for row in rows
        ],
        indent=2,
        sort_keys=True,
    )


def sbatch_output(rows: List[AllocationRow]) -> str:
    lines = []
    seen = set()
    for row in rows:
        key = (row.account, row.qos)
        if key in seen:
            continue
        seen.add(key)
        lines.append(f"#SBATCH --account={row.account}")
        if row.qos:
            lines.append(f"#SBATCH --qos={row.qos}")
        lines.append("")
    return "\n".join(lines).rstrip() if lines else "# no matching allocations"


def run_self_test() -> int:
    parsed = split_parsable("a|b|c|\n1|2|3\n", 3)
    assert parsed == [["a", "b", "c"], ["1", "2", "3"]]
    assert parse_wall_seconds("3-00:00:00") == 259200
    assert parse_wall_seconds("12:00:00") == 43200
    assert parse_wall_seconds("14d") == 1209600
    row = AllocationRow("notchpeak", "soc-gpu-np", "me", "", "soc-gpu-np", "soc-gpu-np")
    row.qos_info = QOSInfo("soc-gpu-np", max_wall="12:00:00", flags="DenyOnLimit")
    row.tags = classify(row)
    assert "gpu" in row.tags
    assert "default" in row.tags
    assert "cluster" in row.to_dict()
    assert csv_output([row], False).startswith("cluster,account,qos")
    assert json.loads(json_output([row], False))[0]["account"] == "soc-gpu-np"

    cluster, partition, bucket = parse_gres_line(
        "notchpeak|notchpeak-gpu|gpu:a100:4,gpu:2080ti:8(IDX:0-7)"
    )
    assert cluster == "notchpeak"
    assert partition == "notchpeak-gpu"
    assert bucket == {"a100": 4, "2080ti": 8}
    _, _, bucket = parse_gres_line("granite|granite-gpu|gpu:8")
    assert bucket == {"_any_": 8}
    _, _, bucket = parse_gres_line("granite|granite|(null)")
    assert bucket == {}
    assert parse_gres_line("malformed line")[1] == ""

    fake_avail = {"notchpeak": {"notchpeak-gpu": PartitionAvail()}}
    fake_avail["notchpeak"]["notchpeak-gpu"].add_gpu("a100", 3, 4)
    summary = format_gpu_summary(fake_avail)
    assert "notchpeak-gpu" in summary and "a100:3/4" in summary

    fc_row = AllocationRow(
        "granite", "sadayappan", "me", "", "granite-gpu-freecycle", ""
    )
    cands = _candidate_partitions(fc_row)
    assert "granite-gpu-freecycle" in cands and "granite-gpu" in cands
    fake_pgpus = {"granite": {"granite-gpu": {"h100nvl": 8}}}
    assert resolve_row_gpu_types(fc_row, fake_pgpus) == ("h100nvl",)
    # Verify table_output handles empty results without crashing.
    assert "(no matching allocations)" in table_output([], False)

    # Case-insensitive --format and --sort.
    assert _lower_choice("JSON") == "json"
    parser = _build_parser()
    args_mixed = parser.parse_args(["--format", "JSON"])
    assert args_mixed.format == "json"
    sorted_mixed = sort_rows([row], "Cluster,QOS", reverse=False)
    assert sorted_mixed and sorted_mixed[0].cluster == "notchpeak"
    # Help text wires examples + case-insensitivity note.
    rendered = parser.format_help()
    assert "Examples:" in rendered
    assert "case-insensitive" in rendered

    # Glob matching: auto-substring + explicit wildcards + case-insensitive.
    assert _to_glob("a100") == "*a100*"
    assert _to_glob("h*") == "h*"
    assert any_glob_match(["a100", "a100_80gb_pcie"], ["a100"])  # auto *a100*
    assert any_glob_match(["h100nvl", "h200"], ["H*"])
    assert any_glob_match(["rtxpr6000bl"], ["rtx*"])
    assert not any_glob_match(["v100"], ["a100"])
    assert not any_glob_match([], ["a100"])
    assert not any_glob_match(["a100"], [])

    # CPU features parser + resolver.
    cluster_p, partition_p, feats = parse_features_line(
        "notchpeak|notchpeak-gpu|chpc,gen,c64,a100"
    )
    assert (cluster_p, partition_p) == ("notchpeak", "notchpeak-gpu")
    assert "gen" in feats and "a100" in feats
    _, _, empty = parse_features_line("granite|granite|(null)")
    assert empty == set()
    fc_row2 = AllocationRow(
        "granite", "sadayappan", "me", "", "granite-gpu-freecycle", ""
    )
    assert resolve_row_features(
        fc_row2, {"granite": {"granite-gpu": {"gen", "h100nvl"}}}
    ) == ("gen", "h100nvl")
    cpu_summary = format_cpu_summary({"granite": {"granite-gpu": {"gen", "h100nvl"}}})
    assert "granite-gpu" in cpu_summary and "gen" in cpu_summary

    # Live-availability parsing.
    assert parse_cpus_state("96/0/0/96") == (0, 96)
    assert parse_cpus_state("32/32/0/64") == (32, 64)
    assert parse_cpus_state("garbage") == (0, 0)
    assert is_free_node_state("idle")
    assert is_free_node_state("mix")
    assert is_free_node_state("mix-")  # pending reboot but still accepting
    assert not is_free_node_state("alloc")
    assert not is_free_node_state("idle*")  # not responding
    assert not is_free_node_state("down")
    assert not is_free_node_state("inval")

    # Parens-aware GRES splitter handles commas inside (IDX:0,2-3).
    assert _split_gres_entries("gpu:rtx6000:3(IDX:0,2-3),nsight:0") == [
        "gpu:rtx6000:3(IDX:0,2-3)",
        "nsight:0",
    ]
    assert parse_gres_per_type("gpu:rtx6000:3(IDX:0,2-3),nsight:0") == {"rtx6000": 3}
    assert parse_gres_per_type("gpu:a100:8(IDX:0-7),nsight:8") == {"a100": 8}
    assert parse_gres_per_type("gpu:rtx2000:0(IDX:N/A)") == {"rtx2000": 0}
    assert parse_gres_per_type("(null)") == {}
    assert parse_gres_per_type("gpu:8") == {"_any_": 8}

    # Default-partition '*' marker is stripped.
    assert _strip_partition_marker("granite*") == "granite"
    assert _strip_partition_marker("granite-gpu") == "granite-gpu"

    # End-to-end row enrichment with synthetic per-partition availability.
    avail = {"granite": {"granite-gpu": PartitionAvail()}}
    bucket = avail["granite"]["granite-gpu"]
    bucket.nodes_total = 2
    bucket.nodes_free = 1
    bucket.cpus_total = 128
    bucket.cpus_free = 32
    bucket.add_gpu("h100nvl", 4, 16)
    fc_row3 = AllocationRow(
        "granite", "sadayappan", "me", "", "granite-gpu-freecycle", ""
    )
    attach_row_availability(fc_row3, avail)
    assert fc_row3.free_nodes == "1/2"
    assert fc_row3.free_cpus == "32/128"
    assert fc_row3.free_gpus == "h100nvl:4/16"
    record = fc_row3.to_dict(include_avail=True)
    assert record["free_nodes"] == "1/2"
    assert record["free_gpus"] == "h100nvl:4/16"
    assert "free_nodes" not in fc_row3.to_dict()  # opt-in only

    # CPU summary appends nodes/cpus when availability is supplied.
    cpu_summary_avail = format_cpu_summary(
        {"granite": {"granite-gpu": {"gen", "h100nvl"}}}, avail
    )
    assert "nodes:1/2" in cpu_summary_avail
    assert "cpus:32/128" in cpu_summary_avail

    # GPU-list wrapper: single line when it fits, multi-line with trailing
    # commas when it doesn't, oversized tokens never crash.
    assert _wrap_gpu_list("a:1/2, b:0/4, c:3/3", 100) == ["a:1/2, b:0/4, c:3/3"]
    assert _wrap_gpu_list("a:1/2, b:0/4, c:3/3", 8) == ["a:1/2,", "b:0/4,", "c:3/3"]
    assert _wrap_gpu_list("", 80) == [""]
    assert _wrap_gpu_list("verylongtoken:99/99, x:1/2", 5) == [
        "verylongtoken:99/99,",
        "x:1/2",
    ]

    # table_output wraps free_gpus into continuation lines when tty + narrow.
    avail_row = AllocationRow(
        "granite", "sadayappan", "me", "", "granite-gpu", "granite-gpu"
    )
    avail_row.qos_info = QOSInfo("granite-gpu")
    avail_row.tags = classify(avail_row)
    avail_row.free_nodes = "3/3"
    avail_row.free_cpus = "96/192"
    avail_row.free_gpus = (
        "a100:1/4, h100nvl:0/8, l40s:0/16, rtx6000:3/13, "
        "rtxpr4000bl:1/43, rtxpr6000bl:5/36, h200_1g.18gb:55/56"
    )
    rendered = table_output(
        [avail_row], wide=False, include_avail=True, tty=True, term_width=60
    )
    rendered_lines = rendered.splitlines()
    # Header + rule + first data line + at least one indented continuation.
    assert len(rendered_lines) >= 4, rendered
    continuation = rendered_lines[3]
    assert continuation.startswith(" "), repr(continuation)
    assert continuation.lstrip().startswith(("a100", "h100", "l40s", "rtx", "h200")), \
        repr(continuation)
    # When piped (tty=False) we get a single physical line per row.
    rendered_piped = table_output(
        [avail_row], wide=False, include_avail=True, tty=False, term_width=60
    )
    assert len(rendered_piped.splitlines()) == 3  # header + rule + one row

    # Compact column set: --avail (no --wide) hides priority/fairshare/usage/default/tags.
    full_cols = list(avail_row.to_dict(wide=False, include_avail=True).keys())
    compact = _select_table_columns(full_cols, wide=False, include_avail=True)
    assert "priority" not in compact and "fairshare" not in compact
    assert "usage" not in compact and "default" not in compact and "tags" not in compact
    assert "cluster" in compact and "free_gpus" in compact
    # --wide brings them back.
    wide_cols = _select_table_columns(full_cols, wide=True, include_avail=True)
    assert "priority" in wide_cols and "tags" in wide_cols

    # Two wrapping records must be separated by a blank line.
    second = AllocationRow(
        "granite", "sadayappan", "me", "", "granite-gpu-guest", "granite-gpu-guest"
    )
    second.qos_info = QOSInfo("granite-gpu-guest")
    second.tags = classify(second)
    second.free_nodes = "5/10"
    second.free_cpus = "100/640"
    second.free_gpus = avail_row.free_gpus  # long, will wrap
    rendered_two = table_output(
        [avail_row, second], wide=False, include_avail=True, tty=True, term_width=60
    )
    assert "\n\n" in rendered_two, "expected blank line between wrapping records"

    # Wait-time formatter.
    assert _format_wait(None) == "?"
    assert _format_wait(0) == "now"
    assert _format_wait(45) == "now"
    assert _format_wait(180) == "3m"
    assert _format_wait(7200) == "2h"
    assert _format_wait(3900) == "1h5m"
    assert _format_wait(90060) == "1d1h"
    assert _format_wait(86400 * 3) == "3d"

    # Test-only stderr parser.
    sample = (
        "sbatch: Job 12704030 to start at 2026-05-08T03:00:00 using "
        "1 processors on nodes notch001 in partition notchpeak-gpu"
    )
    parsed = parse_test_only_stderr(sample)
    assert parsed == datetime(2026, 5, 8, 3, 0, 0)
    assert parse_test_only_stderr("allocation failure: invalid account") is None
    assert parse_test_only_stderr("") is None

    # Sort by wait: None pushes to the end; 0 first, then 3600, 7200.
    rows_for_sort = [
        AllocationRow("c", "a1", "u", "", "q1", "q1"),
        AllocationRow("c", "a2", "u", "", "q2", "q2"),
        AllocationRow("c", "a3", "u", "", "q3", "q3"),
        AllocationRow("c", "a4", "u", "", "q4", "q4"),
    ]
    rows_for_sort[0].wait_seconds = 7200
    rows_for_sort[1].wait_seconds = 0
    rows_for_sort[2].wait_seconds = None
    rows_for_sort[3].wait_seconds = 3600
    sorted_by_wait = sort_rows(rows_for_sort, "wait", reverse=False)
    assert [r.wait_seconds for r in sorted_by_wait] == [0, 3600, 7200, None]

    # Wait column shows up in to_dict only when include_avail=True.
    avail_row.wait_seconds = 0
    assert avail_row.to_dict(include_avail=True)["wait"] == "now"
    assert "wait" not in avail_row.to_dict()

    # parse_gpu_spec: type+count, count-only, type-only, error cases.
    assert parse_gpu_spec("a100:4") == ("a100", 4)
    assert parse_gpu_spec("4") == (None, 4)
    assert parse_gpu_spec("a100") == ("a100", 1)
    assert parse_gpu_spec("A100:8") == ("a100", 8)
    for bad in ("", "  ", ":4", "a100:", "a100:0", "0", "a100:x"):
        try:
            parse_gpu_spec(bad)
        except CommandError:
            pass
        else:
            raise AssertionError(f"parse_gpu_spec({bad!r}) should have raised")

    # ProbeShape.gres_for: defaults preserve historic 'gpu:1' on GPU rows,
    # nothing on CPU rows; user-supplied counts/types render correctly.
    gpu_row = AllocationRow("notchpeak", "x", "u", "", "q", "q")
    gpu_row.tags = ("gpu",)
    gpu_row.gpu_types = ("v100",)
    cpu_row = AllocationRow("notchpeak", "x", "u", "", "q", "q")
    cpu_row.tags = ("cpu",)
    assert ProbeShape().gres_for(gpu_row) == "gpu:1"
    assert ProbeShape().gres_for(cpu_row) is None
    assert ProbeShape(gpu_count=4).gres_for(gpu_row) == "gpu:4"
    assert ProbeShape(gpu_type="a100", gpu_count=4).gres_for(gpu_row) == "gpu:a100:4"
    assert ProbeShape(gpu_type="a100").gres_for(gpu_row) == "gpu:a100:1"
    assert ProbeShape(gpu_type="a100", gpu_count=4).gres_for(cpu_row) is None

    # to_sbatch_args: time/nodes/cpus/mem flow through; gres only when applicable.
    args_built = ProbeShape(nodes=2, cpus=8, mem="32G", time="04:00:00").to_sbatch_args(gpu_row)
    assert "-N" in args_built and args_built[args_built.index("-N") + 1] == "2"
    assert "-n" in args_built and args_built[args_built.index("-n") + 1] == "8"
    assert "-t" in args_built and args_built[args_built.index("-t") + 1] == "04:00:00"
    assert "--mem=32G" in args_built
    assert "--gres=gpu:1" in args_built
    assert "--gres=gpu:a100:4" in ProbeShape(gpu_type="a100", gpu_count=4).to_sbatch_args(gpu_row)
    assert all(a != "--mem=" for a in ProbeShape().to_sbatch_args(gpu_row))

    # should_skip: typed GPU request against mismatched/empty/matching rows.
    assert ProbeShape(gpu_type="a100", gpu_count=4).should_skip(gpu_row) is True
    assert ProbeShape(gpu_type="v100", gpu_count=4).should_skip(gpu_row) is False
    empty_gpu_row = AllocationRow("notchpeak", "x", "u", "", "q", "q")
    empty_gpu_row.tags = ("gpu",)
    # Empty gpu_types means metadata wasn't loaded: don't skip.
    assert ProbeShape(gpu_type="a100", gpu_count=4).should_skip(empty_gpu_row) is False
    # CPU row + GPU request (typed or untyped): always skip.
    assert ProbeShape(gpu_type="a100", gpu_count=4).should_skip(cpu_row) is True
    assert ProbeShape(gpu_count=4).should_skip(cpu_row) is True
    # Untyped count-only on a GPU row still probes (any GPU is fine).
    assert ProbeShape(gpu_count=4).should_skip(gpu_row) is False
    # Default probe never skips.
    assert ProbeShape().should_skip(gpu_row) is False
    assert ProbeShape().should_skip(cpu_row) is False
    # predict_wait honors should_skip even with sbatch on PATH.
    assert predict_wait(gpu_row, shape=ProbeShape(gpu_type="a100", gpu_count=4)) is None

    # apply_wait_for_shorthand: each form maps to the right flag combo.
    parser = _build_parser()
    a = parser.parse_args(["--wait-for", "a100:4"])
    apply_wait_for_shorthand(a)
    assert a.gpus == "a100:4" and "a100" in (a.gpu_type or [])
    a = parser.parse_args(["--wait-for", "gpu:4"])
    apply_wait_for_shorthand(a)
    assert a.gpus == "4" and a.gpu is True
    a = parser.parse_args(["--wait-for", "cpu:32"])
    apply_wait_for_shorthand(a)
    assert a.cpus == 32 and a.cpu is True
    a = parser.parse_args(["--wait-for", "32"])
    apply_wait_for_shorthand(a)
    assert a.cpus == 32 and a.cpu is True
    a = parser.parse_args(["--wait-for", "a100"])
    apply_wait_for_shorthand(a)
    assert a.gpus == "a100" and "a100" in (a.gpu_type or [])
    for bad in ("cpu:0", "gpu:abc", "cpu:", "gpu:0", "a100:0"):
        a = parser.parse_args(["--wait-for", bad])
        try:
            apply_wait_for_shorthand(a)
        except CommandError:
            pass
        else:
            raise AssertionError(f"apply_wait_for_shorthand({bad!r}) should have raised")

    print("self-test passed")
    return 0


def main(argv: Sequence[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        return run_self_test()
    apply_wait_for_shorthand(args)
    if args.gpu and args.cpu:
        raise CommandError("--gpu and --cpu cannot be used together")
    if args.freecycle and args.no_freecycle:
        raise CommandError("--freecycle and --no-freecycle cannot be used together")
    if args.guest and args.no_guest:
        raise CommandError("--guest and --no-guest cannot be used together")
    if args.cpus <= 0:
        raise CommandError(f"--cpus must be > 0: {args.cpus}")
    if args.nodes <= 0:
        raise CommandError(f"--nodes must be > 0: {args.nodes}")
    if parse_wall_seconds(args.time) is None:
        raise CommandError(f"invalid --time value: {args.time}")
    gpu_type, gpu_count = (None, None)
    if args.gpus:
        gpu_type, gpu_count = parse_gpu_spec(args.gpus)
    shape = ProbeShape(
        nodes=args.nodes,
        cpus=args.cpus,
        mem=args.mem,
        gpu_type=gpu_type,
        gpu_count=gpu_count,
        time=args.time,
    )

    if args.list_gpus:
        print(format_gpu_summary(show_partition_availability()))
        return 0
    if args.list_cpus:
        print(format_cpu_summary(show_partition_features(), show_partition_availability()))
        return 0

    user = os.environ.get("USER") or run_command(["id", "-un"]).strip()
    rows = show_associations(user=user, all_visible=args.all_visible)
    include_avail = not args.no_avail
    include_wait = include_avail and not args.no_wait
    partition_avail = show_partition_availability() if include_avail else None
    # When availability data is loaded, derive the gpu-types map from it instead
    # of making a second sinfo call. Matches the shape show_partition_gpus returns.
    if partition_avail is not None and (args.gpu_type or args.wide):
        partition_gpus: Dict[str, Dict[str, Dict[str, int]]] = {
            c: {p: {g: tot for g, (_free, tot) in bucket.gpus.items()} for p, bucket in parts.items()}
            for c, parts in partition_avail.items()
        }
    elif args.gpu_type or args.wide:
        partition_gpus = show_partition_gpus()
    else:
        partition_gpus = {}
    partition_features = show_partition_features() if (args.cpu_type or args.wide) else {}
    attach_metadata(
        rows,
        include_usage=(not args.no_usage and not args.all_visible),
        user=user,
        partition_gpus=partition_gpus,
        partition_features=partition_features,
        partition_avail=partition_avail,
    )
    rows = filter_rows(rows, args)
    if include_wait:
        predict_wait_times(rows, shape=shape)
    sort_spec = args.sort
    if sort_spec is None:
        sort_spec = "wait,cluster,qos" if include_wait else "cluster,account,qos"
    rows = sort_rows(rows, sort_spec, args.reverse)

    if args.sbatch:
        output = sbatch_output(rows)
    elif args.format == "csv":
        output = csv_output(rows, args.wide, include_avail=include_avail, include_wait=include_wait)
    elif args.format == "json":
        output = json_output(rows, args.wide, include_avail=include_avail, include_wait=include_wait)
    else:
        output = table_output(rows, args.wide, include_avail=include_avail, include_wait=include_wait)

    print(output)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except CommandError as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(2)
