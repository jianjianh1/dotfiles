#!/usr/bin/env python3
"""
Find CHPC SLURM allocations and QOS choices for the current user.

The default mode only queries associations for the invoking user. Use
--all-visible to search broader account/QOS metadata your normal permissions
can read; user names are never displayed in that mode.
"""

import argparse
import csv
import difflib
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

# GPU types treated as "premium" for default sort ranking. Substring-matched
# case-insensitively against row.gpu_types so e.g. "a100" matches both "a100"
# and "a100_80gb_pcie", and "h100" matches "h100nvl".
PREMIUM_GPUS = ("a100", "h100", "h200", "a6000")

# CPU microarchitecture tokens grouped by vendor. Substring-matched
# case-insensitively against row.cpu_features (sinfo lowercases features).
# `zen` covers zen1..zen5 via substring match; no need to enumerate them.
INTEL_CPU_FEATURES = (
    "skl", "csl", "icx", "spr", "emr", "cpx",
    "bro", "hsw", "ivy", "snb", "knl",
)
AMD_CPU_FEATURES = ("zen", "nap", "rom", "mil", "gen")

_INTEL_CONSTRAINT_EXPR = "|".join(INTEL_CPU_FEATURES)
_AMD_CONSTRAINT_EXPR = "|".join(AMD_CPU_FEATURES)


def classify_cpu_vendor(features) -> str:
    """Map a row's cpu_features to 'intel', 'amd', 'mixed', or '' (unknown).

    A feature token counts as Intel/AMD if any vendor pattern is a substring
    of it (e.g. 'zen4' -> AMD, 'emr' -> Intel). Tokens matching neither are
    ignored. 'mixed' when both vendors appear in the same set.
    """
    has_intel = False
    has_amd = False
    for feat in features or ():
        f = feat.lower()
        if not has_intel and any(p in f for p in INTEL_CPU_FEATURES):
            has_intel = True
        if not has_amd and any(p in f for p in AMD_CPU_FEATURES):
            has_amd = True
        if has_intel and has_amd:
            break
    if has_intel and has_amd:
        return "mixed"
    if has_intel:
        return "intel"
    if has_amd:
        return "amd"
    return ""

# Probe-shape defaults. Used as the argparse defaults for the legacy
# single-shape flags and to detect when the user has overridden any of them.
DEFAULT_PROBE_CPUS = 1
DEFAULT_PROBE_NODES = 1
DEFAULT_PROBE_TIME = "01:00:00"

# Implicit default shape set, built when no shape flags are passed. Three
# tiers covering the typical HPC research lifecycle:
#   1. dev      — small-GPU iteration, build/test, scaling sanity checks
#   2. research — single-node CPU runs, single-GPU fine-tuning
#   3. premium  — full-node CPU, multi-GPU DDP training
# Each shape is probed at one or more walltimes (curated per tier) so the
# user sees how queue pressure scales with wallclock request length.
# Shapes are gated on accessibility — a probe only emits if the user has
# a row exposing the required vendor or GPU type.
#
# Two walltime tuples per tier: a trimmed default and a `_FULL` sweep used
# when --full is passed. Rows that share the same wait across the
# remaining walltimes are merged by collapse_uniform_walltimes.
DEV_WALLTIMES = ("04:00:00",)  # 4h
DEV_WALLTIMES_FULL = ("04:00:00", "1-00:00:00")  # 4h, 24h
DEV_CPU_CORES = 16
DEV_GPU_PATTERNS = ("2080ti", "v100", "3090")

RESEARCH_WALLTIMES = ("01:00:00", "1-00:00:00", "3-00:00:00")  # 1h, 24h, 72h
RESEARCH_WALLTIMES_FULL = (
    "01:00:00", "02:00:00", "04:00:00", "12:00:00", "1-00:00:00", "3-00:00:00",
)  # 1h, 2h, 4h, 12h, 24h, 72h
RESEARCH_CPU_CORES = 32
RESEARCH_GPU_PATTERNS = ("a100", "h100", "h200")

PREMIUM_WALLTIMES = ("1-00:00:00", "7-00:00:00")  # 24h, 7d
PREMIUM_WALLTIMES_FULL = ("08:00:00", "1-00:00:00", "3-00:00:00", "7-00:00:00")  # 8h, 24h, 72h, 7d
PREMIUM_CPU_AMD_CORES = 64  # full Granite Genoa node
PREMIUM_GPU_SHAPES = (
    ("a100", 4),
    ("h100", 4),
    ("a6000", 4),
)


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
        self.cpu_vendor = classify_cpu_vendor(cpu_features)
        self.free_nodes = ""
        self.free_cpus = ""
        self.free_gpus = ""
        self.wait_by_shape: Dict[str, Optional[int]] = {}

    @property
    def is_default(self) -> bool:
        return bool(self.default_qos) and self.qos == self.default_qos

    def to_dict(
        self,
        wide: bool = False,
        include_avail: bool = False,
        include_wait: bool = True,
        shape: Optional["ProbeShape"] = None,
    ) -> Dict[str, str]:
        # Column order is intentional: identity → probe → "will it fit" →
        # QOS metadata → wide diagnostics → live availability. Python dict
        # insertion order propagates to the table/CSV/JSON renderers, so this
        # is the single point of truth for column layout.
        data: Dict[str, str] = {
            "cluster": self.cluster,
            "account": self.account,
            "qos": self.qos,
        }
        if include_avail and include_wait:
            if shape is not None:
                data["tier"] = _shape_tier(shape)
                data["shape"] = shape.label
                wait_secs = self.wait_by_shape.get(shape.label)
            else:
                data["tier"] = ""
                data["shape"] = ""
                wait_secs = None
            data["wait"] = _format_wait(wait_secs)
        data["wall"] = self.qos_info.max_wall
        data["tags"] = ",".join(self.tags)
        data["cpu_vendor"] = self.cpu_vendor
        data["default"] = "yes" if self.is_default else ""
        data["priority"] = self.qos_info.priority
        data["fairshare"] = self.share_info.fairshare if self.share_info else ""
        data["usage"] = self.share_info.raw_usage if self.share_info else ""
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
            data["free_nodes"] = self.free_nodes
            data["free_cpus"] = self.free_cpus
            data["free_gpus"] = self.free_gpus
        return data


class CommandError(RuntimeError):
    pass


DESCRIPTION = """\
chpc-allocs — show your CHPC SLURM allocations and predict queue wait time.

A "probe" here is a hypothetical job (`sbatch --test-only`) used to predict
wait time. With no args, this help is printed. Otherwise the default run
probes 3 GPU shape tiers (dev / research / premium) at 1-3 walltimes each
— see --list-tiers for the exact list.

Common entry points:
  chpc-allocs                       print this help
  chpc-allocs --gpu                 default 3-tier GPU probe
  chpc-allocs --cpu                 same, but for CPU-only allocations
  chpc-allocs -t dev --gpu          only the dev tier (fast iteration probe)
  chpc-allocs --wait-for SHAPE      a specific job, e.g. a100:4 / cpu:32
  chpc-allocs --explain             preview the probe plan, run nothing
  chpc-allocs --list-gpus           cluster GPU inventory (no allocations needed)
"""

EPILOG = """\
Examples
────────
Quickstart:
  chpc-allocs --wait-for a100:4         # when can my a100x4 job run?
  chpc-allocs --wait-for cpu:32         # ... or a 32-core CPU job
  chpc-allocs -t dev --gpu              # only the dev tier
  chpc-allocs -t research -t premium    # combine tiers
  chpc-allocs --explain                 # preview the default plan, run nothing
  chpc-allocs --list-tiers              # show the implicit 3-tier shape set

Common queries:
  chpc-allocs --cluster notchpeak --gpu        # GPU rows on notchpeak only
  chpc-allocs --gpu-type a100                  # a100 + 80gb_pcie + MIG slices
  chpc-allocs --gpu-type 'h*'                  # any Hopper / H-series
  chpc-allocs --cpu-type intel                 # Intel CPU partitions only
  chpc-allocs --shape a100:1 --shape a100:4 --pivot   # compare shapes side-by-side

Scripting / output:
  chpc-allocs --gpu --format json | jq '.rows[]'      # JSON with _help legend
  chpc-allocs --sbatch --gpu --format json            # machine-readable triples
  chpc-allocs --quick --format json                   # fast list, no probes/sinfo
  chpc-allocs --wide --format csv > allocs.csv

Diagnostics:
  chpc-allocs -v                              # narrate dropped rows + progress
  chpc-allocs --show-all                      # don't hide marginal rows
  chpc-allocs --full                          # all walltimes per tier, no merge
"""


def _lower_choice(value: str) -> str:
    return value.lower()


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        usage="chpc-allocs [--wait-for SHAPE | --shape SHAPE ... | --explain] "
              "[FILTER ...] [OUTPUT ...]",
        description=DESCRIPTION,
        epilog=EPILOG,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )

    # ----- Filtering -------------------------------------------------------
    filt = parser.add_argument_group(
        "Filtering",
        description=(
            "Narrow the allocations shown. Name filters (--cluster/--account/"
            "--qos) are case-insensitive substrings, repeatable, OR-matched. "
            "Hardware filters (--gpu-type/--cpu-type) use globs."
        ),
    )
    filt.add_argument(
        "--cluster", action="append", metavar="NAME",
        help="Cluster name. Repeatable. e.g. --cluster notchpeak",
    )
    filt.add_argument(
        "--account", action="append", metavar="NAME",
        help="Account name. Repeatable.",
    )
    filt.add_argument(
        "--qos", action="append", metavar="NAME",
        help="QOS name. Repeatable.",
    )
    filt.add_argument(
        "--default-only", action="store_true",
        help="Only the default QOS for each association.",
    )
    cpu_gpu = filt.add_mutually_exclusive_group()
    cpu_gpu.add_argument(
        "--gpu", action="store_true",
        help="Only GPU allocations. (Default tier set already targets GPUs.)",
    )
    cpu_gpu.add_argument(
        "--cpu", action="store_true",
        help="Only CPU allocations; switches the tier set to CPU shapes "
        "(cpu:16, cpu-intel:32, cpu-amd:32, cpu-amd:64). "
        "Filter — for the probe shape see --cpus.",
    )
    filt.add_argument(
        "--gpu-type", action="append", metavar="PATTERN",
        help="Only partitions exposing this GPU type. Glob ('h*', 'rtx*'); "
        "bare 'a100' wraps to *a100*. See --list-gpus. "
        "Filter — for the probe shape see --gpus.",
    )
    filt.add_argument(
        "--cpu-type", action="append", metavar="PATTERN",
        help="Only partitions with this CPU feature/microarch. 'intel'/'amd' "
        "are vendor shorthands; otherwise glob (e.g. emr, gen, zen*). "
        "See --list-cpus.",
    )
    fc_group = filt.add_mutually_exclusive_group()
    fc_group.add_argument(
        "--freecycle-only", dest="freecycle_only", action="store_true",
        help="Only freecycle (preemptable, no fairshare cost) rows.",
    )
    fc_group.add_argument(
        "--exclude-freecycle", dest="exclude_freecycle", action="store_true",
        help="Hide freecycle rows.",
    )
    # Old names kept as hidden aliases — same dests as the new flags above.
    filt.add_argument(
        "--freecycle", dest="freecycle_only", action="store_true",
        help=argparse.SUPPRESS,
    )
    filt.add_argument(
        "--no-freecycle", dest="exclude_freecycle", action="store_true",
        help=argparse.SUPPRESS,
    )
    g_group = filt.add_mutually_exclusive_group()
    g_group.add_argument(
        "--guest-only", dest="guest_only", action="store_true",
        help="Only guest (preemptable on idle owner nodes) rows.",
    )
    g_group.add_argument(
        "--exclude-guest", dest="exclude_guest", action="store_true",
        help="Hide guest rows.",
    )
    filt.add_argument(
        "--guest", dest="guest_only", action="store_true",
        help=argparse.SUPPRESS,
    )
    filt.add_argument(
        "--no-guest", dest="exclude_guest", action="store_true",
        help=argparse.SUPPRESS,
    )
    filt.add_argument(
        "--reservation", action="store_true",
        help="Only QOS that require a reservation.",
    )
    filt.add_argument(
        "--min-wall", metavar="DURATION",
        help="Minimum MaxWall. e.g. 12:00:00, 3-00:00:00, 14d, 7d, 'unlimited'.",
    )
    filt.add_argument(
        "--fairshare-min", type=float, metavar="FLOAT",
        help="Drop rows below this FairShare (requires sshare data).",
    )
    filt.add_argument(
        "--usage-max", type=float, metavar="FLOAT",
        help="Drop rows above this RawUsage (requires sshare data).",
    )
    filt.add_argument(
        "--all-visible", action="store_true",
        help="Search every association you can read (omits user names; "
        "may be slow; disables sshare enrichment).",
    )

    # ----- Probe shape -----------------------------------------------------
    shp = parser.add_argument_group(
        "Probe shape",
        description=(
            "Customize the hypothetical job used to predict wait. With no "
            "flags here, the implicit 3-tier shape set runs (see "
            "--list-tiers). Use -t/--tier to restrict to one or more tiers. "
            "Setting any of --cpus/--nodes/--gpus/--mem/--time replaces the "
            "multi-tier default with a single shape — pass --shape "
            "(repeatable) to keep multi-shape probing."
        ),
    )
    shp.add_argument(
        "-t", "--tier", action="append", choices=TIER_NAMES,
        metavar="{dev,research,premium}",
        help="Restrict the implicit shape set to one or more tiers. "
        "Repeatable. Default: all three. Ignored when --shape, --wait-for, "
        "or --cpus/--gpus/--mem/--time/--nodes is set. See --list-tiers.",
    )
    shp.add_argument(
        "--cpus", type=int, metavar="N", default=DEFAULT_PROBE_CPUS,
        help=f"CPUs per task for a SINGLE-shape probe (default: "
        f"{DEFAULT_PROBE_CPUS}). Setting this disables the multi-tier "
        "default — pass --shape for multi-shape, or --cpu for the CPU tier set.",
    )
    shp.add_argument(
        "--nodes", type=int, metavar="N", default=DEFAULT_PROBE_NODES,
        help=f"Node count for the single-shape probe (default: "
        f"{DEFAULT_PROBE_NODES}).",
    )
    shp.add_argument(
        "--gpus", metavar="SPEC",
        help="GPU(s) for a SINGLE-shape probe — 'a100:4', '4' (any type), "
        "'a100' (one). Probe shape — for filtering see --gpu-type.",
    )
    shp.add_argument(
        "--mem", metavar="SIZE",
        help="Memory for the single-shape probe (e.g. 16G, 128G).",
    )
    shp.add_argument(
        "--time", metavar="DURATION", default=DEFAULT_PROBE_TIME,
        help=f"Wall time for the single-shape probe. e.g. 24h, 3d, 4:00:00, "
        f"3-00:00:00. Default: {DEFAULT_PROBE_TIME}.",
    )
    shp.add_argument(
        "--shape", action="append", metavar="SPEC",
        help="Probe an additional job shape. Repeatable. Comma-separated "
        "positional shorthands ('a100:4', 'cpu:32', '32') or key=value tokens "
        "(cpus=, mem=, time=, gpus=, nodes=). e.g. 'a100:4,mem=32G,time=24h'. "
        "Multi-shape output expands to one row per (allocation, shape) — see "
        "--pivot.",
    )
    shp.add_argument(
        "--wait-for", metavar="SPEC",
        help="Shorthand for a single-job query. 'a100:4' = --gpus a100:4 + "
        "--gpu-type a100; 'gpu:4' = --gpus 4 + --gpu; 'cpu:32' = --cpus 32 + "
        "--cpu; '32' = same as cpu:32.",
    )

    # ----- Output ----------------------------------------------------------
    out = parser.add_argument_group(
        "Output",
        description=(
            "Format and trim the output. Default: table on a TTY, JSON when "
            "piped (a stderr notice fires when the auto-switch happens)."
        ),
    )
    out.add_argument(
        "--format", type=_lower_choice, choices=("table", "csv", "json"),
        default=None, metavar="{table,csv,json}",
        help="Output format (case-insensitive). Default: table on a TTY, "
        "json (wide, with _help legend) when piped.",
    )
    out.add_argument(
        "--wide", action="store_true",
        help="Show extra columns: partition, gpu_types, cpu_features, "
        "default_qos, TRES limits, QOS flags, full sshare detail.",
    )
    out.add_argument(
        "--pivot", action="store_true",
        help="Pivot layout: rows = (cluster, account, qos), columns = shape "
        "labels, cells = wait times. Table format only; useful with multiple "
        "--shape flags.",
    )
    out.add_argument(
        "--sort", default=None, metavar="KEYS",
        help="Comma-separated sort keys (case-insensitive). Categories: "
        "Time: wait, shape, wall. "
        "Quality: premium (a100/h100/h200/a6000 first), "
        "vendor (intel<amd<mixed<unknown), default, tags. "
        "Identity: cluster, account, qos. "
        "Score: priority, fairshare, usage. "
        "Default with wait: wait,shape,premium,vendor,cluster,qos. "
        "Default no-wait: premium,vendor,cluster,account,qos.",
    )
    out.add_argument(
        "--reverse", action="store_true",
        help="Reverse the sort order.",
    )
    out.add_argument(
        "--sbatch", action="store_true",
        help="Emit '#SBATCH --account=... --qos=...' blocks instead of a "
        "table. With --format=json, emits a JSON array of "
        "{cluster, account, qos, partition}.",
    )
    out.add_argument(
        "--best", action="store_true",
        help="Print only the lowest-wait runnable triple as a ready-to-paste "
        "#SBATCH block plus a one-line summary. Requires wait data (incompatible "
        "with --no-wait/--quick); also incompatible with --sbatch/--pivot. "
        "With --format=json, emits a single object.",
    )
    out.add_argument(
        "--no-json-help", action="store_true",
        help="In JSON output, drop the top-level _help legend and emit a "
        "bare array. No effect on table/csv.",
    )
    out.add_argument(
        "--full", action="store_true",
        help="All walltimes per tier (e.g. dev gets 30m+1h+4h+12h instead of "
        "30m+12h); skip the uniform-wait row collapse.",
    )
    out.add_argument(
        "--show-all", dest="show_all", action="store_true",
        help="Don't hide marginal rows: '?' waits, no-MaxWall QOS, "
        "over-MaxWall shapes, zero-free.",
    )
    # Old name kept as a hidden alias.
    out.add_argument(
        "--show-unknown", dest="show_all", action="store_true",
        help=argparse.SUPPRESS,
    )

    # ----- Diagnostics & speed --------------------------------------------
    diag = parser.add_argument_group(
        "Diagnostics & speed",
        description=(
            "Speed up runs by skipping queries (--no-wait, --no-availability, "
            "--no-usage, or --quick to skip all three). Debug what the tool "
            "is doing with --explain or -v."
        ),
    )
    diag.add_argument(
        "--no-wait", action="store_true",
        help="Skip the wait probe (no 'wait' column). Faster.",
    )
    diag.add_argument(
        "--no-availability", dest="no_availability", action="store_true",
        help="Skip the live sinfo capacity query (no free_* columns). Faster. "
        "In table mode the free_* columns replace priority/fairshare/usage/"
        "default/tags by default; --wide brings them back.",
    )
    # Old name kept as a hidden alias.
    diag.add_argument(
        "--no-avail", dest="no_availability", action="store_true",
        help=argparse.SUPPRESS,
    )
    diag.add_argument(
        "--no-usage", action="store_true",
        help="Skip the sshare lookup (no fairshare/usage columns). Faster.",
    )
    diag.add_argument(
        "--quick", action="store_true",
        help="Macro for --no-wait --no-availability --no-usage. Enumerate "
        "allocations fast, no probes.",
    )
    diag.add_argument(
        "--explain", action="store_true",
        help="Preview the probe plan and exit; runs no SLURM probes. "
        "Honors --format=json.",
    )
    diag.add_argument(
        "-v", "--verbose", action="store_true",
        help="Narrate dropped rows + probe progress to stderr.",
    )
    diag.add_argument(
        "--self-test", action="store_true",
        help="Run internal parser/format tests and exit. Does not query SLURM.",
    )

    # ----- Inventory shortcuts --------------------------------------------
    inv = parser.add_argument_group(
        "Inventory shortcuts",
        description=(
            "Print cluster inventory without consulting your allocations. "
            "Each exits after printing."
        ),
    )
    inv.add_argument(
        "--list-gpus", action="store_true",
        help="Cluster/partition GPU type:count inventory from sinfo.",
    )
    inv.add_argument(
        "--list-cpus", action="store_true",
        help="Cluster/partition CPU features inventory from sinfo.",
    )
    inv.add_argument(
        "--list-tiers", action="store_true",
        help="Print the implicit shape set and exit. Honors --cpu (CPU tiers) "
        "and --full (all walltimes per tier).",
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


def _to_sbatch_wall(value: str) -> str:
    """Normalize wall-time text to sbatch's accepted HH:MM:SS / D-HH:MM:SS form.

    Accepts every form `parse_wall_seconds` does (compact 'Nh'/'Nm', 'HH:MM:SS',
    'D-HH:MM:SS', 'Nd', bare minutes); falls back to the raw value when it
    can't be parsed. sbatch only accepts colon/dash forms, so passing
    `--time 24h` directly would silently fail.
    """
    seconds = parse_wall_seconds(value)
    if seconds is None or seconds <= 0:
        return value
    days, rem = divmod(seconds, 86400)
    hours, rem = divmod(rem, 3600)
    minutes, secs = divmod(rem, 60)
    if days:
        return f"{days}-{hours:02d}:{minutes:02d}:{secs:02d}"
    return f"{hours:02d}:{minutes:02d}:{secs:02d}"


def _format_wall_short(value: str) -> str:
    """Render wall time compactly: '24:00:00' -> '24h', '00:01:00' -> '1m'.

    Falls back to the raw value when it can't be parsed.
    """
    seconds = parse_wall_seconds(value)
    if seconds is None or seconds <= 0:
        return value
    # Prefer days only when >= 48h to keep '24h' rendering as '24h'.
    if seconds >= 2 * 86400 and seconds % 86400 == 0:
        return f"{seconds // 86400}d"
    if seconds % 3600 == 0:
        return f"{seconds // 3600}h"
    if seconds % 60 == 0 and seconds < 3600:
        return f"{seconds // 60}m"
    if seconds < 60:
        return f"{seconds}s"
    hours, rem = divmod(seconds, 3600)
    minutes = rem // 60
    if hours and minutes:
        return f"{hours}h{minutes}m"
    if hours:
        return f"{hours}h"
    return f"{minutes}m"


class ProbeShape:
    """Shape of the hypothetical job used for `sbatch --test-only` wait probing.

    Defaults reproduce the historical behavior: 1 node, 1 CPU, 1-minute wall,
    `--gres=gpu:1` on GPU rows, no GRES on CPU rows. When the user supplies
    flags (--cpus/--mem/--nodes/--gpus/--time), this carries them into the
    probe so the predicted wait reflects the actual job they intend to run.
    """

    def __init__(
        self,
        nodes: int = DEFAULT_PROBE_NODES,
        cpus: int = DEFAULT_PROBE_CPUS,
        mem: Optional[str] = None,
        gpu_type: Optional[str] = None,
        gpu_count: Optional[int] = None,
        time: str = DEFAULT_PROBE_TIME,
        cpu_vendor: Optional[str] = None,
    ) -> None:
        self.nodes = nodes
        self.cpus = cpus
        self.mem = mem
        self.gpu_type = gpu_type.lower() if gpu_type else None
        self.gpu_count = gpu_count
        self.time = time
        self.cpu_vendor = cpu_vendor.lower() if cpu_vendor else None
        self.label = self._compute_label()

    def _compute_label(self, time_label: Optional[str] = None) -> str:
        wall = time_label if time_label is not None else _format_wall_short(self.time)
        if self.gpu_type or self.gpu_count is not None:
            gtype = self.gpu_type or "gpu"
            count = self.gpu_count if self.gpu_count is not None else 1
            core = f"{gtype}:{count}@{wall}"
        elif self.cpu_vendor:
            core = f"cpu-{self.cpu_vendor}:{self.cpus}@{wall}"
        else:
            core = f"cpu:{self.cpus}@{wall}"
        parts = [core]
        if self.mem:
            parts.append(self.mem)
        label = ",".join(parts)
        if self.nodes > 1:
            label = f"{self.nodes}n*{label}"
        return label

    def gres_for(self, row: "AllocationRow") -> Optional[str]:
        """Return the --gres value for this row, or None to omit the flag."""
        if "gpu" not in row.tags:
            return None
        count = self.gpu_count if self.gpu_count is not None else 1
        if self.gpu_type:
            return f"gpu:{self.gpu_type}:{count}"
        return f"gpu:{count}"

    def to_sbatch_args(self, row: "AllocationRow") -> List[str]:
        args = ["-N", str(self.nodes), "-n", str(self.cpus), "-t", _to_sbatch_wall(self.time)]
        if self.mem:
            args.append(f"--mem={self.mem}")
        gres = self.gres_for(row)
        if gres:
            args.append(f"--gres={gres}")
        constraint = self._constraint_expr()
        if constraint:
            args.append(f"--constraint={constraint}")
        return args

    def _constraint_expr(self) -> Optional[str]:
        """Return a `--constraint=` value pinning the probe to a CPU vendor."""
        if self.cpu_vendor == "intel":
            return _INTEL_CONSTRAINT_EXPR
        if self.cpu_vendor == "amd":
            return _AMD_CONSTRAINT_EXPR
        return None

    def should_skip(self, row: "AllocationRow") -> bool:
        """True when this shape can't possibly run on this row (skip the probe)."""
        if self.cpu_vendor:
            # Allow unknown ('') or mixed rows so we don't drop probes when
            # feature metadata is incomplete; skip only on clear mismatch.
            row_vendor = row.cpu_vendor
            if row_vendor and row_vendor != "mixed" and row_vendor != self.cpu_vendor:
                return True
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


_GPUS_EXPECTED = (
    "'TYPE:COUNT' (e.g. a100:4), 'COUNT' (any GPU type, e.g. 4), or "
    "'TYPE' (1 of that type, e.g. a100)"
)
_GPUS_HINT = "chpc-allocs --list-gpus for available types"
_SHAPE_HINT = "chpc-allocs --help (Probe shape group), or examples in --help"


def _spec_error(
    label: str, spec: str, problem: str, expected: str, hint: str,
) -> CommandError:
    """Build a multi-line `problem/expected/see` CommandError for spec-style flags."""
    return CommandError(
        f"invalid {label} {spec!r}\n"
        f"  problem:  {problem}\n"
        f"  expected: {expected}\n"
        f"  see:      {hint}"
    )


def _shape_error(spec: str, problem: str, expected: str) -> CommandError:
    return _spec_error("--shape spec", spec, problem, expected, _SHAPE_HINT)


def _gpus_error(spec: str, problem: str) -> CommandError:
    return _spec_error("GPU spec", spec, problem, _GPUS_EXPECTED, _GPUS_HINT)


def parse_gpu_spec(spec: str) -> Tuple[Optional[str], int]:
    """Parse a --gpus value into (gpu_type, count).

    Forms:
      'a100:4' -> ('a100', 4)
      '4'      -> (None, 4)       # any GPU type
      'a100'   -> ('a100', 1)
    """
    s = (spec or "").strip().lower()
    if not s:
        raise _gpus_error(spec, "empty value")
    if ":" in s:
        type_, _, count_text = s.partition(":")
        type_ = type_.strip()
        count_text = count_text.strip()
        if not type_:
            raise _gpus_error(spec, "missing GPU type before ':'")
        if not count_text:
            raise _gpus_error(spec, "missing count after ':' (e.g. a100:4)")
        if not count_text.isdigit():
            raise _gpus_error(spec, f"count {count_text!r} is not a positive integer")
        if int(count_text) <= 0:
            raise _gpus_error(spec, "count must be > 0")
        return (type_, int(count_text))
    if s.isdigit():
        if int(s) <= 0:
            raise _gpus_error(spec, "count must be > 0")
        return (None, int(s))
    return (s, 1)


_MEM_RE = re.compile(r"^\d+[kmgtKMGT][bB]?$")


def parse_shape_spec(spec: str) -> ProbeShape:
    """Parse a --shape SPEC into a ProbeShape.

    Tokens (comma-separated, any order):
      cpus=N | mem=SIZE | time=DUR | gpus=SPEC | nodes=N
    Positional shorthands (first one wins for that slot):
      cpu:N        -> cpus=N (CPU shape, no GPU)
      <type>:N     -> gpus=<type>:N
      <type>       -> gpus=<type> (count 1)
      N (digits)   -> cpus=N

    Examples:
      'a100:4'                    -> 1 a100, 1 CPU, 1-min wall
      'a100:4,mem=32G,time=24h'   -> 4 a100, 32G mem, 24-hour wall
      'cpu:32,mem=128G,time=12h'  -> 32 CPUs (CPU job), 128G, 12h
      'cpus=8,mem=16G,gpus=h100nvl:1,time=4h'
    """
    s = (spec or "").strip()
    if not s:
        raise _shape_error(
            spec,
            "empty SPEC",
            "comma-separated tokens, e.g. 'a100:4,mem=32G,time=24h' or 'cpu:32,time=12h'",
        )
    cpus = DEFAULT_PROBE_CPUS
    mem: Optional[str] = None
    nodes = DEFAULT_PROBE_NODES
    time = DEFAULT_PROBE_TIME
    gpu_type: Optional[str] = None
    gpu_count: Optional[int] = None

    for raw in s.split(","):
        tok = raw.strip()
        if not tok:
            continue
        if "=" in tok:
            key, _, val = tok.partition("=")
            key = key.strip().lower()
            val = val.strip()
            if not val:
                raise _shape_error(
                    spec,
                    f"empty value for {key!r}",
                    f"{key}=VALUE (e.g. {key}=8 for an integer, {key}=24h for a duration)",
                )
            if key == "cpus":
                if not val.isdigit() or int(val) <= 0:
                    raise _shape_error(
                        spec,
                        f"cpus value {val!r} is not a positive integer",
                        "cpus=N where N > 0 (e.g. cpus=8, cpus=32)",
                    )
                cpus = int(val)
            elif key == "mem":
                if not _MEM_RE.match(val):
                    raise _shape_error(
                        spec,
                        f"mem value {val!r} has no unit",
                        "integer + unit, e.g. 16G, 32G, 128M",
                    )
                mem = val
            elif key == "nodes":
                if not val.isdigit() or int(val) <= 0:
                    raise _shape_error(
                        spec,
                        f"nodes value {val!r} is not a positive integer",
                        "nodes=N where N > 0 (e.g. nodes=2)",
                    )
                nodes = int(val)
            elif key == "time":
                if parse_wall_seconds(val) is None:
                    raise _shape_error(
                        spec,
                        f"time value {val!r} is not a recognized duration",
                        "HH:MM:SS, D-HH:MM:SS, Nd, or compact 'Nh'/'Nm' (e.g. 24h, 3d, 4:00:00)",
                    )
                time = val
            elif key == "gpus":
                gpu_type, gpu_count = parse_gpu_spec(val)
            else:
                raise _shape_error(
                    spec,
                    f"unknown key {key!r}",
                    "one of cpus=, mem=, time=, gpus=, nodes=",
                )
        else:
            low = tok.lower()
            if low.startswith("cpu:"):
                count_text = low[4:].strip()
                if not count_text or not count_text.isdigit() or int(count_text) <= 0:
                    raise _shape_error(
                        spec,
                        f"'cpu:' shorthand needs a positive integer count, got {count_text!r}",
                        "cpu:N where N > 0 (e.g. cpu:32)",
                    )
                cpus = int(count_text)
            elif low.isdigit():
                if int(low) <= 0:
                    raise _shape_error(
                        spec,
                        f"bare integer {low!r} must be > 0",
                        "N > 0 (treated as cpus=N)",
                    )
                cpus = int(low)
            else:
                gpu_type, gpu_count = parse_gpu_spec(tok)

    return ProbeShape(
        nodes=nodes,
        cpus=cpus,
        mem=mem,
        gpu_type=gpu_type,
        gpu_count=gpu_count,
        time=time,
    )


def _has_vendor(vendors: Set[str], vendor: str) -> bool:
    """True if `vendor` or 'mixed' is in the precomputed vendor set."""
    return vendor in vendors or "mixed" in vendors


def _shortest_matching_gpu(
    gpu_types: Set[str], pattern: str
) -> Optional[str]:
    """Return the shortest GPU type in `gpu_types` matching `pattern`.

    Substring match. Picking the shortest name avoids MIG-slice noise
    (e.g. prefers 'h200' over 'h200_1g.18gb'). Returns None if nothing
    matches.
    """
    matches = [gt for gt in gpu_types if pattern in gt]
    if not matches:
        return None
    return min(matches, key=lambda s: (len(s), s))


TIER_NAMES = ("dev", "research", "premium")


def default_shape_set(
    rows: List["AllocationRow"],
    kind: str = "gpu",
    full: bool = False,
    tiers: Optional[Sequence[str]] = None,
) -> List[ProbeShape]:
    """Build the implicit shape set used when no shape flags are given.

    `kind="gpu"` (default) emits only the GPU half of each tier; `kind="cpu"`
    emits only the CPU half. Walltime spreads scale with tier so the user
    sees queue-pressure scaling with wallclock length.

    `full=False` (default) uses a trimmed walltime set per tier; `full=True`
    restores the wider sweep listed in parentheses below.

    `tiers=None` emits all three; pass an iterable subset of {"dev", "research",
    "premium"} to filter (matches the `--tier` CLI flag).

    Tier 1 — dev (walltime: 4h; full: + 24h):
      * gpu: `2080ti:1`, `v100:1`, `3090:1` — small-GPU iteration / scaling
        sanity (each emits only if accessible)
      * cpu: `cpu:16` — generic build/test or small parallel run

    Tier 2 — research (walltimes: 1h, 24h, 72h; full: + 2h, 4h, 12h):
      * gpu: `a100:1`, `h100:1`, `h200:1` — single-GPU fine-tuning
      * cpu: `cpu-intel:32`, `cpu-amd:32` — single-node CPU jobs
        (one per detected vendor; each carries an sbatch `--constraint=`
        listing that vendor's microarch tokens)

    Tier 3 — premium (walltimes: 24h, 7d; full: + 8h, 72h):
      * gpu: `a100:4`, `h100:4`, `a6000:4` — multi-GPU DDP training
      * cpu: `cpu-amd:64` — full Granite Genoa node

    For each GPU pattern, the shortest matching concrete type from sinfo
    is picked so `--gres=gpu:<type>:N` resolves cleanly.
    """
    if kind not in ("gpu", "cpu"):
        raise ValueError(f"default_shape_set: unknown kind {kind!r}")
    unknown = [t for t in (tiers or ()) if t not in TIER_NAMES]
    if unknown:
        raise CommandError(
            f"unknown tier(s): {', '.join(unknown)}\n"
            f"  expected: {', '.join(TIER_NAMES)}"
        )
    active = set(tiers or TIER_NAMES)
    dev_walls = DEV_WALLTIMES_FULL if full else DEV_WALLTIMES
    research_walls = RESEARCH_WALLTIMES_FULL if full else RESEARCH_WALLTIMES
    premium_walls = PREMIUM_WALLTIMES_FULL if full else PREMIUM_WALLTIMES
    shapes: List[ProbeShape] = []
    vendors = {row.cpu_vendor for row in rows}
    gpu_types = {gt.lower() for row in rows for gt in row.gpu_types}

    # Tier 1 — dev
    if "dev" in active:
        if kind == "cpu":
            for wall in dev_walls:
                shapes.append(ProbeShape(cpus=DEV_CPU_CORES, time=wall))
        else:
            for pattern in DEV_GPU_PATTERNS:
                gpu_type = _shortest_matching_gpu(gpu_types, pattern)
                if gpu_type:
                    for wall in dev_walls:
                        shapes.append(ProbeShape(
                            gpu_type=gpu_type, gpu_count=1, time=wall
                        ))

    # Tier 2 — research
    if "research" in active:
        if kind == "cpu":
            if _has_vendor(vendors, "intel"):
                for wall in research_walls:
                    shapes.append(ProbeShape(
                        cpus=RESEARCH_CPU_CORES, time=wall, cpu_vendor="intel"
                    ))
            if _has_vendor(vendors, "amd"):
                for wall in research_walls:
                    shapes.append(ProbeShape(
                        cpus=RESEARCH_CPU_CORES, time=wall, cpu_vendor="amd"
                    ))
        else:
            for pattern in RESEARCH_GPU_PATTERNS:
                gpu_type = _shortest_matching_gpu(gpu_types, pattern)
                if gpu_type:
                    for wall in research_walls:
                        shapes.append(ProbeShape(
                            gpu_type=gpu_type, gpu_count=1, time=wall
                        ))

    # Tier 3 — premium
    if "premium" in active:
        if kind == "cpu":
            if _has_vendor(vendors, "amd"):
                for wall in premium_walls:
                    shapes.append(ProbeShape(
                        cpus=PREMIUM_CPU_AMD_CORES, time=wall, cpu_vendor="amd"
                    ))
        else:
            for pattern, count in PREMIUM_GPU_SHAPES:
                gpu_type = _shortest_matching_gpu(gpu_types, pattern)
                if gpu_type:
                    for wall in premium_walls:
                        shapes.append(ProbeShape(
                            gpu_type=gpu_type, gpu_count=count, time=wall
                        ))

    return shapes


def _shape_tier(shape: ProbeShape) -> str:
    """Map a shape from `default_shape_set` back to its tier name (dev /
    research / premium).

    Used by `format_tier_listing` so users can see which tier each shape lives
    in. Keys off `(cpus, cpu_vendor, gpu_type, gpu_count)` against the
    constants that `default_shape_set` itself uses, so the labels stay in sync
    automatically when those constants change.
    """
    if shape.gpu_type:
        if shape.gpu_count is not None and shape.gpu_count >= 2:
            return "premium"
        if any(p in shape.gpu_type for p in RESEARCH_GPU_PATTERNS):
            return "research"
        if any(p in shape.gpu_type for p in DEV_GPU_PATTERNS):
            return "dev"
        return "?"
    # CPU-side shapes.
    if shape.cpus == DEV_CPU_CORES:
        return "dev"
    if shape.cpus == RESEARCH_CPU_CORES:
        return "research"
    if shape.cpus >= PREMIUM_CPU_AMD_CORES:
        return "premium"
    return "?"


def format_tier_listing(
    full: bool = False,
    show_gpu: bool = True,
    show_cpu: bool = True,
) -> str:
    """Render the implicit shape set as a section-grouped, per-tier listing.

    Builds the shape set against a synthetic AllocationRow exposing every GPU
    type and both CPU vendors, so all three tiers emit. Uses
    `default_shape_set` directly — never duplicates tier definitions.
    """
    blurb = {
        "dev": "small-GPU iteration, build/test",
        "research": "single-GPU fine-tuning, single-node CPU",
        "premium": "multi-GPU DDP, full-node CPU",
    }
    synthetic = AllocationRow(
        cluster="*", account="*", user="*", partition="*", qos="*", default_qos="",
        cpu_features=("skl", "zen4"),
    )
    # Cover every GPU pattern referenced by the tier set. Concrete names are
    # MIG-free so the shortest-match tiebreaker resolves cleanly.
    synthetic.gpu_types = (
        *DEV_GPU_PATTERNS,
        *RESEARCH_GPU_PATTERNS,
        *(name for name, _ in PREMIUM_GPU_SHAPES),
    )
    synthetic.cpu_vendor = classify_cpu_vendor(synthetic.cpu_features)

    by_tier: Dict[str, Dict[str, List[ProbeShape]]] = {
        t: {"gpu": [], "cpu": []} for t in TIER_NAMES
    }
    if show_gpu:
        for s in default_shape_set([synthetic], kind="gpu", full=full):
            tier = _shape_tier(s)
            if tier in by_tier:
                by_tier[tier]["gpu"].append(s)
    if show_cpu:
        for s in default_shape_set([synthetic], kind="cpu", full=full):
            tier = _shape_tier(s)
            if tier in by_tier:
                by_tier[tier]["cpu"].append(s)

    sweep_label = "full sweep" if full else "trimmed default"
    lines = [f"Default tier set ({sweep_label}).", ""]
    for tier in TIER_NAMES:
        gpu_shapes = by_tier[tier]["gpu"]
        cpu_shapes = by_tier[tier]["cpu"]
        if not gpu_shapes and not cpu_shapes:
            continue
        lines.append(f"{tier.upper():<8}  — {blurb[tier]}")
        for s in gpu_shapes:
            lines.append(f"  gpu     {s.label}")
        for s in cpu_shapes:
            lines.append(f"  cpu     {s.label}")
        lines.append("")

    lines.append(
        "Tip: each tier emits only when your allocations expose the matching "
        "hardware."
    )
    lines.append("Filter to one tier:  chpc-allocs -t dev")
    if not full:
        lines.append("Add --full to see every walltime per tier.")
    return "\n".join(lines)


def _user_supplied_shape_flags(args: argparse.Namespace) -> bool:
    """True if the user passed any flag that customizes the wait probe shape.

    `apply_wait_for_shorthand` runs first, so `--wait-for` shows up here as
    mutated cpus/gpus/etc.
    """
    return (
        bool(args.shape)
        or args.gpus is not None
        or args.mem is not None
        or args.cpus != DEFAULT_PROBE_CPUS
        or args.nodes != DEFAULT_PROBE_NODES
        or args.time != DEFAULT_PROBE_TIME
    )


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
_WALL_COMPACT_RE = re.compile(r"(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?")


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


_PROGRESS_NOTICE_THRESHOLD = 24
# Width for the rolling-counter clear-line write — wide enough to wipe
# any "[chpc-allocs] probing N/M..." string we're likely to emit.
_PROGRESS_CLEAR_WIDTH = 60


def predict_wait_times(
    rows: List["AllocationRow"],
    shapes: Optional[List[ProbeShape]] = None,
    max_workers: int = 8,
    *,
    verbose: bool = False,
) -> None:
    """Populate `row.wait_by_shape[shape.label]` for every (row, shape), in parallel.

    When `verbose=True`, prints a one-line `Probing N pairs...` notice to
    stderr before the threadpool starts. The notice also fires when the
    interactive-progress threshold is exceeded *and* stderr is a TTY — so
    interactive runs of the wide implicit shape set get a heartbeat without
    spamming logs from scripted invocations.
    """
    if not rows or shutil.which("sbatch") is None:
        return
    if not shapes:
        shapes = [ProbeShape()]
    pair_count = sum(1 for r in rows for s in shapes if not s.should_skip(r))
    threshold_hit = pair_count >= _PROGRESS_NOTICE_THRESHOLD
    # Rolling counter would garble the per-row [v] narration verbose emits,
    # so verbose runs keep the original static notice and skip rolling.
    is_tty = sys.stderr.isatty()
    use_rolling = is_tty and threshold_hit and not verbose
    if verbose:
        print(
            f"[chpc-allocs] Probing {pair_count} (allocation × shape) wait times...",
            file=sys.stderr,
        )
    with ThreadPoolExecutor(max_workers=max_workers) as pool:
        futures = {}
        for row in rows:
            for shape in shapes:
                futures[pool.submit(predict_wait, row, shape=shape)] = (row, shape)
        completed = 0
        for future in as_completed(futures):
            row, shape = futures[future]
            try:
                row.wait_by_shape[shape.label] = future.result()
            except Exception:
                row.wait_by_shape[shape.label] = None
            completed += 1
            if use_rolling:
                sys.stderr.write(
                    f"\r[chpc-allocs] probing {completed}/{pair_count}..."
                )
                sys.stderr.flush()
    if use_rolling:
        sys.stderr.write("\r" + " " * _PROGRESS_CLEAR_WIDTH + "\r")
        sys.stderr.flush()


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
        row.cpu_vendor = classify_cpu_vendor(row.cpu_features)
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


def _matches_cpu_type_filter(row: "AllocationRow", patterns: Iterable[str]) -> bool:
    """--cpu-type matcher with `intel`/`amd` shorthand for vendor groups.

    Bare `intel` or `amd` matches when classify_cpu_vendor() returns that
    vendor (or 'mixed'). Other patterns fall through to the existing
    fnmatch-based feature-token matcher.
    """
    vendor = row.cpu_vendor
    other: List[str] = []
    for pat in patterns:
        p = (pat or "").lower()
        if p == "intel":
            if vendor in ("intel", "mixed"):
                return True
        elif p == "amd":
            if vendor in ("amd", "mixed"):
                return True
        else:
            other.append(pat)
    return any_glob_match(row.cpu_features, other)


def parse_wall_seconds(value: str) -> Optional[int]:
    value = (value or "").strip().lower()
    if not value:
        return None
    if value in {"none", "unlimited", "infinite"}:
        return 10**15
    if value.endswith("d") and value[:-1].isdigit():
        return int(value[:-1]) * 86400
    if ":" not in value and "-" not in value:
        compact = _WALL_COMPACT_RE.fullmatch(value)
        if compact and any(compact.groups()):
            h, m, s = (int(g) if g else 0 for g in compact.groups())
            return h * 3600 + m * 60 + s
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


def _emit_verbose(verbose: bool, msg: str) -> None:
    """Print a `[v]` line to stderr when verbose mode is on."""
    if verbose:
        print(f"[v] {msg}", file=sys.stderr)


def filter_rows(rows: List[AllocationRow], args: argparse.Namespace) -> List[AllocationRow]:
    min_wall = parse_wall_seconds(args.min_wall) if args.min_wall else None
    if args.min_wall and min_wall is None:
        raise CommandError(
            f"invalid --min-wall value {args.min_wall!r}\n"
            f"  expected: HH:MM:SS, D-HH:MM:SS, Nd, compact 'Nh'/'Nm', or 'unlimited' "
            f"(e.g. 12:00:00, 3-00:00:00, 7d)"
        )

    verbose = args.verbose
    freecycle_only = args.freecycle_only
    exclude_freecycle = args.exclude_freecycle
    guest_only = args.guest_only
    exclude_guest = args.exclude_guest

    def _drop(row: AllocationRow, reason: str) -> None:
        _emit_verbose(
            verbose, f"{row.qos or '(no-qos)'} @ {row.cluster}: dropped — {reason}"
        )

    result = []
    for row in rows:
        tags = set(row.tags)
        if not matches_any(row.cluster, args.cluster):
            _drop(row, "--cluster filter")
            continue
        if not matches_any(row.account, args.account):
            _drop(row, "--account filter")
            continue
        if not matches_any(row.qos, args.qos):
            _drop(row, "--qos filter")
            continue
        if args.default_only and not row.is_default:
            _drop(row, "--default-only (not the default QOS)")
            continue
        if args.gpu and "gpu" not in tags:
            _drop(row, "--gpu (cpu row)")
            continue
        if args.cpu and "gpu" in tags:
            _drop(row, "--cpu (gpu row)")
            continue
        if args.gpu_type and not any_glob_match(row.gpu_types, args.gpu_type):
            _drop(row, f"--gpu-type {args.gpu_type} (gpu_types={list(row.gpu_types)})")
            continue
        if args.cpu_type and not _matches_cpu_type_filter(row, args.cpu_type):
            _drop(row, f"--cpu-type {args.cpu_type} (vendor={row.cpu_vendor or '?'})")
            continue
        if freecycle_only and "freecycle" not in tags:
            _drop(row, "--freecycle-only")
            continue
        if exclude_freecycle and "freecycle" in tags:
            _drop(row, "--exclude-freecycle")
            continue
        if guest_only and "guest" not in tags:
            _drop(row, "--guest-only")
            continue
        if exclude_guest and "guest" in tags:
            _drop(row, "--exclude-guest")
            continue
        if args.reservation and "reservation" not in tags:
            _drop(row, "--reservation (no reservation tag)")
            continue
        if min_wall is not None:
            wall = parse_wall_seconds(row.qos_info.max_wall)
            if wall is None or wall < min_wall:
                _drop(row, f"--min-wall (max_wall={row.qos_info.max_wall or '?'})")
                continue
        if args.fairshare_min is not None:
            fairshare = parse_float(row.share_info.fairshare if row.share_info else "")
            if fairshare is None or fairshare < args.fairshare_min:
                _drop(row, f"--fairshare-min (fairshare={fairshare})")
                continue
        if args.usage_max is not None:
            usage = parse_float(row.share_info.raw_usage if row.share_info else "")
            if usage is None or usage > args.usage_max:
                _drop(row, f"--usage-max (usage={usage})")
                continue
        result.append(row)
    return result


def _format_applied_filters(args: argparse.Namespace) -> List[str]:
    """Return a list of human-readable filter strings active on this run.

    Used by --explain output and the zero-results hint to show the user
    exactly which filters were applied.
    """
    bits: List[str] = []
    if args.cluster:
        bits.append(f"cluster={','.join(args.cluster)}")
    if args.account:
        bits.append(f"account={','.join(args.account)}")
    if args.qos:
        bits.append(f"qos={','.join(args.qos)}")
    if args.default_only:
        bits.append("--default-only")
    if args.gpu:
        bits.append("--gpu")
    if args.cpu:
        bits.append("--cpu")
    if args.gpu_type:
        bits.append(f"gpu-type={','.join(args.gpu_type)}")
    if args.cpu_type:
        bits.append(f"cpu-type={','.join(args.cpu_type)}")
    if args.freecycle_only:
        bits.append("--freecycle-only")
    if args.exclude_freecycle:
        bits.append("--exclude-freecycle")
    if args.guest_only:
        bits.append("--guest-only")
    if args.exclude_guest:
        bits.append("--exclude-guest")
    if args.reservation:
        bits.append("--reservation")
    if args.min_wall:
        bits.append(f"min-wall={args.min_wall}")
    if args.fairshare_min is not None:
        bits.append(f"fairshare-min={args.fairshare_min}")
    if args.usage_max is not None:
        bits.append(f"usage-max={args.usage_max}")
    if args.all_visible:
        bits.append("--all-visible")
    return bits


def _is_default_output_mode(args: argparse.Namespace) -> bool:
    """True when no output-mode flag (--sbatch/--best/--pivot) is active.

    Each of those modes emits its own empty-set sentinel on stdout, so the
    stderr hint would just duplicate the message.
    """
    return not (args.sbatch or args.best or args.pivot)


def _zero_results_hint(args: argparse.Namespace) -> str:
    """Build a stderr hint shown when filtering left no rows.

    The hint itemizes which filters were applied and points at common
    next steps (verify accounts, broaden filters, list inventory).
    """
    bits = _format_applied_filters(args)
    lines: List[str] = []
    if bits:
        lines.append("0 allocations match. Filters applied:")
        lines.append(f"  {', '.join(bits)}")
    else:
        lines.append("0 allocations match (no filters applied).")
    lines.append("Hints:")
    lines.append("  - Verify your associations: sacctmgr show association user=$USER")
    if args.account or args.qos or args.cluster:
        lines.append("  - Broaden the search by removing some filters, or use --all-visible")
    lines.append("  - List GPU inventory:  chpc-allocs --list-gpus")
    lines.append("  - List CPU inventory:  chpc-allocs --list-cpus")
    lines.append("  - Re-run with -v to see which filter dropped each row")
    return "\n".join(lines)


_WAIT_SENTINEL = 10**12  # sorts unknown waits to the end (still < float('inf') headaches)


def _is_unprobeable_row(row: "AllocationRow") -> bool:
    """True if probing this row would yield no actionable wait info.

    Rows without QOS MaxWall metadata or with zero free capacity always
    yield useless probes; pre-filtering them avoids expensive sbatch
    --test-only subprocess calls.
    """
    if not row.qos_info.max_wall:
        return True
    if not row.free_nodes or row.free_nodes.startswith("0/"):
        return True
    return False


def _is_low_information_pair(
    row: "AllocationRow", shape: "ProbeShape"
) -> bool:
    """True if the (row, shape) pair should be hidden from the default view.

    Drops noise that's not actionable: failed probes, QOSes without
    MaxWall metadata, shapes whose walltime exceeds the QOS MaxWall,
    and rows with zero free capacity.
    """
    if row.wait_by_shape.get(shape.label) is None:
        return True
    if _is_unprobeable_row(row):
        return True
    qos_max = parse_wall_seconds(row.qos_info.max_wall)
    shape_secs = parse_wall_seconds(shape.time)
    if qos_max is not None and shape_secs is not None and shape_secs > qos_max:
        return True
    return False


def expand_rows_by_shape(
    rows: List["AllocationRow"],
    shapes: Optional[List[ProbeShape]],
) -> List[Tuple["AllocationRow", Optional[ProbeShape]]]:
    """Cross-product rows × shapes into one pair per output record.

    Pairs where the shape can't run on the row (per `should_skip`) are
    dropped — the `gpu_types` column already conveys compatibility, so a
    `wait=?` row would be noise. When `shapes` is None or empty, each row
    pairs with `None` (no-wait mode).
    """
    if not shapes:
        return [(row, None) for row in rows]
    return [
        (row, shape)
        for row in rows
        for shape in shapes
        if not shape.should_skip(row)
    ]


def _shape_signature(shape: ProbeShape) -> Tuple[object, ...]:
    """Stable identity for a shape ignoring walltime — used for grouping."""
    return (
        shape.nodes,
        shape.cpus,
        shape.mem,
        shape.gpu_type,
        shape.gpu_count,
        shape.cpu_vendor,
    )


def _row_signature(row: AllocationRow) -> Tuple[str, str, str, str]:
    return (row.cluster, row.account, row.partition, row.qos)


def collapse_uniform_walltimes(
    pairs: List[Tuple[AllocationRow, Optional[ProbeShape]]],
) -> List[Tuple[AllocationRow, Optional[ProbeShape]]]:
    """Merge (row, shape) pairs that share a wait across walltimes.

    Within each (row, shape-without-walltime) group, if every walltime
    yields the same wait value, replace the group with one pair whose
    shape carries a label spanning `min..max` of the group's walltimes.
    Non-uniform groups (where wait differs across walltimes) are emitted
    unchanged so scaling stays visible.

    Mutates `row.wait_by_shape` to add the merged label as a new key so
    downstream sort/render paths (which look up wait via `shape.label`)
    work unchanged.
    """
    grouped: Dict[Tuple[object, ...], List[int]] = {}
    for index, (row, shape) in enumerate(pairs):
        if shape is None:
            continue
        grouped.setdefault((_row_signature(row), _shape_signature(shape)), []).append(index)

    replaced: Dict[int, Tuple[AllocationRow, Optional[ProbeShape]]] = {}
    drop: Set[int] = set()
    for indices in grouped.values():
        if len(indices) < 2:
            continue
        members = [pairs[i] for i in indices]
        waits = [row.wait_by_shape.get(shape.label) for row, shape in members]
        if any(w is None for w in waits) or len(set(waits)) != 1:
            continue
        members_sorted = sorted(members, key=lambda p: parse_wall_seconds(p[1].time) or 0)
        first_row, first_shape = members_sorted[0]
        last_shape = members_sorted[-1][1]
        time_label = (
            _format_wall_short(first_shape.time)
            + ".."
            + _format_wall_short(last_shape.time)
        )
        collapsed = ProbeShape(
            nodes=first_shape.nodes,
            cpus=first_shape.cpus,
            mem=first_shape.mem,
            gpu_type=first_shape.gpu_type,
            gpu_count=first_shape.gpu_count,
            time=first_shape.time,
            cpu_vendor=first_shape.cpu_vendor,
        )
        collapsed.label = collapsed._compute_label(time_label=time_label)
        first_row.wait_by_shape[collapsed.label] = waits[0]
        replaced[indices[0]] = (first_row, collapsed)
        drop.update(indices[1:])

    return [replaced.get(i, pair) for i, pair in enumerate(pairs) if i not in drop]


def sort_pairs(
    pairs: List[Tuple[AllocationRow, Optional[ProbeShape]]],
    sort_spec: str,
    reverse: bool,
) -> List[Tuple[AllocationRow, Optional[ProbeShape]]]:
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
        "shape",
        "premium",
        "vendor",
    }
    unknown = [key for key in keys if key not in allowed]
    if unknown:
        suggestions = []
        for bad in unknown:
            close = difflib.get_close_matches(bad, allowed, n=1, cutoff=0.6)
            if close:
                suggestions.append(f"{bad!r} (did you mean {close[0]!r}?)")
            else:
                suggestions.append(repr(bad))
        raise CommandError(
            "unknown sort key(s): " + ", ".join(suggestions) + "\n"
            "  allowed: " + ", ".join(sorted(allowed))
        )

    def key_for(pair: Tuple[AllocationRow, Optional[ProbeShape]]) -> Tuple[object, ...]:
        row, shape = pair
        values = []
        data = row.to_dict()
        for key in keys:
            if key == "wait":
                wait = row.wait_by_shape.get(shape.label) if shape is not None else None
                values.append(_WAIT_SENTINEL if wait is None else wait)
            elif key == "shape":
                values.append(shape.label if shape is not None else "")
            elif key == "premium":
                values.append(0 if any_glob_match(row.gpu_types, PREMIUM_GPUS) else 1)
            elif key == "vendor":
                values.append({"intel": 0, "amd": 1, "mixed": 2}.get(row.cpu_vendor, 3))
            elif key == "wall":
                values.append(parse_wall_seconds(row.qos_info.max_wall) or -1)
            elif key in {"priority", "fairshare", "usage"}:
                values.append(parse_float(data.get(key, "")) if parse_float(data.get(key, "")) is not None else -1.0)
            elif key == "default":
                values.append(0 if row.is_default else 1)
            else:
                values.append(data.get(key, ""))
        return tuple(values)

    return sorted(pairs, key=key_for, reverse=reverse)


_AVAIL_COMPACT_HIDE = ("default", "priority", "fairshare", "usage", "tags")


def _empty_columns(wide: bool, include_avail: bool, include_wait: bool = True) -> List[str]:
    sentinel_shape = ProbeShape() if include_wait else None
    return list(
        AllocationRow("", "", "", "", "", "")
        .to_dict(
            wide=wide,
            include_avail=include_avail,
            include_wait=include_wait,
            shape=sentinel_shape,
        )
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


# ANSI styling — opt-out via NO_COLOR (https://no-color.org). Color is
# applied only when stdout is a TTY at render time, so piped output stays
# byte-identical to the pre-color era.
_ANSI_RESET = "\x1b[0m"
_ANSI_DIM = "\x1b[2m"
_ANSI_BOLD = "\x1b[1m"
_ANSI_GREEN = "\x1b[32m"
_ANSI_YELLOW = "\x1b[33m"
_ANSI_RED = "\x1b[31m"

# A bare integer followed by m/h/d is enough to bucket _format_wait output
# into <10m green / <1h yellow / >=1h red. "now" and "?" are handled
# separately by _wait_color.
_WAIT_TOKEN_RE = re.compile(r"^(\d+)([mhd])")


def _color_enabled(tty: bool) -> bool:
    """True when ANSI styling should be emitted.

    Per no-color.org, NO_COLOR set to *any* non-empty value disables color.
    """
    if not tty:
        return False
    return not os.environ.get("NO_COLOR")


def _paint(text: str, code: str, *, enable: bool) -> str:
    if not enable or not code:
        return text
    return f"{code}{text}{_ANSI_RESET}"


def _wait_color(raw: str) -> str:
    """Pick an ANSI code for a wait-string token. Empty when no color applies."""
    if raw == "?":
        return _ANSI_DIM
    if raw == "now":
        return _ANSI_GREEN
    match = _WAIT_TOKEN_RE.match(raw)
    if not match:
        return ""
    value, unit = int(match.group(1)), match.group(2)
    if unit == "m":
        return _ANSI_GREEN if value < 10 else _ANSI_YELLOW
    return _ANSI_RED


def _tag_color(raw: str) -> str:
    """Dim freecycle/guest tags — they're preemptable, worth flagging quietly."""
    if "freecycle" in raw or "guest" in raw:
        return _ANSI_DIM
    return ""


def _tier_color(tier: str) -> str:
    """Style tier brackets in pivot/table headers."""
    if tier == "dev":
        return _ANSI_DIM
    if tier == "premium":
        return _ANSI_BOLD
    return ""


# Per-column colorer dispatch: map column name to a function that picks an
# ANSI code from the raw cell value. Columns absent from the map render plain.
_COLUMN_COLORERS = {
    "wait": _wait_color,
    "tags": _tag_color,
}


def _styled_cell(column: str, padded: str, raw: str, enable: bool) -> str:
    """Wrap a *padded* cell in ANSI codes based on column semantics.

    The padding is inside the styled span — spaces don't render visibly
    regardless of foreground color, so this is safe.
    """
    if not enable:
        return padded
    colorer = _COLUMN_COLORERS.get(column)
    if colorer is None:
        return padded
    return _paint(padded, colorer(raw), enable=enable)


def table_output(
    pairs: List[Tuple[AllocationRow, Optional[ProbeShape]]],
    wide: bool,
    include_avail: bool = False,
    include_wait: bool = True,
    *,
    tty: Optional[bool] = None,
    term_width: Optional[int] = None,
) -> str:
    records = [
        row.to_dict(
            wide=wide,
            include_avail=include_avail,
            include_wait=include_wait,
            shape=shape,
        )
        for row, shape in pairs
    ]
    all_columns = (
        list(records[0].keys())
        if records
        else _empty_columns(wide, include_avail, include_wait)
    )
    columns = _select_table_columns(all_columns, wide, include_avail)

    # Suppress redundant tier column when all rows share the same tier (e.g.
    # the user passed -t dev, or the default set produced only one tier's
    # worth of accessible shapes). The field still flows through CSV/JSON
    # for machine consumers — only the human-facing table hides it.
    if "tier" in columns:
        tier_values = {r.get("tier", "") for r in records}
        if len(tier_values) <= 1:
            columns = [c for c in columns if c != "tier"]

    if tty is None:
        tty = sys.stdout.isatty()
    if term_width is None:
        term_width = shutil.get_terminal_size((120, 24)).columns
    color = _color_enabled(tty)

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
        def cell(c: str) -> str:
            value = record.get(c, "")
            return _styled_cell(c, value.ljust(widths[c]), value, color)

        if wrap_target:
            cell_lines = wrapped_cells[index] or [""]
            prefix_cols = columns[:-1]
            prefix = "  ".join(cell(c) for c in prefix_cols)
            sep = "  " if prefix else ""
            lines.append(prefix + sep + cell_lines[0])
            indent = " " * (
                sum(widths[c] for c in prefix_cols) + 2 * len(prefix_cols)
            )
            for cont in cell_lines[1:]:
                lines.append(indent + cont)
        else:
            lines.append("  ".join(cell(c) for c in columns))
    if not records:
        lines.append("(no matching allocations)")
    return "\n".join(lines)


def csv_output(
    pairs: List[Tuple[AllocationRow, Optional[ProbeShape]]],
    wide: bool,
    include_avail: bool = False,
    include_wait: bool = True,
) -> str:
    records = [
        row.to_dict(
            wide=wide,
            include_avail=include_avail,
            include_wait=include_wait,
            shape=shape,
        )
        for row, shape in pairs
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
    pairs: List[Tuple[AllocationRow, Optional[ProbeShape]]],
    wide: bool,
    include_avail: bool = False,
    include_wait: bool = True,
    include_help: bool = False,
) -> str:
    records = [
        row.to_dict(
            wide=wide,
            include_avail=include_avail,
            include_wait=include_wait,
            shape=shape,
        )
        for row, shape in pairs
    ]
    if not include_help:
        return json.dumps(records, indent=2, sort_keys=True)
    payload = {
        "_help": {
            "schema_version": 1,
            "premium_gpus": list(PREMIUM_GPUS),
            "intel_cpu_features": list(INTEL_CPU_FEATURES),
            "amd_cpu_features": list(AMD_CPU_FEATURES),
            "fields": {
                "cluster": "SLURM cluster name (e.g. notchpeak, granite)",
                "account": "account to pass via --account",
                "qos": "QOS to pass via --qos; partition is usually the same name",
                "partition": "partition name (with --wide); pass via --partition",
                "wall": "QOS MaxWall as HH:MM:SS, D-HH:MM:SS, or 'unlimited'",
                "tier": "tier name for this shape — one of dev / research / "
                        "premium when the shape came from the implicit tier "
                        "set, '?' for user-supplied shapes that don't match a "
                        "known tier. See --list-tiers / --tier.",
                "shape": "probed job shape: '<gpu>:<count>@<wall>[,<mem>]' or "
                        "'cpu:<cpus>@<wall>[,<mem>]'. The 'wait' value on this row "
                        "is for THIS shape on THIS allocation. With multiple --shape "
                        "flags, each (allocation, shape) pair gets its own row.",
                "wait": "predicted seconds until job start from `sbatch --test-only` "
                        "for the shape on this row; 'now' means startable immediately, "
                        "'?' / null means probe skipped or unknown",
                "free_nodes": "live free/total node count from sinfo",
                "free_cpus": "live free/total CPU count from sinfo",
                "free_gpus": "comma-separated 'gtype:free/total' per partition (live)",
                "gpu_types": "GPU types exposed by the partition (with --wide)",
                "cpu_features": "node feature tags for the partition (with --wide)",
                "cpu_vendor": "derived from cpu_features: 'intel', 'amd', "
                        "'mixed', or '' when unknown. Filter via --cpu-type "
                        "intel|amd; sort tier 'vendor' ranks intel<amd<mixed<unknown.",
                "tags": "quality flags: gpu, cpu, freecycle (preemptable), "
                        "guest (preemptable on idle owner nodes), reservation, default",
                "default": "'yes' if this QOS is the default for the assoc",
                "priority": "QOS priority (higher = sooner-scheduled)",
                "fairshare": "FairShare from sshare (higher = better standing)",
                "usage": "RawUsage from sshare (lower = less recent consumption)",
            },
            "notes": [
                "Rows are sorted by 'wait,shape,premium,vendor,cluster,qos' by default: "
                "lowest predicted wait first, then grouped by shape, then "
                "premium-GPU rows ahead of non-premium, then Intel CPUs ahead of AMD, "
                "then alphabetical.",
                "Premium GPUs are the substring matches in `_help.premium_gpus` "
                "against `gpu_types` (case-insensitive).",
                "freecycle/guest QOS rows are preemptable; jobs there should "
                "use --requeue and checkpoint.",
                "With multiple --shape flags the output is in long format: one "
                "row per (allocation, shape) pair. The `shape` column tells "
                "you which shape was probed for that wait.",
                "Without any shape flags, the implicit default probes a "
                "three-tier set covering the typical HPC research lifecycle: "
                "dev (cpu:16, 2080ti:1, v100:1, 3090:1 @4h,24h), research "
                "(cpu-intel:32, cpu-amd:32, a100:1, h100:1, h200:1 "
                "@1h,2h,4h,12h,24h,72h), premium (cpu-amd:64, a100:4, h100:4, "
                "a6000:4 @8h,24h,72h,7d). Pass --tier dev|research|premium "
                "(repeatable) to restrict to one or more tiers. Each shape "
                "is gated on accessibility — vendor CPU shapes only emit if "
                "that vendor is detected on the user's rows; GPU shapes only "
                "emit if the user has a row exposing that GPU type. "
                "Vendor-tagged CPU shapes pass `--constraint=` to sbatch so "
                "the probe lands on matching hardware. Pairs where the "
                "shape can't run on the row are dropped from output.",
                "By default, rows are hidden when the probe returned `?`, "
                "the QOS has no MaxWall, the shape's walltime exceeds the "
                "QOS MaxWall, or the allocation has zero free capacity. "
                "Pass --show-unknown to include them.",
            ],
        },
        "rows": records,
    }
    return json.dumps(payload, indent=2, sort_keys=True)


def best_output(
    pairs: List[Tuple[AllocationRow, Optional[ProbeShape]]],
    fmt: str,
) -> str:
    """Render the lowest-wait pair as a paste-ready #SBATCH block (or JSON).

    Assumes `pairs` is already sorted with the shortest wait first (the
    default sort spec puts wait,shape ahead of identity). Falls back to a
    `# no allocations matched` sentinel when filtering eliminated everything.
    """
    if not pairs:
        if fmt == "json":
            return json.dumps(None)
        return "# no allocations matched"
    row, shape = pairs[0]
    wait_secs = row.wait_by_shape.get(shape.label) if shape else None
    alternatives = len(pairs) - 1
    if fmt == "json":
        return json.dumps(
            {
                "cluster": row.cluster,
                "account": row.account,
                "partition": row.partition,
                "qos": row.qos,
                "time": shape.time if shape else "",
                "predicted_wait_seconds": wait_secs,
                "alternatives": alternatives,
            },
            indent=2,
            sort_keys=True,
        )
    lines = [f"#SBATCH --account={row.account}"]
    if row.partition:
        lines.append(f"#SBATCH --partition={row.partition}")
    if row.qos:
        lines.append(f"#SBATCH --qos={row.qos}")
    if shape and shape.time:
        lines.append(f"#SBATCH --time={shape.time}")
    suffix = (
        f"  ({alternatives} alternative{'s' if alternatives != 1 else ''} — "
        "drop --best to see them)"
        if alternatives else ""
    )
    lines.append(f"# predicted wait: {_format_wait(wait_secs)}{suffix}")
    return "\n".join(lines)


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


def sbatch_json_output(rows: List[AllocationRow]) -> str:
    """Machine-readable variant of `sbatch_output`.

    Emits a JSON array of {cluster, account, qos, partition} records, one
    per unique (account, qos) tuple. Useful for templating job scripts.
    """
    seen: Set[Tuple[str, str]] = set()
    items: List[Dict[str, str]] = []
    for row in rows:
        key = (row.account, row.qos)
        if key in seen:
            continue
        seen.add(key)
        items.append(
            {
                "cluster": row.cluster,
                "account": row.account,
                "qos": row.qos,
                "partition": row.partition,
            }
        )
    return json.dumps(items, indent=2, sort_keys=True)


def pivot_output(
    pairs: List[Tuple[AllocationRow, Optional[ProbeShape]]],
    *,
    tty: Optional[bool] = None,
) -> str:
    """Render a (cluster, account, qos) × shape pivot table of wait times.

    Rows are unique allocations, columns are shape labels in first-seen order,
    cells are formatted wait strings. Missing cells render as '?'. When no
    pair carries a shape (no-wait mode), the function returns the same
    "(no matching allocations)" sentinel as `table_output` so the caller
    doesn't need to special-case empty input.
    """
    if not pairs:
        return "(no matching allocations)"
    row_keys: List[Tuple[str, str, str]] = []
    seen_keys: Set[Tuple[str, str, str]] = set()
    shape_labels: List[str] = []
    seen_labels: Set[str] = set()
    shape_by_label: Dict[str, ProbeShape] = {}
    cells: Dict[Tuple[Tuple[str, str, str], str], str] = {}
    for row, shape in pairs:
        if shape is None:
            continue
        key = (row.cluster, row.account, row.qos)
        if key not in seen_keys:
            seen_keys.add(key)
            row_keys.append(key)
        if shape.label not in seen_labels:
            seen_labels.add(shape.label)
            shape_labels.append(shape.label)
            shape_by_label[shape.label] = shape
        wait_secs = row.wait_by_shape.get(shape.label)
        cells[(key, shape.label)] = _format_wait(wait_secs)
    if not row_keys or not shape_labels:
        return "(no matching allocations)"
    # Prefix each shape header with its tier so users can visually group the
    # columns (e.g. "[DEV] 2080TI:1@4H"). Suppress the bracket when only one
    # tier is present — it'd be pure noise.
    tier_by_label = {s: _shape_tier(shape_by_label[s]) for s in shape_labels}
    if len(set(tier_by_label.values())) > 1:
        shape_headers = [
            f"[{tier_by_label[s].upper()}] {s.upper()}" for s in shape_labels
        ]
    else:
        shape_headers = [s.upper() for s in shape_labels]
    headers = ["CLUSTER", "ACCOUNT", "QOS"] + shape_headers
    body: List[List[str]] = []
    for key in row_keys:
        cluster, account, qos = key
        body.append(
            [cluster, account, qos]
            + [cells.get((key, s), "?") for s in shape_labels]
        )
    widths = [
        max(len(headers[i]), max((len(r[i]) for r in body), default=0))
        for i in range(len(headers))
    ]
    if tty is None:
        tty = sys.stdout.isatty()
    color = _color_enabled(tty)
    n_id_cols = 3  # cluster, account, qos
    rule = "  ".join("-" * widths[i] for i in range(len(headers)))

    def styled_header(i: int) -> str:
        cell = headers[i].ljust(widths[i])
        if not color or i < n_id_cols:
            return cell
        # shape-column header: pull tier from the parallel shape_labels list
        label = shape_labels[i - n_id_cols]
        tier = tier_by_label[label]
        return _paint(cell, _tier_color(tier), enable=color)

    def styled_body(row_cells: List[str]) -> str:
        out = []
        for i, raw in enumerate(row_cells):
            cell = raw.ljust(widths[i])
            # Shape columns carry wait values; reuse the table renderer's
            # column-semantic dispatch by labelling them as "wait".
            column = "wait" if i >= n_id_cols else ""
            out.append(_styled_cell(column, cell, raw, color))
        return "  ".join(out)

    lines = ["  ".join(styled_header(i) for i in range(len(headers))), rule]
    for r in body:
        lines.append(styled_body(r))
    legend = "(cells: predicted queue wait via sbatch --test-only; ? = unknown)"
    if color:
        legend = _paint(legend, _ANSI_DIM, enable=color)
    lines.append("")
    lines.append(legend)
    return "\n".join(lines)


def render_explain_plan(
    rows: List[AllocationRow],
    shapes: List[ProbeShape],
    args: argparse.Namespace,
    fmt: str,
) -> str:
    """Build the --explain preview string (text or JSON).

    Reports the post-filter row count, the active filter list, the planned
    shape set with per-shape accessibility (how many rows the shape would
    actually probe), and the estimated total probe count.
    """
    applied = _format_applied_filters(args)
    rows_count = len(rows)
    accessible_pairs = sum(
        1 for r in rows for s in shapes if not s.should_skip(r)
    )

    if fmt == "json":
        shapes_payload = []
        for s in shapes:
            accessible = sum(1 for r in rows if not s.should_skip(r))
            shapes_payload.append(
                {
                    "label": s.label,
                    "accessible_rows": accessible,
                    "skipped_rows": rows_count - accessible,
                }
            )
        payload = {
            "allocations_after_filter": rows_count,
            "filters_applied": applied,
            "shape_count": len(shapes),
            "shapes": shapes_payload,
            "estimated_probes": accessible_pairs,
            "note": "Run without --explain to execute.",
        }
        return json.dumps(payload, indent=2, sort_keys=True)

    lines: List[str] = []
    lines.append(f"Allocations matching filters: {rows_count}")
    lines.append(
        f"Filters applied: {', '.join(applied)}" if applied
        else "Filters applied: (none)"
    )
    if shapes:
        lines.append(f"Probe shape set ({len(shapes)}):")
        for s in shapes:
            accessible = sum(1 for r in rows if not s.should_skip(r))
            if accessible == 0:
                tag = "[skipped — no compatible row]"
            elif accessible == rows_count:
                tag = f"[probes all {rows_count}]"
            else:
                tag = f"[probes {accessible} of {rows_count}]"
            lines.append(f"  {tag}  {s.label}")
    else:
        lines.append("Probe shape set: (none — wait probing skipped)")
    lines.append(
        f"Estimated probes: {accessible_pairs} "
        f"({rows_count} allocations × {len(shapes)} shapes, minus skipped pairs)"
    )
    lines.append("")
    lines.append("Run without --explain to execute.")
    return "\n".join(lines)


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
    assert csv_output([(row, None)], False).startswith("cluster,account,qos")
    assert json.loads(json_output([(row, None)], False))[0]["account"] == "soc-gpu-np"

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
    sorted_mixed = sort_pairs([(row, None)], "Cluster,QOS", reverse=False)
    assert sorted_mixed and sorted_mixed[0][0].cluster == "notchpeak"
    # Help text wires examples + case-insensitivity note.
    rendered = parser.format_help()
    assert "Examples" in rendered
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
        [(avail_row, None)], wide=False, include_avail=True, tty=True, term_width=60
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
        [(avail_row, None)], wide=False, include_avail=True, tty=False, term_width=60
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
        [(avail_row, None), (second, None)], wide=False, include_avail=True, tty=True, term_width=60
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
    probe_default = ProbeShape()
    rows_for_sort[0].wait_by_shape[probe_default.label] = 7200
    rows_for_sort[1].wait_by_shape[probe_default.label] = 0
    rows_for_sort[2].wait_by_shape[probe_default.label] = None
    rows_for_sort[3].wait_by_shape[probe_default.label] = 3600
    pairs_for_sort = [(row, probe_default) for row in rows_for_sort]
    sorted_by_wait = sort_pairs(pairs_for_sort, "wait", reverse=False)
    assert [r.wait_by_shape[probe_default.label] for r, _ in sorted_by_wait] == [0, 3600, 7200, None]

    # Wait/shape columns show up in to_dict only when include_avail=True and a shape is supplied.
    avail_row.wait_by_shape[probe_default.label] = 0
    rendered_dict = avail_row.to_dict(include_avail=True, shape=probe_default)
    assert rendered_dict["wait"] == "now"
    assert rendered_dict["shape"] == probe_default.label
    assert "wait" not in avail_row.to_dict()
    assert "shape" not in avail_row.to_dict()

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

    prem_rows = [
        AllocationRow("notchpeak", "x", "u", "", "q-v100", "q-v100"),
        AllocationRow("notchpeak", "x", "u", "", "q-a100", "q-a100"),
        AllocationRow("notchpeak", "x", "u", "", "q-rtx",  "q-rtx"),
        AllocationRow("notchpeak", "x", "u", "", "q-h100", "q-h100"),
    ]
    prem_rows[0].gpu_types = ("v100",)
    prem_rows[1].gpu_types = ("a100", "a100_80gb_pcie")
    prem_rows[2].gpu_types = ("rtx2080ti",)
    prem_rows[3].gpu_types = ("h100nvl",)
    prem_pairs = [(row, None) for row in prem_rows]
    by_premium = sort_pairs(prem_pairs, "premium,qos", reverse=False)
    assert [r.qos for r, _ in by_premium] == ["q-a100", "q-h100", "q-rtx", "q-v100"], \
        [r.qos for r, _ in by_premium]
    by_premium_rev = sort_pairs(prem_pairs, "premium,qos", reverse=True)
    assert by_premium_rev[0][0].qos == "q-v100"

    payload = json.loads(json_output(prem_pairs, wide=True, include_help=True))
    assert isinstance(payload, dict)
    assert set(payload.keys()) == {"_help", "rows"}
    assert payload["_help"]["premium_gpus"] == list(PREMIUM_GPUS)
    assert "schema_version" in payload["_help"]
    assert "fields" in payload["_help"]
    assert "shape" in payload["_help"]["fields"]
    assert len(payload["rows"]) == len(prem_pairs)
    assert isinstance(json.loads(json_output(prem_pairs, wide=False)), list)

    # parse_shape_spec round-trip + label format.
    sh = parse_shape_spec("a100:4,mem=32G,time=24h")
    assert sh.gpu_type == "a100" and sh.gpu_count == 4
    assert sh.mem == "32G" and sh.time == "24h"
    assert sh.label == "a100:4@24h,32G", sh.label
    sh = parse_shape_spec("cpu:8,time=4h")
    assert sh.cpus == 8 and sh.gpu_type is None and sh.gpu_count is None
    assert sh.label == "cpu:8@4h", sh.label
    sh = parse_shape_spec("a100")
    assert sh.gpu_type == "a100" and sh.gpu_count == 1
    sh = parse_shape_spec("32")
    assert sh.cpus == 32 and sh.gpu_type is None
    sh = parse_shape_spec("cpus=8,mem=16G,gpus=h100nvl:1,time=4h")
    assert sh.cpus == 8 and sh.gpu_type == "h100nvl" and sh.gpu_count == 1
    assert sh.label == "h100nvl:1@4h,16G", sh.label
    # Multi-node prefix.
    sh = parse_shape_spec("nodes=2,cpus=4,time=1h")
    assert sh.nodes == 2 and sh.label == "2n*cpu:4@1h", sh.label
    # Wall short-format edges.
    assert _format_wall_short("00:01:00") == "1m"
    assert _format_wall_short("3-00:00:00") == "3d"
    assert _format_wall_short("01:30:00") == "1h30m"
    # Bad shape specs raise.
    for bad in ("", "cpus=", "time=banana", "weird=1", "cpus=0"):
        try:
            parse_shape_spec(bad)
        except CommandError:
            pass
        else:
            raise AssertionError(f"parse_shape_spec({bad!r}) should have raised")

    # _to_sbatch_wall canonicalizes compact forms for sbatch -t.
    assert _to_sbatch_wall("1h") == "01:00:00"
    assert _to_sbatch_wall("24h") == "1-00:00:00"
    assert _to_sbatch_wall("3-00:00:00") == "3-00:00:00"
    assert _to_sbatch_wall("01:30:00") == "01:30:00"
    assert _to_sbatch_wall("garbage") == "garbage"

    # default_shape_set: three-tier probe set; each shape probed at one or
    # more walltimes; each emission gated on accessibility.
    # Case A — full accessibility: Intel + AMD CPUs and 2080ti, v100, 3090,
    # a100, h100, h200, a6000 GPUs.
    intel_a100_row = AllocationRow(
        "notchpeak", "x", "u", "", "q-a100", "q-a100",
        cpu_features=("skl", "csl"),
    )
    intel_a100_row.gpu_types = ("a100", "a100_80gb_pcie", "v100", "2080ti")
    intel_h100_row = AllocationRow(
        "notchpeak", "x", "u", "", "q-h100", "q-h100",
        cpu_features=("emr",),
    )
    intel_h100_row.gpu_types = ("h100nvl", "3090", "a6000")
    amd_row = AllocationRow(
        "granite", "x", "u", "", "q-amd", "q-amd",
        cpu_features=("zen4", "gen"),
    )
    amd_row.gpu_types = ("h200",)
    rows_full = [intel_a100_row, intel_h100_row, amd_row]
    gpu_full = [s.label for s in default_shape_set(rows_full, kind="gpu", full=True)]
    cpu_full = [s.label for s in default_shape_set(rows_full, kind="cpu", full=True)]
    expected_gpu_full = {
        # dev (4h, 24h) — 2080ti, v100, 3090
        "2080ti:1@4h", "2080ti:1@24h",
        "v100:1@4h", "v100:1@24h",
        "3090:1@4h", "3090:1@24h",
        # research (1h, 2h, 4h, 12h, 24h, 72h → 3d label)
        "a100:1@1h", "a100:1@2h", "a100:1@4h",
        "a100:1@12h", "a100:1@24h", "a100:1@3d",
        "h100nvl:1@1h", "h100nvl:1@2h", "h100nvl:1@4h",
        "h100nvl:1@12h", "h100nvl:1@24h", "h100nvl:1@3d",
        "h200:1@1h", "h200:1@2h", "h200:1@4h",
        "h200:1@12h", "h200:1@24h", "h200:1@3d",
        # premium (8h, 24h, 72h → 3d, 7d)
        "a100:4@8h", "a100:4@24h", "a100:4@3d", "a100:4@7d",
        "h100nvl:4@8h", "h100nvl:4@24h", "h100nvl:4@3d", "h100nvl:4@7d",
        "a6000:4@8h", "a6000:4@24h", "a6000:4@3d", "a6000:4@7d",
    }
    expected_cpu_full = {
        "cpu:16@4h", "cpu:16@24h",
        "cpu-intel:32@1h", "cpu-intel:32@2h", "cpu-intel:32@4h",
        "cpu-intel:32@12h", "cpu-intel:32@24h", "cpu-intel:32@3d",
        "cpu-amd:32@1h", "cpu-amd:32@2h", "cpu-amd:32@4h",
        "cpu-amd:32@12h", "cpu-amd:32@24h", "cpu-amd:32@3d",
        "cpu-amd:64@8h", "cpu-amd:64@24h", "cpu-amd:64@3d", "cpu-amd:64@7d",
    }
    assert set(gpu_full) == expected_gpu_full, sorted(set(gpu_full) ^ expected_gpu_full)
    assert set(cpu_full) == expected_cpu_full, sorted(set(cpu_full) ^ expected_cpu_full)
    # Dedup picks the shortest matching concrete type per pattern (a100 over
    # a100_80gb_pcie; h100nvl is the shortest 'h100' match here).
    assert "a100_80gb_pcie:1@4h" not in gpu_full, gpu_full
    # Tier ordering: dev → research → premium; within tier, walltimes appear
    # in declared order (shorter first).
    cpu_idx = {label: idx for idx, label in enumerate(cpu_full)}
    gpu_idx = {label: idx for idx, label in enumerate(gpu_full)}
    assert cpu_idx["cpu:16@4h"] < cpu_idx["cpu:16@24h"]
    assert cpu_idx["cpu:16@24h"] < cpu_idx["cpu-intel:32@1h"]
    assert cpu_idx["cpu-intel:32@1h"] < cpu_idx["cpu-intel:32@3d"]
    assert cpu_idx["cpu-intel:32@3d"] < cpu_idx["cpu-amd:64@8h"]
    assert gpu_idx["2080ti:1@4h"] < gpu_idx["a100:1@1h"]
    assert gpu_idx["a100:1@1h"] < gpu_idx["a100:4@8h"]
    assert gpu_idx["a100:4@8h"] < gpu_idx["a100:4@7d"]

    # Trimmed default (full=False): fewer walltimes per tier, same tier set.
    gpu_trim = [s.label for s in default_shape_set(rows_full, kind="gpu")]
    expected_gpu_trim = {
        # dev (4h)
        "2080ti:1@4h", "v100:1@4h", "3090:1@4h",
        # research (1h, 24h, 72h)
        "a100:1@1h", "a100:1@24h", "a100:1@3d",
        "h100nvl:1@1h", "h100nvl:1@24h", "h100nvl:1@3d",
        "h200:1@1h", "h200:1@24h", "h200:1@3d",
        # premium (24h, 7d)
        "a100:4@24h", "a100:4@7d",
        "h100nvl:4@24h", "h100nvl:4@7d",
        "a6000:4@24h", "a6000:4@7d",
    }
    assert set(gpu_trim) == expected_gpu_trim, sorted(set(gpu_trim) ^ expected_gpu_trim)
    assert len(gpu_trim) < len(gpu_full)

    # tiers= filter: passing a subset restricts emissions; an empty/None tiers
    # value emits all tiers; an unknown tier raises CommandError.
    dev_only = [s.label for s in default_shape_set(rows_full, kind="gpu", tiers=["dev"])]
    assert set(dev_only) == {"2080ti:1@4h", "v100:1@4h", "3090:1@4h"}, dev_only
    rp = [
        s.label for s in default_shape_set(
            rows_full, kind="gpu", tiers=["research", "premium"]
        )
    ]
    assert all(not lbl.startswith(("2080ti", "v100", "3090")) for lbl in rp), rp
    assert any(lbl.startswith("a100:4") for lbl in rp), rp
    try:
        default_shape_set(rows_full, kind="gpu", tiers=["bogus"])
    except CommandError:
        pass
    else:
        raise AssertionError("default_shape_set should reject unknown tier names")

    # MIG-slice noise: shortest match wins over MIG variants.
    h200_row = AllocationRow(
        "granite", "x", "u", "", "q-h200", "q-h200",
        cpu_features=("zen4",),
    )
    h200_row.gpu_types = ("h200", "h200_1g.18gb", "h200_2g.35gb", "h200nvl")
    h200_labels = [
        s.label for s in default_shape_set([h200_row], kind="gpu", full=True)
    ]
    # h200 lives in research tier (walltimes 1h, 2h, 4h, 12h, 24h, 72h).
    for wall in ("1h", "2h", "4h", "12h", "24h", "3d"):  # 72h → "3d"
        assert f"h200:1@{wall}" in h200_labels, (wall, h200_labels)
    assert "h200_1g.18gb:1@4h" not in h200_labels, h200_labels
    # h200 NOT in premium tier (no @8h or @7d entry).
    assert "h200:1@8h" not in h200_labels, h200_labels
    assert "h200:1@7d" not in h200_labels, h200_labels

    # Case B — minimal accessibility: Intel CPU + a100 only. Each tier gated
    # independently; no AMD vendor → no cpu-amd shapes; no 2080ti/v100/3090/
    # h100/h200/a6000 → only a100 GPU shapes emit.
    minimal_row = AllocationRow(
        "notchpeak", "x", "u", "", "q-min", "q-min",
        cpu_features=("skl",),
    )
    minimal_row.gpu_types = ("a100",)
    minimal_gpu = [s.label for s in default_shape_set([minimal_row], kind="gpu", full=True)]
    minimal_cpu = [s.label for s in default_shape_set([minimal_row], kind="cpu", full=True)]
    assert set(minimal_gpu) == {
        "a100:1@1h", "a100:1@2h", "a100:1@4h",
        "a100:1@12h", "a100:1@24h", "a100:1@3d",
        "a100:4@8h", "a100:4@24h", "a100:4@3d", "a100:4@7d",
    }, sorted(minimal_gpu)
    assert set(minimal_cpu) == {
        "cpu:16@4h", "cpu:16@24h",
        "cpu-intel:32@1h", "cpu-intel:32@2h", "cpu-intel:32@4h",
        "cpu-intel:32@12h", "cpu-intel:32@24h", "cpu-intel:32@3d",
    }, sorted(minimal_cpu)

    # Case C — vendor-less rows: CPU dev shapes still emit (they're
    # vendor-agnostic) but research/premium vendor-tagged shapes are dropped.
    # GPU side is empty (no gpu_types).
    cpu_only_row = AllocationRow("notchpeak", "x", "u", "", "q-cpu", "q-cpu")
    cpu_only_row.gpu_types = ()
    assert default_shape_set([cpu_only_row], kind="gpu", full=True) == []
    cpu_only = [s.label for s in default_shape_set([cpu_only_row], kind="cpu", full=True)]
    assert cpu_only == ["cpu:16@4h", "cpu:16@24h"], cpu_only

    # _is_low_information_pair drops the four noise categories.
    li_shape = ProbeShape(cpus=4, time="01:00:00")
    big_shape = ProbeShape(cpus=4, time="7-00:00:00")
    ok_li_row = AllocationRow(
        "notchpeak", "x", "u", "", "q-ok", "q-ok",
        qos_info=QOSInfo("q-ok", max_wall="3-00:00:00"),
    )
    ok_li_row.free_nodes = "5/10"
    ok_li_row.wait_by_shape = {li_shape.label: 0}
    assert _is_low_information_pair(ok_li_row, li_shape) is False

    unk_row = AllocationRow(
        "notchpeak", "x", "u", "", "q-u", "q-u",
        qos_info=QOSInfo("q-u", max_wall="3-00:00:00"),
    )
    unk_row.free_nodes = "5/10"
    unk_row.wait_by_shape = {li_shape.label: None}
    assert _is_low_information_pair(unk_row, li_shape) is True

    no_wall_row = AllocationRow("notchpeak", "x", "u", "", "q-nw", "q-nw")
    no_wall_row.free_nodes = "5/10"
    no_wall_row.wait_by_shape = {li_shape.label: 0}
    assert _is_low_information_pair(no_wall_row, li_shape) is True

    short_qos_row = AllocationRow(
        "notchpeak", "x", "u", "", "q-s", "q-s",
        qos_info=QOSInfo("q-s", max_wall="3-00:00:00"),
    )
    short_qos_row.free_nodes = "5/10"
    short_qos_row.wait_by_shape = {big_shape.label: 0}
    assert _is_low_information_pair(short_qos_row, big_shape) is True

    empty_cap_row = AllocationRow(
        "notchpeak", "x", "u", "", "q-e", "q-e",
        qos_info=QOSInfo("q-e", max_wall="3-00:00:00"),
    )
    empty_cap_row.free_nodes = "0/10"
    empty_cap_row.wait_by_shape = {li_shape.label: 0}
    assert _is_low_information_pair(empty_cap_row, li_shape) is True

    # Aliases for the downstream expand_rows_by_shape test below.
    a100_row = intel_a100_row

    # _user_supplied_shape_flags detects each shape-related override.
    parser = _build_parser()
    assert _user_supplied_shape_flags(parser.parse_args([])) is False
    assert _user_supplied_shape_flags(parser.parse_args(["--cpus", "16"])) is True
    assert _user_supplied_shape_flags(parser.parse_args(["--time", "4h"])) is True
    assert _user_supplied_shape_flags(parser.parse_args(["--shape", "a100:1"])) is True
    assert _user_supplied_shape_flags(parser.parse_args(["--gpus", "a100:4"])) is True
    assert _user_supplied_shape_flags(parser.parse_args(["--mem", "32G"])) is True
    # --wait-for routes through apply_wait_for_shorthand which mutates cpus/gpus.
    a = parser.parse_args(["--wait-for", "cpu:32"])
    apply_wait_for_shorthand(a)
    assert _user_supplied_shape_flags(a) is True

    # expand_rows_by_shape filters skipped pairs (gpu shape on cpu row).
    a100_only = ProbeShape(gpu_type="a100", gpu_count=1)
    cpu_only_shape = ProbeShape(cpus=8)
    cpu_only_row.tags = ("cpu",)
    a100_row.tags = ("gpu",)
    pairs = expand_rows_by_shape(
        [cpu_only_row, a100_row], [cpu_only_shape, a100_only]
    )
    pair_labels = [(r.qos, s.label) for r, s in pairs]
    assert ("q-cpu", "cpu:8@1h") in pair_labels
    assert ("q-cpu", "a100:1@1h") not in pair_labels  # skipped: cpu row, gpu shape
    assert ("q-a100", "a100:1@1h") in pair_labels

    # collapse_uniform_walltimes: uniform-wait groups merge to one row,
    # non-uniform groups pass through unchanged.
    coll_row = AllocationRow(
        "notchpeak", "co", "u", "", "q-coll", "q-coll",
        qos_info=QOSInfo("q-coll", max_wall="3-00:00:00"), tags=("gpu",),
    )
    coll_row.gpu_types = ("h100nvl",)
    h_1h = ProbeShape(gpu_type="h100nvl", gpu_count=1, time="01:00:00")
    h_24h = ProbeShape(gpu_type="h100nvl", gpu_count=1, time="1-00:00:00")
    h_72h = ProbeShape(gpu_type="h100nvl", gpu_count=1, time="3-00:00:00")
    triple = [(coll_row, h_1h), (coll_row, h_24h), (coll_row, h_72h)]
    coll_row.wait_by_shape = {h_1h.label: 0, h_24h.label: 0, h_72h.label: 0}
    merged = collapse_uniform_walltimes(triple)
    assert len(merged) == 1, merged
    merged_shape = merged[0][1]
    assert merged_shape.label == "h100nvl:1@1h..3d", merged_shape.label
    assert coll_row.wait_by_shape[merged_shape.label] == 0
    # Non-uniform waits → no collapse.
    coll_row.wait_by_shape = {h_1h.label: 0, h_24h.label: 0, h_72h.label: 600}
    assert len(collapse_uniform_walltimes(triple)) == 3
    # Single-element group → unchanged.
    single = collapse_uniform_walltimes([(coll_row, h_1h)])
    assert len(single) == 1 and single[0][1] is h_1h
    # None shape (no-wait mode) → passed through untouched.
    assert collapse_uniform_walltimes([(coll_row, None)]) == [(coll_row, None)]

    parser_fmt = _build_parser()
    args_no_fmt = parser_fmt.parse_args([])
    assert args_no_fmt.format is None
    args_explicit = parser_fmt.parse_args(["--format", "table"])
    assert args_explicit.format == "table"

    # Renamed flags expose new dests; old names still parse as hidden aliases.
    a = parser_fmt.parse_args(["--no-availability"])
    assert a.no_availability is True
    a = parser_fmt.parse_args(["--no-avail"])  # legacy alias
    assert a.no_availability is True
    a = parser_fmt.parse_args(["--show-all"])
    assert a.show_all is True
    a = parser_fmt.parse_args(["--show-unknown"])  # legacy alias
    assert a.show_all is True
    a = parser_fmt.parse_args(["--freecycle-only"])
    assert a.freecycle_only is True and a.exclude_freecycle is False
    a = parser_fmt.parse_args(["--freecycle"])  # legacy alias
    assert a.freecycle_only is True
    a = parser_fmt.parse_args(["--exclude-freecycle"])
    assert a.exclude_freecycle is True
    a = parser_fmt.parse_args(["--no-freecycle"])  # legacy alias
    assert a.exclude_freecycle is True
    a = parser_fmt.parse_args(["--guest-only"])
    assert a.guest_only is True
    a = parser_fmt.parse_args(["--guest"])  # legacy alias
    assert a.guest_only is True
    a = parser_fmt.parse_args(["--exclude-guest"])
    assert a.exclude_guest is True
    a = parser_fmt.parse_args(["--no-guest"])  # legacy alias
    assert a.exclude_guest is True
    # New flags exist and default sensibly.
    a = parser_fmt.parse_args([])
    assert a.explain is False
    assert a.verbose is False
    assert a.pivot is False
    assert a.no_json_help is False
    assert parser_fmt.parse_args(["-v"]).verbose is True
    assert parser_fmt.parse_args(["--explain"]).explain is True
    assert parser_fmt.parse_args(["--pivot"]).pivot is True
    assert parser_fmt.parse_args(["--no-json-help"]).no_json_help is True

    # Mutex groups reject combos at parse time (SystemExit from argparse).
    for combo in (
        ["--gpu", "--cpu"],
        ["--freecycle-only", "--exclude-freecycle"],
        ["--guest-only", "--exclude-guest"],
    ):
        try:
            parser_fmt.parse_args(combo)
        except SystemExit:
            pass
        else:
            raise AssertionError(f"argparse should have rejected {combo}")

    # Help text shows argument groups + key DESCRIPTION/EPILOG sections + does
    # NOT show the legacy aliases.
    rendered = parser_fmt.format_help()
    for header in (
        "Filtering",
        "Probe shape",
        "Output",
        "Diagnostics & speed",
        "Inventory shortcuts",
        "Common entry points",
        "Quickstart:",
        "Common queries:",
        "Scripting / output:",
        # Sort key categories surface in --sort help.
        "Time:",
        "Quality:",
    ):
        assert header in rendered, f"expected {header!r} in --help"
    # Hidden aliases must not appear in --help. Use a word-boundary check so
    # '--no-avail' isn't mistakenly matched against '--no-availability'.
    for hidden in ("--no-avail", "--show-unknown", "--freecycle", "--no-freecycle",
                   "--guest", "--no-guest", "--avail"):
        assert not re.search(rf"{re.escape(hidden)}\b(?!-)", rendered), \
            f"hidden alias {hidden!r} leaked into --help"
    # New-name flags ARE in help.
    for visible in ("--no-availability", "--show-all", "--freecycle-only",
                    "--exclude-freecycle", "--guest-only", "--exclude-guest",
                    "--explain", "--pivot", "--no-json-help",
                    "--list-tiers", "--quick"):
        assert visible in rendered, f"expected {visible!r} in --help"

    # Better error messages: mem without unit + bad time + cpus=0 + bad gpu spec.
    try:
        parse_shape_spec("a100:4,mem=99")
    except CommandError as exc:
        msg = str(exc)
        assert "mem" in msg and "unit" in msg, msg
        assert "16G" in msg, msg
    else:
        raise AssertionError("parse_shape_spec('a100:4,mem=99') should have raised")
    try:
        parse_shape_spec("cpus=0")
    except CommandError as exc:
        assert "positive integer" in str(exc), str(exc)
    else:
        raise AssertionError("cpus=0 should have raised")
    try:
        parse_shape_spec("time=banana")
    except CommandError as exc:
        msg = str(exc)
        assert "time" in msg and ("Nh" in msg or "duration" in msg), msg
    else:
        raise AssertionError("time=banana should have raised")
    try:
        parse_gpu_spec("a100:")
    except CommandError as exc:
        assert "missing count" in str(exc), str(exc)
    else:
        raise AssertionError("'a100:' should have raised")
    try:
        parse_gpu_spec(":4")
    except CommandError as exc:
        assert "missing GPU type" in str(exc), str(exc)
    else:
        raise AssertionError("':4' should have raised")

    # _format_applied_filters captures only non-default flags.
    a = parser_fmt.parse_args([])
    assert _format_applied_filters(a) == []
    a = parser_fmt.parse_args([
        "--cluster", "notchpeak", "--account", "foo", "--gpu",
        "--gpu-type", "a100", "--min-wall", "12:00:00",
    ])
    bits = _format_applied_filters(a)
    assert "cluster=notchpeak" in bits
    assert "account=foo" in bits
    assert "--gpu" in bits
    assert "gpu-type=a100" in bits
    assert "min-wall=12:00:00" in bits

    # _zero_results_hint mentions applied filters and offers actionable hints.
    hint = _zero_results_hint(a)
    assert "0 allocations match" in hint
    assert "cluster=notchpeak" in hint
    assert "--list-gpus" in hint
    assert "-v" in hint  # suggest verbose mode
    # No filters → still produces a hint with the no-filters phrasing.
    hint_empty = _zero_results_hint(parser_fmt.parse_args([]))
    assert "no filters applied" in hint_empty

    # render_explain_plan: text and JSON forms, with shape accessibility tags.
    explain_rows = [intel_a100_row, amd_row]
    explain_shapes = [
        ProbeShape(gpu_type="a100", gpu_count=1, time="01:00:00"),
        ProbeShape(gpu_type="h100", gpu_count=4, time="1-00:00:00"),
    ]
    a = parser_fmt.parse_args(["--gpu"])
    text = render_explain_plan(explain_rows, explain_shapes, a, "text")
    assert "Allocations matching filters: 2" in text
    assert "Probe shape set (2)" in text
    assert "a100:1@1h" in text
    assert "Run without --explain" in text
    payload = json.loads(render_explain_plan(explain_rows, explain_shapes, a, "json"))
    assert payload["allocations_after_filter"] == 2
    assert payload["shape_count"] == 2
    assert isinstance(payload["shapes"], list) and len(payload["shapes"]) == 2
    assert "label" in payload["shapes"][0]
    assert "accessible_rows" in payload["shapes"][0]

    # pivot_output: rows × shapes with wait cells.
    pivot_row = AllocationRow(
        "notchpeak", "research", "u", "", "q-piv", "q-piv",
        qos_info=QOSInfo("q-piv", max_wall="3-00:00:00"),
    )
    pivot_row.tags = ("gpu",)
    pivot_row.gpu_types = ("a100", "h100nvl")
    s_a1 = ProbeShape(gpu_type="a100", gpu_count=1, time="01:00:00")
    s_a4 = ProbeShape(gpu_type="a100", gpu_count=4, time="01:00:00")
    s_h1 = ProbeShape(gpu_type="h100nvl", gpu_count=1, time="01:00:00")
    pivot_row.wait_by_shape = {
        s_a1.label: 0,
        s_a4.label: 3600,
        s_h1.label: None,
    }
    pivot_text = pivot_output([(pivot_row, s_a1), (pivot_row, s_a4), (pivot_row, s_h1)])
    pivot_lines = pivot_text.splitlines()
    assert pivot_lines[0].startswith("CLUSTER")
    assert "A100:1@1H" in pivot_lines[0] or "A100:1@1H" in pivot_lines[0].upper()
    # Body row shows the pivot row with three wait cells (now / 1h / ?).
    assert any("now" in line and "1h" in line and "?" in line for line in pivot_lines[2:]), \
        pivot_text
    # Empty input handled.
    assert pivot_output([]) == "(no matching allocations)"
    # No-shape pairs (no-wait mode) produce the same sentinel.
    assert pivot_output([(pivot_row, None)]) == "(no matching allocations)"

    # best_output: text and JSON forms; alternatives count; empty fallback.
    best_text = best_output([(pivot_row, s_a1), (pivot_row, s_a4)], "text")
    assert "#SBATCH --account=research" in best_text
    assert "#SBATCH --qos=q-piv" in best_text
    assert "#SBATCH --time=01:00:00" in best_text
    assert "predicted wait: now" in best_text
    assert "1 alternative" in best_text and "drop --best" in best_text
    best_json = json.loads(best_output([(pivot_row, s_a1), (pivot_row, s_a4)], "json"))
    assert best_json["account"] == "research"
    assert best_json["qos"] == "q-piv"
    assert best_json["predicted_wait_seconds"] == 0
    assert best_json["alternatives"] == 1
    assert best_output([], "text") == "# no allocations matched"
    assert json.loads(best_output([], "json")) is None

    # sbatch_json_output: deduplicated array of {cluster, account, qos, partition}.
    sbatch_row_a = AllocationRow("notchpeak", "research", "u", "notchpeak-gpu", "qa", "qa")
    sbatch_row_b = AllocationRow("granite", "mlres", "u", "granite-gpu", "qb", "qb")
    sbatch_row_dup = AllocationRow("notchpeak", "research", "u", "alt", "qa", "qa")  # dedup
    sbatch_payload = json.loads(
        sbatch_json_output([sbatch_row_a, sbatch_row_b, sbatch_row_dup])
    )
    assert isinstance(sbatch_payload, list) and len(sbatch_payload) == 2
    keys = {(item["account"], item["qos"]) for item in sbatch_payload}
    assert keys == {("research", "qa"), ("mlres", "qb")}

    # JSON output stability: include_help=False yields a bare array (consumed
    # via --no-json-help); include_help=True still wraps with _help + rows.
    bare = json.loads(json_output([(pivot_row, s_a1)], wide=False))
    assert isinstance(bare, list)
    wrapped = json.loads(json_output([(pivot_row, s_a1)], wide=False, include_help=True))
    assert "_help" in wrapped and "rows" in wrapped

    # _resolve_output_format auto-switches when stdout is not a TTY (we
    # simulate with an explicit format set instead — the auto path is
    # exercised by main()).
    a = parser_fmt.parse_args(["--format", "csv"])
    fmt, wide, auto = _resolve_output_format(a)
    assert fmt == "csv" and wide is False and auto is False

    # --pivot rejected with --format=json or --format=csv (validated in main()).
    # Just verify the parser accepts the combo so the runtime check is what
    # rejects it.
    assert parser_fmt.parse_args(["--pivot", "--format", "json"]).pivot is True

    # --avail (legacy hidden no-op) was removed; argparse rejects it now.
    try:
        parser_fmt.parse_args(["--avail"])
    except SystemExit:
        pass
    else:
        raise AssertionError("--avail should have been removed")

    # --list-tiers + --quick parse and produce the expected dest values.
    assert parser_fmt.parse_args(["--list-tiers"]).list_tiers is True
    assert parser_fmt.parse_args(["--quick"]).quick is True

    # format_tier_listing renders section-grouped sections with both gpu and
    # cpu shapes under each tier (dev / research / premium).
    listing = format_tier_listing(full=False)
    assert "Default tier set" in listing
    assert "DEV" in listing and "RESEARCH" in listing and "PREMIUM" in listing
    assert "middle" not in listing.lower()  # collapsed into dev
    # Default trimmed dev walltime is 4h.
    assert "2080ti:1@4h" in listing and "cpu:16@4h" in listing
    assert "cpu-intel:32" in listing and "cpu-amd:32" in listing
    assert "cpu-amd:64" in listing
    assert "@7d" in listing  # premium
    # --full produces a strict superset of walltimes per tier (dev gains 24h).
    listing_full = format_tier_listing(full=True)
    assert "2080ti:1@24h" in listing_full and "cpu:16@24h" in listing_full
    # show_gpu/show_cpu narrow output.
    gpu_only = format_tier_listing(show_gpu=True, show_cpu=False)
    assert "cpu:16" not in gpu_only and "2080ti:1@4h" in gpu_only
    cpu_only_listing = format_tier_listing(show_gpu=False, show_cpu=True)
    assert "2080ti" not in cpu_only_listing and "cpu:16@4h" in cpu_only_listing

    # _shape_tier maps each shape back to its tier label correctly.
    assert _shape_tier(ProbeShape(cpus=DEV_CPU_CORES, time="4h")) == "dev"
    assert _shape_tier(ProbeShape(cpus=RESEARCH_CPU_CORES, time="1h", cpu_vendor="intel")) == "research"
    assert _shape_tier(ProbeShape(cpus=PREMIUM_CPU_AMD_CORES, time="24h", cpu_vendor="amd")) == "premium"
    assert _shape_tier(ProbeShape(gpu_type="2080ti", gpu_count=1)) == "dev"
    assert _shape_tier(ProbeShape(gpu_type="v100", gpu_count=1)) == "dev"
    assert _shape_tier(ProbeShape(gpu_type="3090", gpu_count=1)) == "dev"
    assert _shape_tier(ProbeShape(gpu_type="a100", gpu_count=1)) == "research"
    assert _shape_tier(ProbeShape(gpu_type="a100", gpu_count=4)) == "premium"

    # --tier flag parses and rejects unknown values.
    assert parser_fmt.parse_args(["-t", "dev"]).tier == ["dev"]
    assert parser_fmt.parse_args(
        ["-t", "dev", "--tier", "research"]
    ).tier == ["dev", "research"]
    try:
        parser_fmt.parse_args(["--tier", "bogus"])
    except SystemExit:
        pass
    else:
        raise AssertionError("--tier should reject unknown values")

    # Group membership: each flag must be DEFINED inside its group's section
    # (not just mentioned in DESCRIPTION/EPILOG). argparse renders each flag
    # entry as "  --flag-name  ..." with two-space indent, so search for that
    # pattern within the slice between two adjacent group headers.
    out_idx = rendered.index("Output:")
    diag_idx = rendered.index("Diagnostics & speed:")
    inv_idx = rendered.index("Inventory shortcuts:")
    examples_idx = rendered.index("Examples")
    output_section = rendered[out_idx:diag_idx]
    diag_section = rendered[diag_idx:inv_idx]
    inv_section = rendered[inv_idx:examples_idx]
    assert "  --full" in output_section, "--full not in Output group"
    assert "  --show-all" in output_section, "--show-all not in Output group"
    assert "  --quick" in diag_section, "--quick not in Diagnostics group"
    assert "  --list-tiers" in inv_section, "--list-tiers not in Inventory group"

    print("self-test passed")
    return 0


def _resolve_output_format(args: argparse.Namespace) -> Tuple[str, bool, bool]:
    """Pick (fmt, wide, auto_switched) for this run.

    Default: table on a TTY, json (wide) when stdout is piped or redirected.
    Explicit --format always wins. --sbatch keeps fmt=None unless the user
    set it, since sbatch's text/json branching is decided by main().
    """
    fmt = args.format
    wide = args.wide
    auto_switched = False
    if fmt is None and not args.sbatch:
        if sys.stdout.isatty():
            fmt = "table"
        else:
            fmt = "json"
            wide = True
            auto_switched = True
    return (fmt or "table"), wide, auto_switched


# Legacy long-form flags kept around for muscle-memory scripts. argparse
# silently accepts them (help=SUPPRESS); we emit a one-line stderr notice
# so users discover the new spelling. Map: legacy → current.
_LEGACY_ALIAS_MAP = {
    "--freecycle": "--freecycle-only",
    "--no-freecycle": "--exclude-freecycle",
    "--guest": "--guest-only",
    "--no-guest": "--exclude-guest",
    "--show-unknown": "--show-all",
    "--no-avail": "--no-availability",
}


def _warn_legacy_aliases(argv: Sequence[str], verbose: bool) -> None:
    """Emit one stderr line per legacy alias used.

    Notice is suppressed unless stderr is a TTY or --verbose is set, mirroring
    _maybe_emit_format_auto_notice — keeps logged pipelines quiet but lets
    interactive users discover the rename.
    """
    if not (verbose or sys.stderr.isatty()):
        return
    # split('=', 1)[0] handles '--no-avail=foo'-style tokens.
    used = dict.fromkeys(
        head for head in (token.split("=", 1)[0] for token in argv)
        if head in _LEGACY_ALIAS_MAP
    )
    for alias in used:
        replacement = _LEGACY_ALIAS_MAP[alias]
        print(
            f"[chpc-allocs] {alias} is a legacy alias; prefer {replacement}.",
            file=sys.stderr,
        )


def _maybe_emit_format_auto_notice(auto_switched: bool, verbose: bool) -> None:
    """Print a stderr line when --format auto-switched to JSON.

    The notice fires only when stderr is a TTY (so logged pipelines stay
    quiet) or when --verbose is on (so users debugging an auto-switch can
    see it under any setup).
    """
    if not auto_switched:
        return
    if not (verbose or sys.stderr.isatty()):
        return
    print(
        "[chpc-allocs] stdout is piped — output is JSON (wide). "
        "Pass --format=table to override or --format=json to silence this notice.",
        file=sys.stderr,
    )


def main(argv: Sequence[str]) -> int:
    if not argv:
        _build_parser().print_help()
        return 0
    args = parse_args(argv)
    if args.self_test:
        return run_self_test()
    _warn_legacy_aliases(argv, args.verbose)
    if args.quick:
        args.no_wait = True
        args.no_availability = True
        args.no_usage = True
    if args.list_tiers:
        print(format_tier_listing(
            full=args.full,
            show_gpu=not args.cpu,
            show_cpu=not args.gpu,
        ))
        return 0
    apply_wait_for_shorthand(args)
    # Catches the awkward old-alias cross-pair combos (e.g. --freecycle
    # --exclude-freecycle) that the argparse mutex groups don't see.
    if args.freecycle_only and args.exclude_freecycle:
        raise CommandError("--freecycle-only and --exclude-freecycle cannot be used together")
    if args.guest_only and args.exclude_guest:
        raise CommandError("--guest-only and --exclude-guest cannot be used together")
    if args.cpus <= 0:
        raise CommandError(f"--cpus must be > 0 (got {args.cpus})")
    if args.nodes <= 0:
        raise CommandError(f"--nodes must be > 0 (got {args.nodes})")
    if parse_wall_seconds(args.time) is None:
        raise CommandError(
            f"invalid --time value {args.time!r}\n"
            f"  expected: HH:MM:SS, D-HH:MM:SS, Nd, or compact 'Nh'/'Nm' "
            f"(e.g. 1:00:00, 24h, 3d, 30m)"
        )
    if args.pivot and args.format in ("csv", "json"):
        raise CommandError(
            "--pivot is only supported with --format=table\n"
            "  hint: drop --format, or post-process the long-format JSON/CSV with jq/awk"
        )
    if args.best:
        if args.no_wait:
            raise CommandError(
                "--best needs wait data; drop --no-wait/--quick"
            )
        if args.sbatch or args.pivot:
            raise CommandError(
                "--best is incompatible with --sbatch and --pivot"
            )
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

    # If the user passed --cpus/--nodes/--gpus/--mem/--time without --shape,
    # the implicit multi-tier default is silently disabled and a single shape
    # runs. Surface this so users don't wonder why they got one row instead
    # of the usual ~20. Skip when --no-wait (no probe to be confused about),
    # --explain (the plan output already shows the shape), or --shape (user
    # opted into single-shape explicitly).
    if (
        not args.no_wait
        and not args.shape
        and not args.explain
        and _user_supplied_shape_flags(args)
        and (args.verbose or sys.stderr.isatty())
    ):
        tier_note = (
            " (--tier is ignored without the multi-tier default)"
            if args.tier else ""
        )
        print(
            f"[chpc-allocs] using a single explicit shape ({shape.label}); "
            f"the multi-tier default is disabled{tier_note}. Drop --cpus/"
            "--nodes/--gpus/--mem/--time to restore it, or pass --shape "
            "(repeatable) for multi-shape probing.",
            file=sys.stderr,
        )

    if args.list_gpus:
        print(format_gpu_summary(show_partition_availability()))
        return 0
    if args.list_cpus:
        print(format_cpu_summary(show_partition_features(), show_partition_availability()))
        return 0

    user = os.environ.get("USER") or run_command(["id", "-un"]).strip()
    rows = show_associations(user=user, all_visible=args.all_visible)
    include_avail = not args.no_availability
    include_wait = include_avail and not args.no_wait
    partition_avail = show_partition_availability() if include_avail else None
    # When availability data is loaded, derive the gpu-types map from it for
    # free (no second sinfo call) — needed by the implicit 'premium' sort tier
    # so a100/h100/h200/a6000 rows surface even without --gpu-type/--wide.
    # Matches the shape show_partition_gpus returns.
    if partition_avail is not None:
        partition_gpus: Dict[str, Dict[str, Dict[str, int]]] = {
            c: {p: {g: tot for g, (_free, tot) in bucket.gpus.items()} for p, bucket in parts.items()}
            for c, parts in partition_avail.items()
        }
    elif args.gpu_type or args.wide:
        partition_gpus = show_partition_gpus()
    else:
        partition_gpus = {}
    # cpu_vendor classification + Intel/AMD baseline shapes both rely on
    # partition features, so fetch them unless explicitly opted out.
    partition_features = (
        {} if args.no_availability and not (args.cpu_type or args.wide)
        else show_partition_features()
    )
    attach_metadata(
        rows,
        include_usage=(not args.no_usage and not args.all_visible),
        user=user,
        partition_gpus=partition_gpus,
        partition_features=partition_features,
        partition_avail=partition_avail,
    )
    rows = filter_rows(rows, args)
    shapes: List[ProbeShape] = []
    if include_wait:
        if args.shape:
            shapes = [parse_shape_spec(s) for s in args.shape]
        elif _user_supplied_shape_flags(args):
            shapes = [shape]
        else:
            shapes = default_shape_set(
                rows,
                kind="cpu" if args.cpu else "gpu",
                full=args.full,
                tiers=args.tier,
            )

    # --explain: print the resolved plan and exit before any probes run.
    if args.explain:
        explain_fmt = args.format if args.format in ("json",) else "text"
        print(render_explain_plan(rows, shapes, args, explain_fmt))
        return 0

    if include_wait:
        if not args.show_all:
            rows = [r for r in rows if not _is_unprobeable_row(r)]
        predict_wait_times(rows, shapes=shapes, verbose=args.verbose)
    pairs = expand_rows_by_shape(rows, shapes if include_wait else None)
    if include_wait and not args.show_all:
        pairs = [p for p in pairs if not _is_low_information_pair(*p)]
        if not args.full:
            pairs = collapse_uniform_walltimes(pairs)
    sort_spec = args.sort
    if sort_spec is None:
        sort_spec = (
            "wait,shape,premium,vendor,cluster,qos" if include_wait
            else "premium,vendor,cluster,account,qos"
        )
    pairs = sort_pairs(pairs, sort_spec, args.reverse)

    # If filtering left no rows, surface a hint so the user can self-debug.
    # Skip when an output-mode flag will produce its own empty-set message.
    if not pairs and _is_default_output_mode(args):
        print(_zero_results_hint(args), file=sys.stderr)

    fmt, wide, auto_switched = _resolve_output_format(args)
    _maybe_emit_format_auto_notice(auto_switched, args.verbose)

    if args.best:
        output = best_output(pairs, fmt)
    elif args.sbatch:
        if fmt == "json":
            output = sbatch_json_output([row for row, _ in pairs])
        else:
            output = sbatch_output([row for row, _ in pairs])
    elif args.pivot:
        output = pivot_output(pairs)
    elif fmt == "csv":
        output = csv_output(pairs, wide, include_avail=include_avail, include_wait=include_wait)
    elif fmt == "json":
        output = json_output(
            pairs,
            wide,
            include_avail=include_avail,
            include_wait=include_wait,
            include_help=not args.no_json_help,
        )
    else:
        output = table_output(pairs, wide, include_avail=include_avail, include_wait=include_wait)

    print(output)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except CommandError as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(2)
