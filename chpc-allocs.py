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
import shutil
import subprocess
import sys
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

    @property
    def is_default(self) -> bool:
        return bool(self.default_qos) and self.qos == self.default_qos

    def to_dict(self, wide: bool = False) -> Dict[str, str]:
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
  chpc-allocs --list-gpus                  # cluster/partition GPU inventory
  chpc-allocs --list-cpus                  # cluster/partition feature inventory
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
        "--sort", default="cluster,account,qos", metavar="KEYS",
        help="Comma-separated sort keys (case-insensitive). Valid: "
        "cluster, account, qos, default, wall, priority, fairshare, usage, tags.",
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


def parse_gres_line(line: str) -> Tuple[str, str, Dict[str, int]]:
    """Parse one `sinfo --clusters=all -h -O 'Cluster:|,PartitionName:|,Gres:1024'`
    line into (cluster, partition, {type: count}).

    GRES strings look like 'gpu:a100:8,gpu:2080ti:2', 'gpu:8' (untyped, mapped
    to '_any_'), or 'gpu:a100:8(IDX:0-7)' (trailing flags stripped).
    """
    fields = line.split("|", 2)
    if len(fields) < 3:
        return "", "", {}
    cluster, partition, gres = (fields[0].strip(), fields[1].strip(), fields[2].strip())
    bucket: Dict[str, int] = {}
    if not partition or not gres or gres == "(null)":
        return cluster, partition, bucket
    for entry in gres.split(","):
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
    return cluster, partition, bucket


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


def format_gpu_summary(partition_gpus: Dict[str, Dict[str, Dict[str, int]]]) -> str:
    if not partition_gpus:
        return "(no GPU partitions found)"
    pairs: List[Tuple[str, str, Dict[str, int]]] = []
    for cluster in partition_gpus:
        for partition, types in partition_gpus[cluster].items():
            pairs.append((cluster, partition, types))
    if not pairs:
        return "(no GPU partitions found)"
    cluster_w = max(len(c) for c, _, _ in pairs)
    partition_w = max(len(p) for _, p, _ in pairs)
    lines = []
    for cluster, partition, types in sorted(pairs):
        rendered = ", ".join(f"{gtype}:{count}" for gtype, count in sorted(types.items()))
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


def format_cpu_summary(partition_features: Dict[str, Dict[str, Set[str]]]) -> str:
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
    lines = []
    for cluster, partition, feats in sorted(pairs):
        rendered = ",".join(sorted(feats))
        lines.append(f"{cluster.ljust(cluster_w)}  {partition.ljust(partition_w)}  {rendered}")
    return "\n".join(lines)


def attach_metadata(
    rows: List[AllocationRow],
    include_usage: bool,
    user: str,
    partition_gpus: Optional[Dict[str, Dict[str, Dict[str, int]]]] = None,
    partition_features: Optional[Dict[str, Dict[str, Set[str]]]] = None,
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
    }
    unknown = [key for key in keys if key not in allowed]
    if unknown:
        raise CommandError("unknown sort key(s): " + ", ".join(unknown))

    def key_for(row: AllocationRow) -> Tuple[object, ...]:
        values = []
        data = row.to_dict()
        for key in keys:
            if key == "wall":
                values.append(parse_wall_seconds(row.qos_info.max_wall) or -1)
            elif key in {"priority", "fairshare", "usage"}:
                values.append(parse_float(data.get(key, "")) if parse_float(data.get(key, "")) is not None else -1.0)
            elif key == "default":
                values.append(0 if row.is_default else 1)
            else:
                values.append(data.get(key, ""))
        return tuple(values)

    return sorted(rows, key=key_for, reverse=reverse)


def table_output(rows: List[AllocationRow], wide: bool) -> str:
    records = [row.to_dict(wide=wide) for row in rows]
    columns = list(records[0].keys()) if records else list(AllocationRow("", "", "", "", "", "").to_dict(wide=wide).keys())
    widths = {
        column: max(
            len(column),
            max((len(record.get(column, "")) for record in records), default=0),
        )
        for column in columns
    }
    header = "  ".join(column.upper().ljust(widths[column]) for column in columns)
    rule = "  ".join("-" * widths[column] for column in columns)
    lines = [header, rule]
    for record in records:
        lines.append("  ".join(record.get(column, "").ljust(widths[column]) for column in columns))
    if not records:
        lines.append("(no matching allocations)")
    return "\n".join(lines)


def csv_output(rows: List[AllocationRow], wide: bool) -> str:
    records = [row.to_dict(wide=wide) for row in rows]
    columns = list(records[0].keys()) if records else list(AllocationRow("", "", "", "", "", "").to_dict(wide=wide).keys())
    stream = StringIO()
    writer = csv.DictWriter(stream, fieldnames=columns, lineterminator="\n")
    writer.writeheader()
    writer.writerows(records)
    return stream.getvalue().rstrip("\n")


def json_output(rows: List[AllocationRow], wide: bool) -> str:
    return json.dumps([row.to_dict(wide=wide) for row in rows], indent=2, sort_keys=True)


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

    summary = format_gpu_summary({"notchpeak": {"notchpeak-gpu": {"a100": 4}}})
    assert "notchpeak-gpu" in summary and "a100:4" in summary

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
    print("self-test passed")
    return 0


def main(argv: Sequence[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        return run_self_test()
    if args.gpu and args.cpu:
        raise CommandError("--gpu and --cpu cannot be used together")
    if args.freecycle and args.no_freecycle:
        raise CommandError("--freecycle and --no-freecycle cannot be used together")
    if args.guest and args.no_guest:
        raise CommandError("--guest and --no-guest cannot be used together")

    if args.list_gpus:
        print(format_gpu_summary(show_partition_gpus()))
        return 0
    if args.list_cpus:
        print(format_cpu_summary(show_partition_features()))
        return 0

    user = os.environ.get("USER") or run_command(["id", "-un"]).strip()
    rows = show_associations(user=user, all_visible=args.all_visible)
    partition_gpus = show_partition_gpus() if (args.gpu_type or args.wide) else {}
    partition_features = show_partition_features() if (args.cpu_type or args.wide) else {}
    attach_metadata(
        rows,
        include_usage=(not args.no_usage and not args.all_visible),
        user=user,
        partition_gpus=partition_gpus,
        partition_features=partition_features,
    )
    rows = filter_rows(rows, args)
    rows = sort_rows(rows, args.sort, args.reverse)

    if args.sbatch:
        output = sbatch_output(rows)
    elif args.format == "csv":
        output = csv_output(rows, args.wide)
    elif args.format == "json":
        output = json_output(rows, args.wide)
    else:
        output = table_output(rows, args.wide)

    print(output)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except CommandError as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(2)
