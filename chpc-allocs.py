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
from typing import Dict, Iterable, Iterator, List, Optional, Sequence, Set, Tuple


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


# ════════════════════════════════════════════════════════════════════
# Shape grammar — classification tables (CPU vendor/microarch, GPU
# generation/SM compute capability). These data tables and their
# alias/classification helpers form the vocabulary used by the
# HardwareFilter and shape parsers below.
# ════════════════════════════════════════════════════════════════════

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

# Long-form microarchitecture aliases → canonical short feature token. Keys are
# checked after lowercasing; both hyphenated and concatenated forms are listed.
# zen1..zen5 are intentionally omitted: substring-matching `zen` already covers
# them in INTEL_CPU_FEATURES/AMD_CPU_FEATURES, and they pass through to
# row.cpu_features unchanged for accurate constraint expressions.
CPU_ARCH_ALIASES = {
    "skylake": "skl",
    "cascadelake": "csl", "cascade-lake": "csl",
    "icelake": "icx", "ice-lake": "icx",
    "sapphirerapids": "spr", "sapphire-rapids": "spr",
    "emeraldrapids": "emr", "emerald-rapids": "emr",
    "cooperlake": "cpx", "cooper-lake": "cpx",
    "broadwell": "bro",
    "haswell": "hsw",
    "ivybridge": "ivy", "ivy-bridge": "ivy",
    "sandybridge": "snb", "sandy-bridge": "snb",
    "knightslanding": "knl", "knights-landing": "knl",
    "naples": "nap",
    "rome": "rom",
    "milan": "mil",
    "genoa": "gen",
}

# Display name for each canonical short arch token. Surfaced by --list-cpus
# so users see "Cascade Lake" rather than the sinfo feature token "csl".
# Add new entries here when you extend CPU_ARCH_ALIASES so a future arch
# isn't displayed only as its short token.
CPU_ARCH_LONG = {
    "skl": "Skylake",
    "csl": "Cascade Lake",
    "icx": "Ice Lake",
    "spr": "Sapphire Rapids",
    "emr": "Emerald Rapids",
    "cpx": "Cooper Lake",
    "bro": "Broadwell",
    "hsw": "Haswell",
    "ivy": "Ivy Bridge",
    "snb": "Sandy Bridge",
    "knl": "Knights Landing",
    "nap": "Naples",
    "rom": "Rome",
    "mil": "Milan",
    "gen": "Genoa",
    **{f"zen{i}": f"Zen {i}" for i in range(1, 6)},
}

# `zen<N>` literals (zen1..zen5) recognized as arch atoms. Stored in cpu_archs
# verbatim so `--constraint=zen4` filters to that exact feature, while bare
# `zen` falls through CPU_ARCH_ALIASES into the substring-match path.
_ZEN_ARCH_LITERALS = tuple(f"zen{i}" for i in range(1, 6))

# Vendor-OR `--constraint` expressions, built once. SLURM constraint syntax:
# `a|b|c` = any-of. Used by ProbeShape.to_sbatch_args when only a vendor is
# requested (no specific arch).
VENDOR_CONSTRAINT_EXPR = {
    "intel": "|".join(INTEL_CPU_FEATURES),
    "amd": "|".join(AMD_CPU_FEATURES),
}


def _canon_cpu_arch(tok: str) -> Optional[str]:
    """Resolve a token to a canonical short-form CPU arch tag, or None.

    Accepts short forms (`skl`, `gen`, `rom`, ...), long forms via
    CPU_ARCH_ALIASES (`skylake`, `genoa`, `rome`, ...), and `zen<N>` literals.
    Returns the token suitable for a `--constraint=` value and for substring
    matching against row.cpu_features.
    """
    if not tok:
        return None
    t = tok.lower()
    if t in INTEL_CPU_FEATURES or t in AMD_CPU_FEATURES:
        return t
    if t in CPU_ARCH_ALIASES:
        return CPU_ARCH_ALIASES[t]
    if t in _ZEN_ARCH_LITERALS:
        return t
    return None


def _features_match_vendor(features, vendor: str) -> bool:
    """True iff any feature token substring-matches the given vendor's table.

    Mirrors classify_cpu_vendor's substring logic but for a single vendor.
    """
    table = INTEL_CPU_FEATURES if vendor == "intel" else AMD_CPU_FEATURES
    for feat in features or ():
        f = feat.lower()
        if any(p in f for p in table):
            return True
    return False


# NVIDIA GPU generation aliases → canonical short tag. Long forms collapse
# to a single canonical name stored in ProbeShape.gpu_gen.
GPU_GEN_ALIASES = {
    "kepler": "kepler",
    "maxwell": "maxwell",
    "pascal": "pascal",
    "volta": "volta",
    "turing": "turing",
    "ampere": "ampere",
    "ada": "ada",
    "lovelace": "ada",
    "adalovelace": "ada",
    "ada-lovelace": "ada",
    "hopper": "hopper",
    "blackwell": "blackwell",
}

# Numeric ordering for `gen_min=` comparisons. The integer is the lowest SM
# compute capability for that generation's family on this cluster — used as
# the threshold when expanding gen_min to an SM lower bound.
GPU_GEN_ORDER = {
    "kepler": 30,
    "maxwell": 50,
    "pascal": 60,
    "volta": 70,
    "turing": 75,
    "ampere": 80,
    "ada": 89,
    "hopper": 90,
    "blackwell": 100,
}

# Recognized SM compute-capability tokens, accepted as positional `sm70` /
# `sm_70` and as `sm=N` / `sm_min=N` integer values. Constrained to the SMs
# that classify into known generations on this cluster.
GPU_SM_TOKENS = (70, 75, 80, 86, 89, 90, 100, 120)

# Ordered substring classifier: GRES token → (generation, sm). First match
# wins, so longer/more-specific patterns must come before shorter prefixes
# (e.g. `rtx4000ada` before any bare `rtx4000`). MIG-slice tokens like
# `h200_1g.18gb` and `a100_80gb_pcie_1g.10gb` inherit via substring match
# on `h200`/`a100`.
GPU_TOKEN_CLASSIFIERS = (
    # Blackwell (sm_120). RTX PRO 4000/6000 Blackwell first, before any
    # rtx4000/rtx6000 prefix would shadow them.
    ("rtxpr6000bl",    "blackwell", 120),
    ("rtxpr4000bl",    "blackwell", 120),
    ("blackwell",      "blackwell", 120),
    # Hopper (sm_90).
    ("h200nvl",        "hopper",     90),
    ("h200",           "hopper",     90),
    ("h100nvl",        "hopper",     90),
    ("h100",           "hopper",     90),
    ("h800",           "hopper",     90),
    # Ada Lovelace (sm_89). All `*ada` variants before bare `rtx####`.
    ("rtx6000ada",     "ada",        89),
    ("rtx5000ada",     "ada",        89),
    ("rtx4500ada",     "ada",        89),
    ("rtx4000ada",     "ada",        89),
    ("rtx2000ada",     "ada",        89),
    ("l40s",           "ada",        89),
    ("l40",            "ada",        89),
    ("l4",             "ada",        89),
    # Ampere (sm_80 datacenter, sm_86 workstation/consumer).
    ("a100",           "ampere",     80),
    ("a800",           "ampere",     80),
    ("a30",            "ampere",     80),
    ("a40",            "ampere",     86),
    ("a6000",          "ampere",     86),
    ("a5500",          "ampere",     86),
    ("a5000",          "ampere",     86),
    ("a4500",          "ampere",     86),
    ("rtxa6000",       "ampere",     86),
    ("3090",           "ampere",     86),
    ("3080",           "ampere",     86),
    # Turing (sm_75) — must follow all `*ada`/`*bl` variants above.
    ("titanrtx",       "turing",     75),
    ("rtx2000",        "turing",     75),
    ("rtx5000",        "turing",     75),
    ("rtx6000",        "turing",     75),
    ("2080ti",         "turing",     75),
    ("t4",             "turing",     75),
    # Volta (sm_70).
    ("titanv",         "volta",      70),
    ("v100",           "volta",      70),
    # Pascal (sm_61). p40 = sm_61, p100 = sm_60; we report the family minimum.
    ("p100",           "pascal",     60),
    ("p40",            "pascal",     61),
    ("p4",             "pascal",     61),
    # Maxwell (sm_52) and Kepler (sm_35) included for completeness.
    ("m40",            "maxwell",    52),
    ("k80",            "kepler",     37),
    ("k40",            "kepler",     35),
    ("k20",            "kepler",     35),
)


def _canon_gpu_gen(tok: str) -> Optional[str]:
    """Resolve a token to a canonical NVIDIA generation tag, or None."""
    if not tok:
        return None
    return GPU_GEN_ALIASES.get(tok.lower())


def _parse_sm_token(tok: str) -> Optional[int]:
    """Parse `sm70` / `sm_70` (case-insensitive) → int 70, or None.

    Returns None for any value not in GPU_SM_TOKENS so unknown SMs (e.g.
    typos like `sm99`) fall through to the GPU-spec fallback for diagnosis.
    """
    if not tok:
        return None
    s = tok.lower()
    if not s.startswith("sm"):
        return None
    rest = s[2:]
    if rest.startswith("_"):
        rest = rest[1:]
    if not rest.isdigit():
        return None
    n = int(rest)
    return n if n in GPU_SM_TOKENS else None


def _classify_gpu_token(token: str) -> Optional[Tuple[str, int]]:
    """Return (generation, sm) for a GRES token, or None if unrecognized."""
    if not token:
        return None
    t = token.lower()
    for pattern, gen, sm in GPU_TOKEN_CLASSIFIERS:
        if pattern in t:
            return (gen, sm)
    return None


def _parse_sm_int(val: str) -> Optional[int]:
    """Validate `val` as a known SM integer, or return None."""
    if val.isdigit() and int(val) in GPU_SM_TOKENS:
        return int(val)
    return None


def _gpu_token_satisfies(
    token: str,
    *,
    gen: Optional[str],
    sm: Optional[int],
    gen_min: Optional[str],
    sm_min: Optional[int],
) -> bool:
    """True iff this GRES token satisfies all set generation/SM constraints."""
    cls = _classify_gpu_token(token)
    if cls is None:
        return False
    tok_gen, tok_sm = cls
    if gen is not None and tok_gen != gen:
        return False
    if sm is not None and tok_sm != sm:
        return False
    if gen_min is not None and tok_sm < GPU_GEN_ORDER[gen_min]:
        return False
    if sm_min is not None and tok_sm < sm_min:
        return False
    return True


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


# ════════════════════════════════════════════════════════════════════
# Shape grammar — parser hints, regex, and recognized atoms
# Consolidated here so adding/changing a shape atom touches one place.
# ════════════════════════════════════════════════════════════════════

_VENDORS = ("intel", "amd")

_VENDOR_HINT = "vendor=intel|amd"
_ARCH_HINT = (
    "short forms (skl, csl, icx, spr, emr, cpx, bro, hsw, ivy, snb, knl, "
    "zen, nap, rom, mil, gen, zen1..zen5) or long forms "
    "(skylake, cascadelake, icelake, sapphirerapids, broadwell, haswell, "
    "naples, rome, milan, genoa, ...)"
)
_GEN_HINT = (
    "one of kepler, maxwell, pascal, volta, turing, ampere, ada (alias "
    "lovelace), hopper, blackwell"
)
_SM_HINT = (
    "integer compute capability from " + ", ".join(str(n) for n in GPU_SM_TOKENS)
    + " (e.g. sm80, sm_80, sm=80, sm_min=80)"
)
_GPUS_EXPECTED = (
    "'TYPE:COUNT' (e.g. a100:4), 'COUNT' (any GPU type, e.g. 4), or "
    "'TYPE' (1 of that type, e.g. a100)"
)
_GPUS_HINT = "chpc-allocs --list-gpus for available types"
_SHAPE_HINT = "chpc-allocs --help (Probe shape group), or examples in --help"

_MEM_RE = re.compile(r"^\d+[kmgtKMGT][bB]?$")


# Probe-shape defaults — used by ProbeShape() and parse_shape_spec().
DEFAULT_PROBE_CPUS = 1
DEFAULT_PROBE_NODES = 1
DEFAULT_PROBE_TIME = "01:00:00"


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

    def _gpus_cell(self, shape: Optional["ProbeShape"]) -> str:
        """Compact cell for the `gpus` column: the row's GPU type resolved
        from the probe shape's gpu_type (e.g. shape says 'h100', row exposes
        'h100nvl'). Empty for CPU-only rows or shapes without a gpu_type.
        """
        if not self.gpu_types or shape is None:
            return ""
        resolved = shape.resolved_gpu_type(self)
        return resolved or ""

    def to_dict(
        self,
        wide: bool = False,
        include_avail: bool = False,
        include_wait: bool = True,
        shape: Optional["ProbeShape"] = None,
        show_gpus: bool = False,
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
                data["shape"] = shape.label
                wait_secs = self.wait_by_shape.get(shape.label)
            else:
                data["shape"] = ""
                wait_secs = None
            data["wait"] = _format_wait(wait_secs)
        data["wall"] = self.qos_info.max_wall
        data["tags"] = ",".join(self.tags)
        if show_gpus:
            data["gpus"] = self._gpus_cell(shape)
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
wait time. With no args, this help is printed. Pass a SHAPE_LIST to probe
those shapes; a one-line "Probing:" banner on stderr shows the planned
shapes before probing.

Common entry points:
  chpc-allocs                       print this help
  chpc-allocs a100:4                a single a100x4 probe
  chpc-allocs cpu:32                a single 32-core CPU probe
  chpc-allocs a100:4+cpu:32         two alternatives ('+' = OR, no quoting)
  chpc-allocs 'a100:4*cpu:32'       one combined job ('*' = AND, quote in shells that glob '*')
  chpc-allocs 'a100:4*intel'        constrain to Intel hosts (vendor atom)
  chpc-allocs 'gpu:4*ampere'        any 4 Ampere GPUs (gen atom)
  chpc-allocs 'gpu:1,sm_min=80'     any GPU with compute capability >= 8.0
  chpc-allocs --best a100:4         lowest-wait runnable triple as paste-ready #SBATCH
  chpc-allocs --quick               list allocations, no probes
  chpc-allocs --explain a100:4      preview the probe plan, run nothing
  chpc-allocs --list-gpus           cluster GPU inventory (no allocations needed)
  chpc-allocs --list-gpus a100:1    inventory narrowed to partitions exposing a100
"""

EPILOG = """\
Examples
────────
Quickstart:
  chpc-allocs a100:4                          # when can my a100x4 job run?
  chpc-allocs cpu:32                          # ... or a 32-core CPU job
  chpc-allocs a100:4+cpu:32@12h               # two alternatives ('+' = OR)
  chpc-allocs 'a100:4*cpu:32@12h'             # one combined job ('*' = AND)
  chpc-allocs 'a100:4*cpu:32+h100:1'          # AND inside, OR across ('*' binds tighter)
  chpc-allocs --explain a100:4                # preview the plan, run nothing

Shape grammar:
  chpc-allocs h100:1                          # 'h100' resolves to actual GRES (e.g. h100nvl)
  chpc-allocs 'a100:4*intel'                  # a100x4 only on Intel hosts
  chpc-allocs 'cpu:32*genoa'                  # 32-core CPU on Genoa nodes (alias 'gen')
  chpc-allocs zen4                            # 1 cpu on any Zen 4 host
  chpc-allocs 'gpu:4*ampere'                  # any 4 Ampere GPUs (gen atom)
  chpc-allocs 'gpu:1,sm_min=80'               # 1 GPU with compute capability >= 8.0
  chpc-allocs 'a100:4@12h,vendor=intel'       # walltime + vendor key=value
  Vendors: intel, amd. Microarchitectures (short or long form):
    Intel: skl/skylake, csl/cascadelake, icx/icelake, spr/sapphirerapids,
           emr/emeraldrapids, cpx/cooperlake, bro/broadwell, hsw/haswell,
           ivy/ivybridge, snb/sandybridge, knl/knightslanding
    AMD:   nap/naples, rom/rome, mil/milan, gen/genoa, zen, zen1..zen5
  GPU generation / SM compute capability (NVIDIA):
    Generations: kepler, maxwell, pascal, volta, turing, ampere,
                 ada (= lovelace), hopper, blackwell
    SM atoms:    sm70, sm75, sm80, sm86, sm89, sm90, sm100, sm120
                 (also sm_70, sm_80, ...)
    Ranges (key=value only): sm_min=80, gen_min=ampere
    Note: '+' suffix (e.g. 'sm80+') is NOT supported — '+' is the
          shape-list OR separator. Use 'sm_min=80' instead.

Filtering rows (repeatable, OR-matched, case-insensitive substrings):
  chpc-allocs --cluster notchpeak                       # one cluster only
  chpc-allocs --cluster notchpeak --cluster granite     # union of two clusters
  chpc-allocs --account sadayappan a100:4               # narrow by account
  chpc-allocs --qos notchpeak-gpu --quick               # narrow by QOS
  chpc-allocs --cluster notchpeak --account sadayappan a100:4

Freecycle / guest / reservation / walltime:
  chpc-allocs --freecycle-only a100:4                   # preemptable only
  chpc-allocs --exclude-guest cpu:32                    # hide guest rows
  chpc-allocs --reservation --quick                     # only reservation-gated QOS
  chpc-allocs --min-wall 24:00:00 --quick               # MaxWall >= 24h
  chpc-allocs --min-wall 7d a100:4                      # MaxWall >= 7 days

Sorting and trimming:
  chpc-allocs --sort wait,premium a100:4                # cheapest premium GPU first
  chpc-allocs --sort cluster,qos --reverse --quick      # group by cluster/qos, reversed
  chpc-allocs --full 'a100:1+a100:4'                    # don't collapse uniform-wait rows
  chpc-allocs --show-all a100:4                         # keep '?' / over-MaxWall rows

Inventory shortcuts (do not consult your allocations; SHAPE_LIST narrows):
  chpc-allocs --list-gpus                               # full GPU inventory
  chpc-allocs --list-gpus a100:1                        # only partitions exposing a100
  chpc-allocs --list-gpus 'a100:4*intel'                # ... and only Intel hosts
  chpc-allocs --list-cpus                               # full CPU inventory
  chpc-allocs --list-cpus 'cpu:32*genoa'                # only Genoa nodes with >=32 cores

Recipes:
  chpc-allocs --best a100:4                             # paste-ready #SBATCH for fastest triple
  chpc-allocs --best a100:4 --format json | jq .        # same, machine-readable
  chpc-allocs --sbatch --quick                          # all my allocations as #SBATCH blocks
  chpc-allocs --sbatch a100:4 --format json             # JSON array of {cluster,account,qos,partition}
  chpc-allocs --pivot 'a100:1+a100:4+h100:1'            # shapes side-by-side, table only
  chpc-allocs intel+amd --pivot                         # compare Intel vs AMD

Speed (skip probes/queries):
  chpc-allocs --quick                                   # = --no-wait --no-availability --no-usage
  chpc-allocs --no-wait a100:4                          # keep capacity/usage, skip wait probe
  chpc-allocs --no-availability --no-usage cpu:32       # probe only, no sinfo/sshare

Scripting / output:
  chpc-allocs a100:1 --format json | jq '.rows[]'       # JSON with _help legend
  chpc-allocs --quick --wide --format csv > allocs.csv  # wide CSV dump

Diagnostics:
  chpc-allocs -v a100:1                       # narrate dropped rows + progress
  chpc-allocs --show-all a100:1               # don't hide marginal rows
  chpc-allocs --explain 'a100:4*intel+h100:1' # show resolved probe plan, run nothing
"""


def _lower_choice(value: str) -> str:
    return value.lower()


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        usage="chpc-allocs [SHAPE_LIST | --explain] [FILTER ...] [OUTPUT ...]",
        description=DESCRIPTION,
        epilog=EPILOG,
        formatter_class=argparse.RawDescriptionHelpFormatter,
        # Prefix abbreviation off: `--freecycle` no longer silently expands
        # to `--freecycle-only` (the same goes for `--guest` / `--no-guest`).
        allow_abbrev=False,
    )

    # Positional probe spec. Two-level grammar:
    #   '+' = OR (separate independent probes)
    #   '*' = AND (combine pieces into one job; binds tighter than '+')
    # E.g. 'a100:4*cpu:32+h100:1' = (a100:4 with 32 cpus) OR (h100:1).
    # Quote when '*' might glob in your shell. Parsed in main() via
    # parse_shape_list.
    parser.add_argument(
        "shape_pos", nargs="?", metavar="SHAPE_LIST", default=None,
        help="Probe shape, or list joined with '+' (alternatives, OR) and "
        "'*' (combine into one job, AND; binds tighter than '+'). "
        "Per-shape grammar: 'a100:4' (GPU), 'cpu:32' (32-core CPU), "
        "'gpu:4' (any GPU x 4), '32' (= cpu:32). Append '@DUR' for walltime: "
        "'a100:1@30m', 'cpu:32@12h'. CPU vendor/microarch atoms: 'intel', "
        "'amd', 'skl', 'genoa', 'rome', 'milan', 'zen4', etc. (filter rows + "
        "pass --constraint to sbatch). GPU generation / SM atoms: 'ampere', "
        "'hopper', 'ada', 'sm80', 'sm_89', etc. (filter rows + pin --gres "
        "type). Comma-separated key=value tokens (cores=, mem=, time=, "
        "gpus=, nodes=, vendor=, arch=, gen=, sm=, gen_min=, sm_min=) also "
        "accepted, e.g. 'gpu:1,sm_min=80', 'a100:4,gen=hopper'. Combined "
        "example: 'a100:4*intel+h100:1@30m'. Quote when your shell would "
        "expand '*'.",
    )

    # ----- Filtering -------------------------------------------------------
    filt = parser.add_argument_group(
        "Filtering",
        description=(
            "Narrow the allocations shown. Name filters (--cluster/--account/"
            "--qos) are case-insensitive substrings, repeatable, OR-matched. "
            "Hardware narrowing happens implicitly via the probe shape "
            "(SHAPE_LIST) — a row whose hardware can't run any probed shape "
            "is dropped."
        ),
    )
    filt.add_argument(
        "--cluster", action="append", metavar="NAME",
        help="Cluster name. Repeatable. e.g. --cluster notchpeak",
    )
    filt.add_argument(
        "--account", action="append", metavar="NAME",
        help="Account name. Repeatable. e.g. --account sadayappan",
    )
    filt.add_argument(
        "--qos", action="append", metavar="NAME",
        help="QOS name. Repeatable. e.g. --qos notchpeak-gpu",
    )
    filt.add_argument(
        "--default-only", action="store_true",
        help="Only the default QOS for each association. "
        "e.g. --default-only --quick",
    )
    fc_group = filt.add_mutually_exclusive_group()
    fc_group.add_argument(
        "--freecycle-only", dest="freecycle_only", action="store_true",
        help="Only freecycle (preemptable, no fairshare cost) rows. "
        "e.g. --freecycle-only a100:4",
    )
    fc_group.add_argument(
        "--exclude-freecycle", dest="exclude_freecycle", action="store_true",
        help="Hide freecycle rows. e.g. --exclude-freecycle a100:4",
    )
    g_group = filt.add_mutually_exclusive_group()
    g_group.add_argument(
        "--guest-only", dest="guest_only", action="store_true",
        help="Only guest (preemptable on idle owner nodes) rows. "
        "e.g. --guest-only h100:1",
    )
    g_group.add_argument(
        "--exclude-guest", dest="exclude_guest", action="store_true",
        help="Hide guest rows. e.g. --exclude-guest cpu:32",
    )
    filt.add_argument(
        "--reservation", action="store_true",
        help="Only QOS that require a reservation. "
        "e.g. --reservation --quick",
    )
    filt.add_argument(
        "--min-wall", metavar="DURATION",
        help="Minimum MaxWall. e.g. 12:00:00, 3-00:00:00, 14d, 7d, "
        "'unlimited'. Usage: --min-wall 24:00:00",
    )
    filt.add_argument(
        "--fairshare-min", type=float, metavar="FLOAT",
        help="Drop rows below this FairShare (requires sshare data). "
        "e.g. --fairshare-min 0.1",
    )
    filt.add_argument(
        "--usage-max", type=float, metavar="FLOAT",
        help="Drop rows above this RawUsage (requires sshare data). "
        "e.g. --usage-max 0.5",
    )
    filt.add_argument(
        "--all-visible", action="store_true",
        help="Search every association you can read (omits user names; "
        "may be slow; disables sshare enrichment). "
        "e.g. --all-visible --quick",
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
        "json (wide, with _help legend) when piped. "
        "e.g. --format json | jq '.rows[]'",
    )
    out.add_argument(
        "--wide", action="store_true",
        help="Show extra columns: partition, gpu_types, cpu_features, "
        "default_qos, TRES limits, QOS flags, full sshare detail. Also "
        "restores priority/fairshare/usage/default/tags when availability "
        "columns are present (otherwise hidden so the free_* columns fit). "
        "e.g. --wide --quick --format csv",
    )
    out.add_argument(
        "--pivot", action="store_true",
        help="Pivot layout: rows = (cluster, account, qos), columns = shape "
        "labels, cells = wait times. Table format only; useful with a "
        "multi-shape SHAPE_LIST. e.g. 'a100:1+a100:4' --pivot",
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
        "Default no-wait: premium,vendor,cluster,account,qos. "
        "e.g. --sort wait,premium,cluster",
    )
    out.add_argument(
        "--reverse", action="store_true",
        help="Reverse the sort order. e.g. --sort wait --reverse a100:4",
    )
    out.add_argument(
        "--sbatch", action="store_true",
        help="Emit '#SBATCH --account=... --qos=...' blocks instead of a "
        "table. With --format=json, emits a JSON array of "
        "{cluster, account, qos, partition}. e.g. --sbatch a100:4 --quick",
    )
    out.add_argument(
        "--best", action="store_true",
        help="Print only the lowest-wait runnable triple as a ready-to-paste "
        "#SBATCH block plus a one-line summary. Requires wait data (incompatible "
        "with --no-wait/--quick); also incompatible with --sbatch/--pivot. "
        "With --format=json, emits a single object. e.g. --best a100:4",
    )
    out.add_argument(
        "--no-json-help", action="store_true",
        help="In JSON output, drop the top-level _help legend and emit a "
        "bare array. No effect on table/csv. "
        "e.g. --quick --format json --no-json-help",
    )
    out.add_argument(
        "--full", action="store_true",
        help="Skip the uniform-wait row collapse: keep every walltime row "
        "even when a multi-shape SHAPE_LIST gave the same wait across them. "
        "e.g. --full 'a100:1+a100:4'",
    )
    out.add_argument(
        "--show-all", dest="show_all", action="store_true",
        help="Don't hide marginal rows: '?' waits, no-MaxWall QOS, "
        "over-MaxWall shapes, zero-free. e.g. --show-all a100:4",
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
        help="Skip the wait probe (no 'wait' column). Faster. "
        "e.g. --no-wait --format csv",
    )
    diag.add_argument(
        "--no-availability", dest="no_availability", action="store_true",
        help="Skip the live sinfo capacity query (no free_* columns). Faster. "
        "In table mode the free_* columns replace priority/fairshare/usage/"
        "default/tags by default; --wide brings them back. "
        "e.g. --no-availability cpu:32",
    )
    diag.add_argument(
        "--no-usage", action="store_true",
        help="Skip the sshare lookup (no fairshare/usage columns). Faster. "
        "e.g. --no-usage a100:4",
    )
    diag.add_argument(
        "--quick", action="store_true",
        help="Macro for --no-wait --no-availability --no-usage. Enumerate "
        "allocations fast, no probes. e.g. --quick --format csv > allocs.csv",
    )
    diag.add_argument(
        "--explain", action="store_true",
        help="Preview the probe plan and exit; runs no SLURM probes. "
        "Honors --format=json. e.g. --explain a100:4+cpu:32",
    )
    diag.add_argument(
        "-v", "--verbose", action="store_true",
        help="Narrate dropped rows + probe progress to stderr. "
        "e.g. -v a100:4",
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
            "Each exits after printing. If a SHAPE_LIST is supplied, the "
            "inventory is narrowed to partitions that satisfy it (vendor / "
            "microarch / GPU gen / SM atoms all apply)."
        ),
    )
    inv.add_argument(
        "--list-gpus", action="store_true",
        help="Cluster/partition GPU type:count inventory from sinfo. "
        "A SHAPE_LIST narrows the listing. "
        "e.g. --list-gpus, --list-gpus a100:1, --list-gpus 'a100:4*intel'",
    )
    inv.add_argument(
        "--list-cpus", action="store_true",
        help=(
            "Cluster/partition CPU inventory from sinfo: vendor, "
            "architecture, and per-node layout (cores×sockets, memory). "
            "SLURM does not expose specific CPU SKU strings on this cluster. "
            "A SHAPE_LIST narrows the listing. "
            "e.g. --list-cpus, --list-cpus 'cpu:32*genoa'"
        ),
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


def _sacctmgr_query(
    entity: str,
    fields: Sequence[str],
    where_clauses: Sequence[str] = (),
) -> List[List[str]]:
    """Run `sacctmgr show ENTITY [where ...] format=... -n -P` and return parsed rows.

    Centralizes the boilerplate shared by show_associations / show_qos so a
    single place handles tool resolution, argument shaping, and parsing.
    """
    sacctmgr = require_tool("sacctmgr")
    args = [sacctmgr, "show", entity]
    if where_clauses:
        args.append("where")
        args.extend(where_clauses)
    args.extend(["format=" + ",".join(fields), "-n", "-P"])
    return split_parsable(run_command(args), len(fields))


def show_associations(user: Optional[str], all_visible: bool) -> List[AllocationRow]:
    where: List[str] = []
    if user and not all_visible:
        where.append(f"user={user}")

    rows = []
    for fields in _sacctmgr_query("association", ASSOC_FIELDS, where):
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
    info: Dict[str, QOSInfo] = {}

    # sacctmgr accepts comma-joined name= lists; chunk to keep argv well under
    # any plausible exec line-length limit on systems with many QOSes.
    chunk_size = 80
    for index in range(0, len(unique_names), chunk_size):
        chunk = unique_names[index : index + chunk_size]
        for fields in _sacctmgr_query("qos", QOS_FIELDS, ["name=" + ",".join(chunk)]):
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
        # (arch_short, cores_per_socket, sockets, mem_gib) -> node count.
        # arch_short is "" when no feature classifies; mem_gib is mem_mb//1024.
        self.node_types: Dict[Tuple[str, int, int, int], int] = {}
        # (arch_short, cores_per_socket) -> [cpus_free, cpus_total]
        self.cpus_by_shape: Dict[Tuple[str, int], List[int]] = {}

    def add_gpu(self, gtype: str, free: int, total: int) -> None:
        slot = self.gpus.setdefault(gtype, [0, 0])
        slot[0] += free
        slot[1] += total

    def add_node_type(self, sig: Tuple[str, int, int, int]) -> None:
        self.node_types[sig] = self.node_types.get(sig, 0) + 1

    def add_cpu_shape(self, arch: str, cps: int, free: int, total: int) -> None:
        slot = self.cpus_by_shape.setdefault((arch, cps), [0, 0])
        slot[0] += free
        slot[1] += total


def _strip_partition_marker(name: str) -> str:
    """Sinfo marks a cluster's default partition with a trailing '*'."""
    return name[:-1] if name.endswith("*") else name


def _node_arch_short(features_blob: str) -> str:
    """Resolve a node's feature blob to a canonical short arch token, or "".

    Tokenizes lowercased comma-separated features and returns the first one
    that classifies via _canon_cpu_arch. Used to bucket per-node layout
    signatures even on mixed-vendor partitions.
    """
    if not features_blob or features_blob == "(null)":
        return ""
    for tok in features_blob.lower().split(","):
        canon = _canon_cpu_arch(tok.strip())
        if canon:
            return canon
    return ""


def show_partition_availability() -> Dict[str, Dict[str, PartitionAvail]]:
    """Return {cluster: {partition: PartitionAvail}} from a single per-node sinfo.

    Counts nodes_total/cpus_total/gpus_total from configured capacity (every
    listed node), but only credits a node's idle CPUs/GPUs as 'free' when the
    node state is idle or mix (and not '*'/non-responding). Also accumulates
    per-node layout signatures (arch, cores_per_socket, sockets, mem_gib) into
    bucket.node_types so --list-cpus can surface specific node types per
    partition.
    """
    sinfo = require_tool("sinfo")
    args = [
        sinfo,
        "--clusters=all",
        "-h",
        "-N",
        "-O",
        ("Cluster:|,NodeHost:|,Partition:|,StateCompact:|,CPUsState:|,"
         "Gres:1024|,GresUsed:1024|,Cores:|,Sockets:|,Memory:|,"
         "Features:1024"),
    ]
    result: Dict[str, Dict[str, PartitionAvail]] = {}
    try:
        output = run_command(args)
    except CommandError:
        return result
    for line in output.splitlines():
        if not line.strip():
            continue
        # Gres/GresUsed/Features are 1024-wide so the line is fixed-width;
        # split into 11 pipe-delimited fields.
        fields = line.split("|")
        if len(fields) < 11:
            continue
        cluster = fields[0].strip()
        node = fields[1].strip()
        partition = _strip_partition_marker(fields[2].strip())
        state = fields[3].strip()
        cpus_state = fields[4].strip()
        gres_total = fields[5].strip()
        gres_used = fields[6].strip()
        cores_per_socket_s = fields[7].strip()
        sockets_s = fields[8].strip()
        memory_s = fields[9].strip()
        features_blob = fields[10].strip()
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

        try:
            cps = int(cores_per_socket_s)
            sockets = int(sockets_s)
            mem_mb = int(memory_s)
        except ValueError:
            continue
        arch_short = _node_arch_short(features_blob)
        bucket.add_node_type((arch_short, cps, sockets, mem_mb // 1024))
        bucket.add_cpu_shape(
            arch_short,
            cps,
            cpus_idle if free_node else 0,
            cpus_total,
        )
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


# ════════════════════════════════════════════════════════════════════
# Shape grammar — HardwareFilter
# ════════════════════════════════════════════════════════════════════


class HardwareFilter:
    """Bundle of CPU/GPU constraint atoms applied to an AllocationRow.

    Stored once on `ProbeShape.filter`. Empty by default — the no-op filter
    accepts every row. The data fields and the predicate methods that consume
    them live together so adding a new constraint atom touches one place.

    Plain class (not @dataclass) for Python 3.6 compatibility on CHPC.
    """

    __slots__ = (
        "cpu_vendor", "cpu_archs",
        "gpu_gen", "gpu_sm", "gpu_gen_min", "gpu_sm_min",
    )

    def __init__(
        self,
        cpu_vendor: Optional[str] = None,
        cpu_archs: Tuple[str, ...] = (),
        gpu_gen: Optional[str] = None,
        gpu_sm: Optional[int] = None,
        gpu_gen_min: Optional[str] = None,
        gpu_sm_min: Optional[int] = None,
    ) -> None:
        self.cpu_vendor = cpu_vendor.lower() if cpu_vendor else None
        self.cpu_archs = tuple(a.lower() for a in cpu_archs)
        self.gpu_gen = gpu_gen.lower() if gpu_gen else None
        self.gpu_sm = gpu_sm
        self.gpu_gen_min = gpu_gen_min.lower() if gpu_gen_min else None
        self.gpu_sm_min = gpu_sm_min

    def __repr__(self) -> str:
        # Hide fields at their constructor defaults: None for the scalar fields
        # and () for cpu_archs. Add new sentinels here if a field's default
        # changes (e.g., a future int field defaulting to 0).
        fields = ", ".join(
            f"{name}={getattr(self, name)!r}" for name in self.__slots__
            if getattr(self, name) not in (None, ())
        )
        return f"HardwareFilter({fields})" if fields else "HardwareFilter()"

    def has_cpu_constraint(self) -> bool:
        return self.cpu_vendor is not None or bool(self.cpu_archs)

    def has_gpu_constraint(self) -> bool:
        return (
            self.gpu_gen is not None
            or self.gpu_sm is not None
            or self.gpu_gen_min is not None
            or self.gpu_sm_min is not None
        )

    def has_any(self) -> bool:
        return self.has_cpu_constraint() or self.has_gpu_constraint()

    def cpu_constraint_expr(self) -> Optional[str]:
        """SLURM `--constraint` expression for CPU atoms, or None.

        arch wins over vendor (a specific arch already implies its vendor).
        Multiple archs AND with `&`; vendor expands to an OR over the
        vendor's feature table.
        """
        if self.cpu_archs:
            return "&".join(self.cpu_archs) if len(self.cpu_archs) > 1 else self.cpu_archs[0]
        if self.cpu_vendor:
            return VENDOR_CONSTRAINT_EXPR.get(self.cpu_vendor)
        return None

    def cpu_satisfies(self, features) -> bool:
        """True iff `features` satisfy every set CPU constraint.

        Empty `features` (metadata not loaded) returns True so probes still
        run on rows whose features sinfo didn't expose — same convention
        used elsewhere for missing metadata.
        """
        if not features:
            return True
        if self.cpu_vendor and not _features_match_vendor(features, self.cpu_vendor):
            return False
        for arch in self.cpu_archs:
            if not any(arch in f.lower() for f in features):
                return False
        return True

    def gpu_satisfies(self, token: str) -> bool:
        """True iff `token` satisfies every set GPU constraint."""
        return _gpu_token_satisfies(
            token,
            gen=self.gpu_gen, sm=self.gpu_sm,
            gen_min=self.gpu_gen_min, sm_min=self.gpu_sm_min,
        )

    def label_markers(self) -> List[str]:
        """Ordered marker strings appended to ProbeShape labels.

        Order: arch tokens, then vendor (only when no arch — arch implies
        vendor), then gen / gen_min (with `+` suffix), then sm / sm_min.
        """
        markers: List[str] = []
        if self.cpu_archs:
            markers.extend(self.cpu_archs)
        elif self.cpu_vendor:
            markers.append(self.cpu_vendor)
        if self.gpu_gen:
            markers.append(self.gpu_gen)
        elif self.gpu_gen_min:
            markers.append(f"{self.gpu_gen_min}+")
        if self.gpu_sm is not None:
            markers.append(f"sm{self.gpu_sm}")
        elif self.gpu_sm_min is not None:
            markers.append(f"sm{self.gpu_sm_min}+")
        return markers


EMPTY_FILTER = HardwareFilter()


# ════════════════════════════════════════════════════════════════════
# Shape grammar — ProbeShape
# ════════════════════════════════════════════════════════════════════


class ProbeShape:
    """Shape of the hypothetical job used for `sbatch --test-only` wait probing.

    Defaults: 1 node, 1 CPU, 1-hour wall, `--gres=gpu:1` on GPU rows, no
    GRES on CPU rows. parse_shape_spec() builds these from a user-supplied
    SHAPE_LIST so the predicted wait reflects the actual job they intend
    to run.
    """

    def __init__(
        self,
        nodes: int = DEFAULT_PROBE_NODES,
        cpus: int = DEFAULT_PROBE_CPUS,
        mem: Optional[str] = None,
        gpu_type: Optional[str] = None,
        gpu_count: Optional[int] = None,
        time: str = DEFAULT_PROBE_TIME,
        filter: HardwareFilter = EMPTY_FILTER,
    ) -> None:
        self.nodes = nodes
        self.cpus = cpus
        self.mem = mem
        self.gpu_type = gpu_type.lower() if gpu_type else None
        self.gpu_count = gpu_count
        self.time = time
        self.filter = filter
        self.label = self._compute_label()

    def _compute_label(self, time_label: Optional[str] = None) -> str:
        wall = time_label if time_label is not None else _format_wall_short(self.time)
        if self.gpu_type or self.gpu_count is not None or self.filter.has_gpu_constraint():
            gtype = self.gpu_type or "gpu"
            count = self.gpu_count if self.gpu_count is not None else 1
            core = f"{gtype}:{count}@{wall}"
        else:
            core = f"cpu:{self.cpus}@{wall}"
        parts = [core]
        if self.mem:
            parts.append(self.mem)
        parts.extend(self.filter.label_markers())
        label = ",".join(parts)
        if self.nodes > 1:
            label = f"{self.nodes}n*{label}"
        return label

    def _candidate_tokens(self, row: "AllocationRow") -> Tuple[str, ...]:
        """Row gpu_types tokens that satisfy gpu_type AND gen/SM constraints.

        Empty when (a) the row has no gpu_types metadata, or (b) no token
        satisfies the combined predicate. `should_skip` and `resolved_gpu_type`
        share this so `a100:4*hopper` correctly yields zero candidates on a
        heterogeneous row that contains both `a100` and `h100`.
        """
        if not row.gpu_types:
            return ()
        return tuple(t for t in row.gpu_types if self.accepts_gpu_token(t))

    def resolved_gpu_type(self, row: "AllocationRow") -> Optional[str]:
        """Return the row-specific GRES name for this shape, or None.

        Priority:
          1. self.gpu_type set, no gen/SM: shortest substring match (legacy).
          2. gpu_type and/or gen/SM: shortest token from `_candidate_tokens`.
          3. Neither: None (caller emits bare gpu:N).

        When `row.gpu_types` is empty (metadata not loaded) and only gpu_type
        is set, fall back to the literal — preserves legacy probe behavior.
        """
        gen_sm = self.filter.has_gpu_constraint()
        if not (self.gpu_type or gen_sm):
            return None
        if not row.gpu_types:
            return self.gpu_type
        cands = self._candidate_tokens(row)
        if cands:
            return min(cands, key=lambda s: (len(s), s))
        # Legacy: gpu_type-only with no substring match falls back to literal
        # so `--gres=gpu:<literal>:N` reproduces pre-classifier probe behavior.
        if self.gpu_type and not gen_sm:
            return _shortest_matching_gpu(set(row.gpu_types), self.gpu_type) or self.gpu_type
        return None

    def gres_for(self, row: "AllocationRow") -> Optional[str]:
        """Return the --gres value for this row, or None to omit the flag."""
        if "gpu" not in row.tags:
            return None
        count = self.gpu_count if self.gpu_count is not None else 1
        gtype = self.resolved_gpu_type(row)
        if gtype:
            return f"gpu:{gtype}:{count}"
        return f"gpu:{count}"

    def to_sbatch_args(self, row: "AllocationRow") -> List[str]:
        args = ["-N", str(self.nodes), "-n", str(self.cpus), "-t", _to_sbatch_wall(self.time)]
        if self.mem:
            args.append(f"--mem={self.mem}")
        gres = self.gres_for(row)
        if gres:
            args.append(f"--gres={gres}")
        constraint = self.filter.cpu_constraint_expr()
        if constraint:
            args.append(f"--constraint={constraint}")
        return args

    def should_skip(self, row: "AllocationRow") -> bool:
        """True when this shape can't possibly run on this row (skip the probe)."""
        gpu_constraint = self.filter.has_gpu_constraint()
        if self.requires_gpu() and "gpu" not in row.tags:
            return True
        # Empty row.gpu_types means metadata wasn't loaded — don't skip.
        if row.gpu_types and (self.gpu_type or gpu_constraint):
            if not self._candidate_tokens(row):
                return True
        if not self.filter.cpu_satisfies(row.cpu_features):
            return True
        return False

    def requires_gpu(self) -> bool:
        """True when this shape's hardware constraints can only be served by a GPU."""
        return (
            self.gpu_type is not None
            or self.gpu_count is not None
            or self.filter.has_gpu_constraint()
        )

    def accepts_gpu_token(self, token: str) -> bool:
        """True iff `token` satisfies the shape's gpu_type substring (if set)
        and the HardwareFilter's gen/sm constraint (if set)."""
        if self.gpu_type and self.gpu_type not in token.lower():
            return False
        if self.filter.has_gpu_constraint() and not self.filter.gpu_satisfies(token):
            return False
        return True


def _filtered_gpu_items(
    bucket: "PartitionAvail", shape: "ProbeShape",
) -> List[Tuple[str, Tuple[int, int]]]:
    """Bucket's GPU entries restricted to types `shape` accepts.

    Shape with no GPU constraint at all → every entry passes through.
    """
    if not shape.gpu_type and not shape.filter.has_gpu_constraint():
        return [(g, (free, total)) for g, (free, total) in bucket.gpus.items()]
    return [
        (g, (free, total))
        for g, (free, total) in bucket.gpus.items()
        if shape.accepts_gpu_token(g)
    ]


def _bucket_matches_shape(
    bucket: "PartitionAvail", features: Set[str], shape: "ProbeShape",
) -> bool:
    """True iff `bucket` and `features` jointly satisfy `shape`.

    - Shape's CPU filter must accept `features` (empty features pass,
      matching cpu_satisfies' missing-metadata convention).
    - Shape requires GPU → at least one GPU type in the bucket must be
      accepted; a CPU-only bucket fails for any GPU-requiring shape.
    """
    if not shape.filter.cpu_satisfies(features):
        return False
    if shape.requires_gpu():
        if not bucket.gpus:
            return False
        if not any(shape.accepts_gpu_token(g) for g in bucket.gpus):
            return False
    return True


# ════════════════════════════════════════════════════════════════════
# Shape grammar — parsers
# ════════════════════════════════════════════════════════════════════


def _parse_positive_int(text: str, error: str) -> int:
    if not text or not text.isdigit() or int(text) <= 0:
        raise CommandError(error)
    return int(text)


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
    return _spec_error("shape spec", spec, problem, expected, _SHAPE_HINT)


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


def _parse_prefix_count(tok: str, prefix: str, spec: str, hint: str) -> int:
    """Validate a `prefix:N` shorthand (e.g. 'cpu:32', 'gpu:4') and return N."""
    count_text = tok[len(prefix):].strip()
    if not count_text or not count_text.isdigit() or int(count_text) <= 0:
        raise _shape_error(
            spec,
            f"{prefix!r} shorthand needs a positive integer count, got {count_text!r}",
            hint,
        )
    return int(count_text)


# All known keys for `key=value` shape tokens. Used both by `_apply_kv_token`
# (to dispatch) and by its unknown-key suggestion via difflib.get_close_matches.
_KV_TOKEN_KEYS = (
    "cores", "mem", "nodes", "time", "gpus", "vendor", "arch",
    "gen", "sm", "gen_min", "sm_min",
)


# `gen=`/`gen_min=`/`sm=`/`sm_min=` share a common parse-and-store shape;
# this table parametrizes the four otherwise-near-duplicate handlers.
_GEN_SM_KV_KEYS = {
    "gen":     ("gpu_gen",     _canon_gpu_gen, _GEN_HINT, "generation"),
    "gen_min": ("gpu_gen_min", _canon_gpu_gen, _GEN_HINT, "generation"),
    "sm":      ("gpu_sm",      _parse_sm_int,  _SM_HINT,  "SM"),
    "sm_min":  ("gpu_sm_min",  _parse_sm_int,  _SM_HINT,  "SM"),
}

_AT_HINT = "<shape>@<duration>, e.g. 'a100:1@30m', 'cpu:32@12h'"


def _parse_at_suffix(low: str, tok: str, spec: str) -> Tuple[str, Optional[str]]:
    """Strip a trailing `@<DUR>` from a positional token; return (head, dur_or_None)."""
    if "@" not in low:
        return low, None
    head, _, dur = low.partition("@")
    head = head.strip()
    dur = dur.strip()
    if not head:
        raise _shape_error(spec, f"empty shape before '@' in {tok!r}", _AT_HINT)
    if not dur:
        raise _shape_error(spec, f"empty duration after '@' in {tok!r}", _AT_HINT)
    if parse_wall_seconds(dur) is None:
        raise _shape_error(
            spec,
            f"duration {dur!r} after '@' is not a recognized walltime",
            "HH:MM:SS, D-HH:MM:SS, Nd, or compact 'Nh'/'Nm' (e.g. 24h, 3d, 30m)",
        )
    return head, dur


def _apply_kv_token(key: str, val: str, state: dict, spec: str) -> None:
    """Validate & store one comma-separated `key=value` token into state."""
    if not val:
        raise _shape_error(
            spec,
            f"empty value for {key!r}",
            f"{key}=VALUE (e.g. {key}=8 for an integer, {key}=24h for a duration)",
        )
    if key == "cores":
        if not val.isdigit() or int(val) <= 0:
            raise _shape_error(
                spec,
                f"cores value {val!r} is not a positive integer",
                "cores=N where N > 0 (e.g. cores=8, cores=32)",
            )
        state["cpus"] = int(val)
    elif key == "mem":
        if not _MEM_RE.match(val):
            raise _shape_error(
                spec, f"mem value {val!r} has no unit",
                "integer + unit, e.g. 16G, 32G, 128M",
            )
        state["mem"] = val
    elif key == "nodes":
        if not val.isdigit() or int(val) <= 0:
            raise _shape_error(
                spec, f"nodes value {val!r} is not a positive integer",
                "nodes=N where N > 0 (e.g. nodes=2)",
            )
        state["nodes"] = int(val)
    elif key == "time":
        if parse_wall_seconds(val) is None:
            raise _shape_error(
                spec, f"time value {val!r} is not a recognized duration",
                "HH:MM:SS, D-HH:MM:SS, Nd, or compact 'Nh'/'Nm' (e.g. 24h, 3d, 4:00:00)",
            )
        state["time"] = val
    elif key == "gpus":
        state["gpu_type"], state["gpu_count"] = parse_gpu_spec(val)
    elif key == "vendor":
        v = val.lower()
        if v not in _VENDORS:
            raise _shape_error(
                spec, f"vendor value {val!r} is not recognized", _VENDOR_HINT,
            )
        state["cpu_vendor"] = v
    elif key == "arch":
        canon = _canon_cpu_arch(val)
        if canon is None:
            raise _shape_error(
                spec, f"arch value {val!r} is not recognized", _ARCH_HINT,
            )
        if canon not in state["cpu_archs"]:
            state["cpu_archs"].append(canon)
    elif key in _GEN_SM_KV_KEYS:
        state_key, parser, hint, label = _GEN_SM_KV_KEYS[key]
        parsed = parser(val)
        if parsed is None:
            raise _shape_error(
                spec, f"{key} value {val!r} is not a recognized {label}", hint,
            )
        state[state_key] = parsed
    else:
        problem = f"unknown key {key!r}"
        suggestions = difflib.get_close_matches(key, _KV_TOKEN_KEYS, n=2, cutoff=0.6)
        if suggestions:
            problem += f" (did you mean {' or '.join(repr(s) for s in suggestions)}?)"
        raise _shape_error(
            spec,
            problem,
            "one of cores=, mem=, time=, gpus=, nodes=, vendor=, arch=, "
            "gen=, sm=, gen_min=, sm_min=",
        )


def _apply_positional_token(low: str, state: dict, spec: str) -> None:
    """Apply one positional shape token (cpu:/gpu:/digits/vendor/arch/gen/sm/type)."""
    if low.startswith("cpu:"):
        state["cpus"] = _parse_prefix_count(low, "cpu:", spec, "cpu:N where N > 0 (e.g. cpu:32)")
        return
    if low.startswith("gpu:"):
        state["gpu_type"] = None
        state["gpu_count"] = _parse_prefix_count(
            low, "gpu:", spec,
            "gpu:N where N > 0 (e.g. gpu:4); use <type>:N to pin a GPU type",
        )
        return
    if low.isdigit():
        if int(low) <= 0:
            raise _shape_error(
                spec, f"bare integer {low!r} must be > 0", "N > 0 (treated as cores=N)",
            )
        state["cpus"] = int(low)
        return
    if low in _VENDORS:
        state["cpu_vendor"] = low
        return
    canon = _canon_cpu_arch(low)
    if canon is not None:
        if canon not in state["cpu_archs"]:
            state["cpu_archs"].append(canon)
        return
    gen_canon = _canon_gpu_gen(low)
    if gen_canon is not None:
        state["gpu_gen"] = gen_canon
        return
    sm_val = _parse_sm_token(low)
    if sm_val is not None:
        state["gpu_sm"] = sm_val
        return
    state["gpu_type"], state["gpu_count"] = parse_gpu_spec(low)


# Keys partitioned for ProbeShape / HardwareFilter at construction time.
_PROBESHAPE_STATE_KEYS = ("nodes", "cpus", "mem", "gpu_type", "gpu_count", "time")
_FILTER_STATE_KEYS = (
    "cpu_vendor", "cpu_archs",
    "gpu_gen", "gpu_sm", "gpu_gen_min", "gpu_sm_min",
)


def parse_shape_spec(spec: str) -> ProbeShape:
    """Parse a single shape SPEC into a ProbeShape.

    Tokens (comma-separated, any order):
      cores=N | mem=SIZE | time=DUR | gpus=SPEC | nodes=N
      vendor=intel|amd | arch=<microarch>
      gen=<NV-gen> | sm=N | gen_min=<NV-gen> | sm_min=N
    Positional shorthands (first one wins for that slot):
      cpu:N        -> cores=N (CPU shape, no GPU)
      gpu:N        -> any GPU type, count N
      <type>:N     -> gpus=<type>:N
      <type>       -> gpus=<type> (count 1)
      N (digits)   -> cores=N
      intel|amd    -> vendor filter
      <microarch>  -> arch filter (skl, genoa, rome, zen4, ...)
      <NV-gen>     -> GPU gen filter (ampere, hopper, ada, ...)
      sm<NN>       -> exact SM compute capability (sm80, sm_80, ...)
    Walltime suffix on any positional shorthand:
      <shape>@<DUR> -> shape + time=DUR (e.g. 'a100:1@30m', 'cpu:32@12h')

    Examples:
      'a100:4'                     -> 1 a100, 1 core, 1-min wall
      'a100:1@30m'                 -> 1 a100, 30-minute wall
      'a100:4,mem=32G,time=24h'    -> 4 a100, 32G mem, 24-hour wall
      'cpu:32,mem=128G,time=12h'   -> 32 cores (CPU job), 128G, 12h
      'cores=8,mem=16G,gpus=h100nvl:1,time=4h'
      'a100:4,vendor=intel'        -> 4 a100 on Intel hosts
      'cpu:32,arch=genoa'          -> 32 cores on Genoa nodes
      'gpu:4,gen=ampere'           -> 4 Ampere-gen GPUs (any model)
      'gpu:1,sm_min=80'            -> 1 GPU with compute capability >= 8.0
      'gpu:1,gen_min=ampere'       -> 1 GPU, Ampere-or-newer
    """
    s = (spec or "").strip()
    if not s:
        raise _shape_error(
            spec, "empty SPEC",
            "comma-separated tokens, e.g. 'a100:4,mem=32G,time=24h' or 'cpu:32,time=12h'",
        )
    # Keys must be the union of _PROBESHAPE_STATE_KEYS and _FILTER_STATE_KEYS;
    # `_apply_kv_token` and `_apply_positional_token` write here, then the
    # construction below partitions the dict for ProbeShape vs HardwareFilter.
    state: Dict[str, object] = {
        "nodes": DEFAULT_PROBE_NODES,
        "cpus": DEFAULT_PROBE_CPUS,
        "mem": None,
        "time": DEFAULT_PROBE_TIME,
        "gpu_type": None,
        "gpu_count": None,
        "cpu_vendor": None,
        "cpu_archs": [],
        "gpu_gen": None,
        "gpu_sm": None,
        "gpu_gen_min": None,
        "gpu_sm_min": None,
    }
    for raw in s.split(","):
        tok = raw.strip()
        if not tok:
            continue
        if "=" in tok:
            key, _, val = tok.partition("=")
            _apply_kv_token(key.strip().lower(), val.strip(), state, spec)
            continue
        low = tok.lower()
        head, dur = _parse_at_suffix(low, tok, spec)
        if dur is not None:
            state["time"] = dur
        _apply_positional_token(head, state, spec)

    shape_args = {k: state[k] for k in _PROBESHAPE_STATE_KEYS}
    filter_args = {k: state[k] for k in _FILTER_STATE_KEYS}
    filter_args["cpu_archs"] = tuple(filter_args["cpu_archs"])
    return ProbeShape(filter=HardwareFilter(**filter_args), **shape_args)


def parse_shape_list(spec: str) -> List[ProbeShape]:
    """Parse a SHAPE_LIST: '+' joins alternatives, '*' combines into one job.

    Top-level '+' separates independent probes (OR). Inside each group, '*'
    merges pieces into a single shape (AND): the AND-joined pieces are
    comma-concatenated and handed to parse_shape_spec, so later tokens
    overwrite earlier same-field values (last-wins, matching how duplicate
    keys behave inside one comma-token shape).
    """
    s = (spec or "").strip()
    _LIST_HINT = (
        "shapes joined with '+' (alternatives) and '*' (combine), "
        "e.g. 'a100:4', 'a100:4*cpu:32', 'a100:4*cpu:32+h100:1'"
    )
    if not s:
        raise _shape_error(spec, "empty SHAPE_LIST", _LIST_HINT)
    shapes: List[ProbeShape] = []
    for or_raw in s.split("+"):
        or_piece = or_raw.strip()
        if not or_piece:
            raise _shape_error(
                spec, "empty piece between '+' separators", _LIST_HINT,
            )
        and_pieces = [p.strip() for p in or_piece.split("*")]
        if any(not p for p in and_pieces):
            raise _shape_error(
                spec, "empty piece between '*' separators", _LIST_HINT,
            )
        merged = ",".join(and_pieces)
        shapes.append(parse_shape_spec(merged))
    return shapes


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
            # Both sides are naive local datetimes: SLURM emits the predicted
            # start in the cluster's local timezone (no offset in the string,
            # parsed as naive by parse_test_only_stderr) and `datetime.now()`
            # returns naive local. Don't "fix" this into a UTC conversion —
            # that would break the math on a single-TZ cluster like CHPC.
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
    interactive runs of a wide multi-shape SHAPE_LIST get a heartbeat without
    spamming logs from scripted invocations.
    """
    if not rows or shutil.which("sbatch") is None:
        return
    if not shapes:
        shapes = [ProbeShape()]
    probe_pairs = [
        (row, shape)
        for row in rows
        for shape in shapes
        if not shape.should_skip(row)
    ]
    pair_count = len(probe_pairs)
    if pair_count == 0:
        return
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
        for row, shape in probe_pairs:
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
    """Return partition names to try for a given row, most-specific first.

    `sacctmgr show association` doesn't always pin a partition (Partition is
    blank for many account/qos combinations on CHPC), and even when it does,
    the matching partition name is sometimes the QOS name with a suffix
    stripped (e.g. QOS `granite-gpu-freecycle` runs on partition `granite-gpu`).
    Probes try each candidate in order and stop at the first one SLURM accepts.
    """
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


def _render_simple_table(headers: Sequence[str], rows: Sequence[Sequence[str]]) -> str:
    """Render a left-justified text table: HEADERS, dashed rule, then rows."""
    cols = len(headers)
    widths = [len(h) for h in headers]
    for row in rows:
        for i in range(cols):
            cell = row[i] if i < len(row) else ""
            if len(cell) > widths[i]:
                widths[i] = len(cell)
    header_line = "  ".join(h.ljust(widths[i]) for i, h in enumerate(headers))
    rule_line = "  ".join("-" * widths[i] for i in range(cols))
    out = [header_line, rule_line]
    for row in rows:
        out.append(
            "  ".join(
                (row[i] if i < len(row) else "").ljust(widths[i])
                for i in range(cols)
            )
        )
    return "\n".join(out)


def format_gpu_summary(
    partition_avail: Dict[str, Dict[str, PartitionAvail]],
    partition_features: Optional[Dict[str, Dict[str, Set[str]]]] = None,
    shapes: Optional[Sequence["ProbeShape"]] = None,
) -> str:
    """Render GPU inventory as a table with one row per (cluster, partition, gtype).

    Annotates each GRES token with vendor, NVIDIA generation, and SM compute
    capability via _classify_gpu_token. Unrecognized tokens still render —
    GENERATION/SM cells are blank rather than absent.

    When `shapes` is given, only (cluster, partition, gtype) rows accepted
    by some shape's HardwareFilter are emitted: the partition's CPU
    features must satisfy the shape's CPU constraint, and the gtype must
    satisfy the shape's GPU constraint. `partition_features` supplies the
    CPU side; without it, CPU constraints are treated as missing-metadata
    (pass) — same convention as `cpu_satisfies`.
    """
    feat_map = partition_features or {}
    rows: List[List[str]] = []
    for cluster in sorted(partition_avail):
        for partition in sorted(partition_avail[cluster]):
            bucket = partition_avail[cluster][partition]
            if not bucket.gpus:
                continue
            features = feat_map.get(cluster, {}).get(partition, set())
            cpu_ok_shapes = (
                [s for s in shapes if s.filter.cpu_satisfies(features)]
                if shapes else None
            )
            if cpu_ok_shapes is not None and not cpu_ok_shapes:
                continue
            nodes_ft = f"{bucket.nodes_free}/{bucket.nodes_total}"
            cpus_ft = f"{bucket.cpus_free}/{bucket.cpus_total}"
            for gtype, (free, total) in sorted(bucket.gpus.items()):
                if cpu_ok_shapes is not None and not any(
                    s.accepts_gpu_token(gtype) for s in cpu_ok_shapes
                ):
                    continue
                cls = _classify_gpu_token(gtype)
                if cls is None:
                    vendor, gen, sm_cell = "", "", ""
                else:
                    gen, sm = cls
                    vendor = "nvidia"
                    sm_cell = f"sm_{sm}"
                rows.append([
                    cluster, partition, gtype, vendor, gen, sm_cell,
                    f"{free}/{total}", nodes_ft, cpus_ft,
                ])
    if not rows:
        if shapes:
            return "(no GPU resources match shape)"
        return "(no GPU partitions found)"
    return _render_simple_table(
        ["CLUSTER", "PARTITION", "GTYPE", "VENDOR", "GENERATION", "SM",
         "FREE/TOTAL", "NODES_F/T", "CPUS_F/T"],
        rows,
    )


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


_VENDOR_DISPLAY = {"intel": "Intel", "amd": "AMD", "mixed": "mixed"}

# Cap on the number of distinct node-type signatures rendered per partition
# in --list-cpus. Guest partitions can have 30+ unique configs; uncapped
# they blow out the column width past usable terminal sizes.
_NODE_TYPE_TOP_N = 3


def _format_mem_gib(mem_gib: int) -> str:
    """Render a node's memory tier compactly: '746G' or '1.5T'."""
    if mem_gib < 1024:
        return f"{mem_gib}G"
    tib = mem_gib / 1024
    return f"{tib:.1f}T"


def _format_node_type(sig: Tuple[str, int, int, int], count: int) -> str:
    """Render a (arch, cores_per_socket, sockets, mem_gib) signature with count."""
    arch, cores, sockets, mem_gib = sig
    arch_long = CPU_ARCH_LONG.get(arch, arch) if arch else "?"
    return f"{arch_long} {cores}c×{sockets} {_format_mem_gib(mem_gib)} ×{count}"


def _arch_display_list(feats: Iterable[str]) -> str:
    """Return a comma-joined list of long-form architecture names for FEATS.

    Each feature is canonicalized via _canon_cpu_arch, then mapped to its
    long-form display name via CPU_ARCH_LONG. Unknown short tokens fall
    through unchanged so a future arch addition is still visible.
    """
    seen: Dict[str, None] = {}
    for feat in feats or ():
        canon = _canon_cpu_arch(feat)
        if not canon:
            continue
        seen[CPU_ARCH_LONG.get(canon, canon)] = None
    return ", ".join(sorted(seen))


def format_cpu_summary(
    partition_features: Dict[str, Dict[str, Set[str]]],
    partition_avail: Optional[Dict[str, Dict[str, PartitionAvail]]] = None,
    shapes: Optional[Sequence["ProbeShape"]] = None,
) -> str:
    """Render CPU-only partitions as a table.

    GPU partitions (those whose PartitionAvail.gpus is non-empty) are filtered
    out so the listing complements --list-gpus. Architecture names are
    long-form (e.g. "Cascade Lake", "Genoa") via CPU_ARCH_LONG.

    With partition_avail: emits NODE_TYPE (per-partition node-layout
    signatures) and availability columns; ARCHITECTURE is omitted because
    each NODE_TYPE entry already carries its arch.

    Without partition_avail: emits an ARCHITECTURE column and no filtering.
    """
    if not partition_features:
        return "(no partition features found)"
    rows: List[List[str]] = []
    show_avail = partition_avail is not None
    for cluster in sorted(partition_features):
        for partition in sorted(partition_features[cluster]):
            feats = partition_features[cluster][partition]
            avail_bucket = (
                partition_avail.get(cluster, {}).get(partition)
                if partition_avail is not None
                else None
            )
            if avail_bucket is not None and avail_bucket.gpus:
                continue
            if shapes and not any(
                not s.requires_gpu() and s.filter.cpu_satisfies(feats)
                for s in shapes
            ):
                continue
            vendor_short = classify_cpu_vendor(feats)
            vendor = _VENDOR_DISPLAY.get(vendor_short, "")
            row = [cluster, partition, vendor]
            if show_avail:
                node_types = avail_bucket.node_types if avail_bucket else {}
                if node_types:
                    sorted_sigs = sorted(
                        node_types.items(), key=lambda kv: (-kv[1], kv[0])
                    )
                    head = sorted_sigs[:_NODE_TYPE_TOP_N]
                    rendered = "; ".join(_format_node_type(s, c) for s, c in head)
                    if len(sorted_sigs) > _NODE_TYPE_TOP_N:
                        rendered += f"; +{len(sorted_sigs) - _NODE_TYPE_TOP_N} more"
                    row.append(rendered)
                else:
                    row.append("")
                if avail_bucket is None:
                    row.extend(["", ""])
                else:
                    row.append(f"{avail_bucket.nodes_free}/{avail_bucket.nodes_total}")
                    row.append(f"{avail_bucket.cpus_free}/{avail_bucket.cpus_total}")
            else:
                row.append(_arch_display_list(feats))
            rows.append(row)
    if not rows:
        if shapes:
            return "(no CPU partitions match shape)"
        return "(no CPU-only partitions found)"
    headers = ["CLUSTER", "PARTITION", "VENDOR"]
    if show_avail:
        headers += ["NODE_TYPE", "NODES_F/T", "CPUS_F/T"]
    else:
        headers.append("ARCHITECTURE")
    return _render_simple_table(headers, rows)


def attach_metadata(
    rows: List[AllocationRow],
    include_usage: bool,
    user: str,
    partition_gpus: Optional[Dict[str, Dict[str, Dict[str, int]]]] = None,
    partition_features: Optional[Dict[str, Dict[str, Set[str]]]] = None,
    partition_avail: Optional[Dict[str, Dict[str, PartitionAvail]]] = None,
    shapes: Optional[Sequence["ProbeShape"]] = None,
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
            attach_row_availability(
                row, partition_avail, partition_features, shapes,
            )


def attach_row_availability(
    row: AllocationRow,
    partition_avail: Dict[str, Dict[str, PartitionAvail]],
    partition_features: Optional[Dict[str, Dict[str, Set[str]]]] = None,
    shapes: Optional[Sequence["ProbeShape"]] = None,
) -> None:
    """Roll up live availability across this row's candidate partitions.

    When `shapes` is given, only buckets accepted by some shape's
    HardwareFilter contribute. GPU entries within a bucket are further
    restricted to types satisfying that shape's GPU constraint, unioned
    across all accepting shapes.
    """
    per_cluster = partition_avail.get(row.cluster, {})
    feat_per_cluster = (partition_features or {}).get(row.cluster, {})
    nodes_free = nodes_total = 0
    cpus_free = cpus_total = 0
    cpu_shapes: Dict[Tuple[str, int], List[int]] = {}
    gpus: Dict[str, List[int]] = {}
    seen_partitions: Set[str] = set()
    matched = False
    for cand in _candidate_partitions(row):
        bucket = per_cluster.get(cand)
        if bucket is None or cand in seen_partitions:
            continue
        seen_partitions.add(cand)
        features = feat_per_cluster.get(cand, set())
        if shapes:
            accepting = [s for s in shapes if _bucket_matches_shape(bucket, features, s)]
            if not accepting:
                continue
            allowed: Dict[str, Tuple[int, int]] = {}
            for s in accepting:
                for gtype, ft in _filtered_gpu_items(bucket, s):
                    allowed[gtype] = ft
            allowed_gpus = allowed.items()
        else:
            allowed_gpus = bucket.gpus.items()
        matched = True
        nodes_free += bucket.nodes_free
        nodes_total += bucket.nodes_total
        cpus_free += bucket.cpus_free
        cpus_total += bucket.cpus_total
        for shape_key, (sfree, stotal) in bucket.cpus_by_shape.items():
            slot = cpu_shapes.setdefault(shape_key, [0, 0])
            slot[0] += sfree
            slot[1] += stotal
        for gtype, (free, total) in allowed_gpus:
            slot = gpus.setdefault(gtype, [0, 0])
            slot[0] += free
            slot[1] += total
    if not matched:
        return
    row.free_nodes = f"{nodes_free}/{nodes_total}"
    if cpu_shapes:
        ordered = sorted(
            cpu_shapes.items(),
            key=lambda kv: (-kv[1][1], kv[0][0] or "~", kv[0][1]),
        )
        row.free_cpus = ", ".join(
            _format_cpu_shape_token(arch, cps, free, total)
            for (arch, cps), (free, total) in ordered
        )
    else:
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


def _iter_glob_matches(
    values: Iterable[str], patterns: Iterable[str]
) -> Iterator[str]:
    """Yield each value (in input order) matching any pattern; case-insensitive."""
    globs = [_to_glob(p) for p in patterns]
    if not globs:
        return
    for value in values:
        v = value.lower()
        if any(fnmatch.fnmatchcase(v, g) for g in globs):
            yield value


def any_glob_match(values: Iterable[str], patterns: Iterable[str]) -> bool:
    """True if any value matches any pattern (case-insensitive, fnmatch)."""
    return next(_iter_glob_matches(values, patterns), None) is not None


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
        hours = 0
        minutes = int(parts[0])
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


def filter_rows_by_shapes(
    rows: List["AllocationRow"],
    shapes: Optional[Sequence[ProbeShape]],
) -> List["AllocationRow"]:
    """Keep rows compatible with at least one supplied shape.

    This lets SHAPE_LIST narrow output consistently even when wait probing is
    disabled. Missing hardware metadata follows ProbeShape.should_skip()'s
    existing best-effort convention.
    """
    if not shapes:
        return rows
    return [
        row for row in rows
        if any(not shape.should_skip(row) for shape in shapes)
    ]


def _filter_signature(filter_: HardwareFilter) -> Tuple[object, ...]:
    return (
        filter_.cpu_vendor,
        filter_.cpu_archs,
        filter_.gpu_gen,
        filter_.gpu_sm,
        filter_.gpu_gen_min,
        filter_.gpu_sm_min,
    )


def _shape_signature(shape: ProbeShape) -> Tuple[object, ...]:
    """Stable identity for a shape ignoring walltime — used for grouping."""
    return (
        shape.nodes,
        shape.cpus,
        shape.mem,
        shape.gpu_type,
        shape.gpu_count,
        _filter_signature(shape.filter),
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
            filter=first_shape.filter,
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


def _format_cpu_shape_token(arch: str, cps: int, free: int, total: int) -> str:
    """Render one CPU shape bucket as 'arch{cps}c:free/total'.

    arch is the canonical short token (gen, skl, csl, …); falls back to '?'
    when the node had no classifiable feature. cps is cores-per-socket.
    """
    label = arch or "?"
    return f"{label}{cps}c:{free}/{total}"


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
    show_gpus: bool = False,
) -> str:
    records = [
        row.to_dict(
            wide=wide,
            include_avail=include_avail,
            include_wait=include_wait,
            shape=shape,
            show_gpus=show_gpus,
        )
        for row, shape in pairs
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
    color = _color_enabled(tty)

    # Wrap list-style columns (free_cpus, free_gpus) onto continuation lines
    # when we're rendering for a tty. The wrap helper is content-agnostic —
    # it only splits on ", " — so it handles both columns identically.
    wrap_candidates = ("free_cpus", "free_gpus")
    wrap_targets: List[str] = []
    if include_avail and tty and columns:
        for col in wrap_candidates:
            if col in columns and any(record.get(col) for record in records):
                wrap_targets.append(col)

    base_widths = {
        column: max(
            len(column),
            max((len(record.get(column, "")) for record in records), default=0),
        )
        for column in columns
    }

    wrapped_cells: Dict[str, List[List[str]]] = {}
    if wrap_targets:
        non_wrap_cell_width = sum(
            base_widths[c] for c in columns if c not in wrap_targets
        )
        separator_chars = 2 * (len(columns) - 1) if len(columns) > 1 else 0
        available = max(40, term_width - non_wrap_cell_width - separator_chars)
        natural = {col: base_widths[col] for col in wrap_targets}
        total_natural = sum(natural.values()) or 1
        budgets: Dict[str, int] = {}
        for col in wrap_targets:
            share = max(20, int(available * natural[col] / total_natural))
            budgets[col] = min(natural[col], share) if natural[col] > 0 else 20
        for col in wrap_targets:
            wrapped_cells[col] = [
                _wrap_gpu_list(r.get(col, ""), budgets[col]) for r in records
            ]
        widths = dict(base_widths)
        for col in wrap_targets:
            widths[col] = max(
                len(col),
                max(
                    (max(len(line) for line in cell) for cell in wrapped_cells[col] if cell),
                    default=0,
                ),
            )
    else:
        widths = base_widths

    header = "  ".join(column.upper().ljust(widths[column]) for column in columns)
    rule = "  ".join("-" * widths[column] for column in columns)
    lines = [header, rule]
    # When any record wraps onto continuation lines, separate records with a
    # blank line so the eye can tell where one row ends and the next begins.
    if wrap_targets:
        max_lines_per_record = [
            max((len(wrapped_cells[col][i]) for col in wrap_targets), default=1) or 1
            for i in range(len(records))
        ]
    else:
        max_lines_per_record = [1] * len(records)
    separate_records = bool(wrap_targets and any(n > 1 for n in max_lines_per_record))
    for index, record in enumerate(records):
        if separate_records and index > 0:
            lines.append("")
        if wrap_targets:
            max_lines = max_lines_per_record[index]
            for li in range(max_lines):
                parts: List[str] = []
                for c in columns:
                    if c in wrap_targets:
                        cell_lines = wrapped_cells[c][index] or [""]
                        text = cell_lines[li] if li < len(cell_lines) else ""
                    else:
                        text = record.get(c, "") if li == 0 else ""
                    parts.append(_styled_cell(c, text.ljust(widths[c]), text, color))
                lines.append("  ".join(parts))
        else:
            def cell(c: str) -> str:
                value = record.get(c, "")
                return _styled_cell(c, value.ljust(widths[c]), value, color)
            lines.append("  ".join(cell(c) for c in columns))
    if not records:
        lines.append("(no matching allocations)")
    return "\n".join(lines)


def csv_output(
    pairs: List[Tuple[AllocationRow, Optional[ProbeShape]]],
    wide: bool,
    include_avail: bool = False,
    include_wait: bool = True,
    *,
    show_gpus: bool = False,
) -> str:
    records = [
        row.to_dict(
            wide=wide,
            include_avail=include_avail,
            include_wait=include_wait,
            shape=shape,
            show_gpus=show_gpus,
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
    *,
    show_gpus: bool = False,
) -> str:
    records = [
        row.to_dict(
            wide=wide,
            include_avail=include_avail,
            include_wait=include_wait,
            shape=shape,
            show_gpus=show_gpus,
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
                "shape": "probed job shape: '<gpu>:<count>@<wall>[,<mem>]' or "
                        "'cpu:<cpus>@<wall>[,<mem>]'. The 'wait' value on this row "
                        "is for THIS shape on THIS allocation. With a multi-shape "
                        "SHAPE_LIST, each (allocation, shape) pair gets its own row.",
                "wait": "predicted seconds until job start from `sbatch --test-only` "
                        "for the shape on this row; 'now' means startable immediately, "
                        "'?' / null means probe skipped or unknown",
                "free_nodes": "live free/total node count from sinfo",
                "free_cpus": "live free/total CPU count from sinfo",
                "free_gpus": "comma-separated 'gtype:free/total' per partition (live)",
                "gpu_types": "GPU types exposed by the partition (with --wide)",
                "gpus": "the row's GPU type resolved from the probe shape's "
                        "gpu_type (e.g. shape 'h100' resolves to row 'h100nvl'). "
                        "Shown when an active probe shape carries a gpu_type.",
                "cpu_features": "node feature tags for the partition (with --wide)",
                "cpu_vendor": "derived from cpu_features: 'intel', 'amd', "
                        "'mixed', or '' when unknown. Sort key 'vendor' ranks "
                        "intel<amd<mixed<unknown.",
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
                "Multi-shape output is long format: one row per (allocation, shape) "
                "pair. The `shape` column tells you which shape was probed for that wait.",
                "Each shape is gated on accessibility — pairs where the shape "
                "can't run on the row are dropped from output.",
                "By default, rows are hidden when the probe returned `?`, "
                "the QOS has no MaxWall, the shape's walltime exceeds the "
                "QOS MaxWall, or the allocation has zero free capacity. "
                "Pass --show-all to include them.",
            ],
        },
        "rows": records,
    }
    return json.dumps(payload, indent=2, sort_keys=True)


def _effective_partition(row: AllocationRow) -> str:
    """Best partition directive for paste-ready sbatch output.

    Association rows often omit Partition. For CHPC's freecycle/reservation
    QOSes, the runnable partition is usually the QOS name with that suffix
    stripped. Guest QOSes commonly use a partition that keeps the `-guest`
    suffix, so preserve the full QOS name unless sacctmgr provided Partition.
    """
    if row.partition:
        return row.partition
    if row.qos:
        for suffix in ("-freecycle", "-res"):
            if row.qos.endswith(suffix):
                stripped = row.qos[: -len(suffix)]
                if stripped:
                    return stripped
        return row.qos
    return ""


def _shape_sbatch_directive_lines(
    row: AllocationRow,
    shape: Optional[ProbeShape],
) -> List[str]:
    if shape is None:
        return []
    lines: List[str] = []
    args = shape.to_sbatch_args(row)
    i = 0
    while i < len(args):
        arg = args[i]
        if arg == "-N" and i + 1 < len(args):
            lines.append(f"#SBATCH --nodes={args[i + 1]}")
            i += 2
        elif arg == "-n" and i + 1 < len(args):
            lines.append(f"#SBATCH --ntasks={args[i + 1]}")
            i += 2
        elif arg == "-t" and i + 1 < len(args):
            lines.append(f"#SBATCH --time={args[i + 1]}")
            i += 2
        else:
            lines.append(f"#SBATCH {arg}")
            i += 1
    return lines


def sbatch_directive_lines(
    row: AllocationRow,
    shape: Optional[ProbeShape] = None,
) -> List[str]:
    """Return paste-ready #SBATCH lines for an allocation and optional shape."""
    lines = []
    if row.cluster:
        lines.append(f"#SBATCH --clusters={row.cluster}")
    if row.account:
        lines.append(f"#SBATCH --account={row.account}")
    partition = _effective_partition(row)
    if partition:
        lines.append(f"#SBATCH --partition={partition}")
    if row.qos:
        lines.append(f"#SBATCH --qos={row.qos}")
    lines.extend(_shape_sbatch_directive_lines(row, shape))
    return lines


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
    directives = sbatch_directive_lines(row, shape)
    if fmt == "json":
        return json.dumps(
            {
                "cluster": row.cluster,
                "account": row.account,
                "partition": row.partition,
                "effective_partition": _effective_partition(row),
                "qos": row.qos,
                "time": shape.time if shape else "",
                "shape_label": shape.label if shape else "",
                "sbatch_directives": directives,
                "predicted_wait_seconds": wait_secs,
                "alternatives": alternatives,
            },
            indent=2,
            sort_keys=True,
        )
    lines = list(directives)
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
        wait_secs = row.wait_by_shape.get(shape.label)
        cells[(key, shape.label)] = _format_wait(wait_secs)
    if not row_keys or not shape_labels:
        return "(no matching allocations)"
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
        return headers[i].ljust(widths[i])

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
    assert parse_wall_seconds("60") == 3600  # bare SLURM walltime is minutes
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
    assert "CLUSTER" in summary and "GTYPE" in summary, summary
    assert "notchpeak-gpu" in summary, summary
    # a100 row carries vendor/generation/SM annotations.
    a100_line = next(ln for ln in summary.splitlines() if "a100" in ln)
    assert "nvidia" in a100_line and "ampere" in a100_line, a100_line
    assert "sm_80" in a100_line and "3/4" in a100_line, a100_line

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
    assert "granite-gpu" in cpu_summary and "Genoa" in cpu_summary, cpu_summary
    assert "AMD" in cpu_summary, cpu_summary
    # Long-form display, never the short feature token.
    assert "gen," not in cpu_summary and " gen " not in cpu_summary, cpu_summary
    # Multi-feature Intel CPU partition surfaces sorted long-form names.
    cpu_intel = format_cpu_summary(
        {"notchpeak": {"notchpeak-shared-short": {"csl", "emr", "skl"}}}
    )
    intel_line = next(ln for ln in cpu_intel.splitlines() if "shared-short" in ln)
    assert "Intel" in intel_line, intel_line
    assert "Cascade Lake, Emerald Rapids, Skylake" in intel_line, intel_line

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
    bucket.add_cpu_shape("gen", 96, 32, 128)
    fc_row3 = AllocationRow(
        "granite", "sadayappan", "me", "", "granite-gpu-freecycle", ""
    )
    attach_row_availability(fc_row3, avail)
    assert fc_row3.free_nodes == "1/2"
    assert fc_row3.free_cpus == "gen96c:32/128"
    assert fc_row3.free_gpus == "h100nvl:4/16"
    record = fc_row3.to_dict(include_avail=True)
    assert record["free_nodes"] == "1/2"
    assert record["free_gpus"] == "h100nvl:4/16"
    assert "free_nodes" not in fc_row3.to_dict()  # opt-in only

    # Per-shape CPU formatter and ordering — biggest pool first, '?' last.
    assert _format_cpu_shape_token("gen", 96, 192, 384) == "gen96c:192/384"
    assert _format_cpu_shape_token("", 64, 0, 64) == "?64c:0/64"
    multi_avail = {"notchpeak": {"notchpeak-shared-short": PartitionAvail()}}
    mb = multi_avail["notchpeak"]["notchpeak-shared-short"]
    mb.nodes_total = 6
    mb.nodes_free = 4
    mb.cpus_total = 512
    mb.cpus_free = 224
    mb.add_cpu_shape("skl", 16, 32, 128)
    mb.add_cpu_shape("gen", 96, 192, 384)
    mb.add_cpu_shape("", 32, 0, 0)  # empty shape ignored by sort but still appears
    multi_row = AllocationRow(
        "notchpeak", "notchpeak-shared-short", "me", "", "notchpeak-shared-short", ""
    )
    attach_row_availability(multi_row, multi_avail)
    assert multi_row.free_cpus.startswith("gen96c:192/384"), multi_row.free_cpus
    assert "skl16c:32/128" in multi_row.free_cpus, multi_row.free_cpus

    # Fallback: when bucket has no per-shape data, the legacy F/T form is used.
    fb_avail = {"granite": {"granite": PartitionAvail()}}
    fb = fb_avail["granite"]["granite"]
    fb.nodes_total = 1
    fb.nodes_free = 1
    fb.cpus_total = 96
    fb.cpus_free = 48
    fb_row = AllocationRow("granite", "sadayappan", "me", "", "granite", "")
    attach_row_availability(fb_row, fb_avail)
    assert fb_row.free_cpus == "48/96", fb_row.free_cpus

    # CPU summary: GPU partitions are filtered out when partition_avail
    # carries gpus, and a CPU-only partition surfaces availability columns.
    cpu_only_avail = {"notchpeak": {"notchpeak-shared-short": PartitionAvail()}}
    cb = cpu_only_avail["notchpeak"]["notchpeak-shared-short"]
    cb.nodes_total = 10
    cb.nodes_free = 5
    cb.cpus_total = 200
    cb.cpus_free = 80
    cpu_features = {
        "granite": {"granite-gpu": {"gen", "h100nvl"}},  # filtered (has gpus)
        "notchpeak": {"notchpeak-shared-short": {"csl", "emr", "skl"}},
    }
    cpu_only_avail["granite"] = {"granite-gpu": PartitionAvail()}
    cpu_only_avail["granite"]["granite-gpu"].add_gpu("h100nvl", 4, 16)
    cpu_summary_avail = format_cpu_summary(cpu_features, cpu_only_avail)
    assert "granite-gpu" not in cpu_summary_avail, cpu_summary_avail
    assert "notchpeak-shared-short" in cpu_summary_avail, cpu_summary_avail
    assert "5/10" in cpu_summary_avail and "80/200" in cpu_summary_avail
    assert "NODES_F/T" in cpu_summary_avail and "CPUS_F/T" in cpu_summary_avail

    # Memory + node-type formatters.
    assert _format_mem_gib(746) == "746G"
    assert _format_mem_gib(1024) == "1.0T"
    assert _format_mem_gib(1496) == "1.5T"
    assert _format_node_type(("gen", 96, 1, 746), 5) == "Genoa 96c×1 746G ×5"
    assert _format_node_type(("", 64, 2, 1496), 1) == "? 64c×2 1.5T ×1"

    # _node_arch_short picks the first feature that classifies.
    assert _node_arch_short("chpc,gen,c96,m768") == "gen"
    assert _node_arch_short("chpc,c96,m768") == ""
    assert _node_arch_short("(null)") == ""

    # NODE_TYPE column renders sorted by descending count, joined with '; '.
    nt_avail = {"granite": {"granite": PartitionAvail()}}
    nb = nt_avail["granite"]["granite"]
    nb.nodes_total = 8
    nb.nodes_free = 3
    nb.cpus_total = 768
    nb.cpus_free = 96
    for _ in range(5):
        nb.add_node_type(("gen", 96, 1, 746))
    for _ in range(3):
        nb.add_node_type(("gen", 96, 2, 1496))
    nt_summary = format_cpu_summary(
        {"granite": {"granite": {"gen", "chpc"}}}, nt_avail
    )
    assert "NODE_TYPE" in nt_summary, nt_summary
    nt_line = next(
        ln for ln in nt_summary.splitlines() if " granite " in f" {ln} "
    )
    # Higher-count signature comes first.
    assert nt_line.index("Genoa 96c×1") < nt_line.index("Genoa 96c×2"), nt_line
    assert "; " in nt_line, nt_line
    assert "×5" in nt_line and "×3" in nt_line

    # _render_simple_table emits header + rule + rows, all width-aligned.
    rendered_table = _render_simple_table(
        ["A", "BB"], [["x", "yyyy"], ["zz", "w"]]
    )
    table_lines = rendered_table.splitlines()
    assert len(table_lines) == 4, rendered_table
    assert table_lines[0].startswith("A "), table_lines[0]
    assert table_lines[1].startswith("--"), table_lines[1]
    # Every row reaches the same width (left-justified).
    assert len(set(len(ln) for ln in table_lines)) == 1, table_lines

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
    assert "a100" in continuation or "h100" in continuation \
        or "l40s" in continuation or "rtx" in continuation \
        or "h200" in continuation, repr(continuation)
    # When piped (tty=False) we get a single physical line per row.
    rendered_piped = table_output(
        [(avail_row, None)], wide=False, include_avail=True, tty=False, term_width=60
    )
    assert len(rendered_piped.splitlines()) == 3  # header + rule + one row

    # free_cpus also wraps when its content is long and we're rendering for tty.
    wide_cpu_row = AllocationRow(
        "notchpeak", "soc-np", "me", "", "soc-np", "soc-np"
    )
    wide_cpu_row.qos_info = QOSInfo("soc-np")
    wide_cpu_row.tags = classify(wide_cpu_row)
    wide_cpu_row.free_nodes = "4/12"
    wide_cpu_row.free_cpus = (
        "gen96c:192/384, skl16c:32/128, csl20c:40/160, "
        "icx32c:64/256, spr48c:96/384"
    )
    wide_cpu_row.free_gpus = ""
    rendered_cpu = table_output(
        [(wide_cpu_row, None)], wide=False, include_avail=True, tty=True, term_width=60
    )
    rendered_cpu_lines = rendered_cpu.splitlines()
    assert len(rendered_cpu_lines) >= 4, rendered_cpu
    # At least one line after the data row should carry a CPU shape token.
    assert any(
        "gen96c" in ln or "skl16c" in ln or "csl20c" in ln
            or "icx32c" in ln or "spr48c" in ln
        for ln in rendered_cpu_lines[3:]
    ), rendered_cpu

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

    h100_row = AllocationRow("notchpeak", "x", "u", "", "q", "q")
    h100_row.tags = ("gpu",)
    h100_row.gpu_types = ("h100nvl", "l40s")
    assert ProbeShape(gpu_type="h100nvl").resolved_gpu_type(h100_row) == "h100nvl"
    assert ProbeShape(gpu_type="h100").resolved_gpu_type(h100_row) == "h100nvl"
    assert ProbeShape(gpu_type="h100", gpu_count=4).gres_for(h100_row) == "gpu:h100nvl:4"
    assert ProbeShape(gpu_type="h100").resolved_gpu_type(empty_gpu_row) == "h100"
    assert ProbeShape(gpu_type="h100").resolved_gpu_type(gpu_row) == "h100"
    assert ProbeShape().resolved_gpu_type(gpu_row) is None

    # _gpus_cell: shows the per-row resolution of the shape's gpu_type;
    # empty for CPU rows, missing shapes, or shapes without a gpu_type.
    assert h100_row._gpus_cell(ProbeShape(gpu_type="h100", gpu_count=1)) == "h100nvl"
    assert h100_row._gpus_cell(ProbeShape(gpu_type="h100")) == "h100nvl"
    assert h100_row._gpus_cell(None) == ""
    assert h100_row._gpus_cell(ProbeShape(cpus=32)) == ""
    assert cpu_row._gpus_cell(ProbeShape(gpu_type="h100")) == ""
    # Default probe never skips.
    assert ProbeShape().should_skip(gpu_row) is False
    assert ProbeShape().should_skip(cpu_row) is False
    # predict_wait honors should_skip even with sbatch on PATH.
    assert predict_wait(gpu_row, shape=ProbeShape(gpu_type="a100", gpu_count=4)) is None

    # parse_shape_list: '+' splits OR groups; '*' merges AND pieces into one shape.
    parser = _build_parser()
    shapes_one = parse_shape_list("a100:4")
    assert len(shapes_one) == 1 and shapes_one[0].gpu_type == "a100" and shapes_one[0].gpu_count == 4
    shapes_many = parse_shape_list("a100:4+cpu:32@12h+h100:1@30m")
    assert [s.label for s in shapes_many] == ["a100:4@1h", "cpu:32@12h", "h100:1@30m"]
    # Whitespace around '+' tolerated.
    shapes_ws = parse_shape_list(" a100:4 + cpu:32 ")
    assert [s.label for s in shapes_ws] == ["a100:4@1h", "cpu:32@1h"]
    # AND ('*'): one combined shape with both gpu and cpu fields populated.
    shapes_and = parse_shape_list("a100:4*cpu:32")
    assert len(shapes_and) == 1
    assert shapes_and[0].gpu_type == "a100" and shapes_and[0].gpu_count == 4
    assert shapes_and[0].cpus == 32
    # AND with @-suffix on one piece: time flows through to the merged shape.
    shapes_and_t = parse_shape_list("a100:4@2h*cpu:32")
    assert shapes_and_t[0].time == "2h" and shapes_and_t[0].cpus == 32
    # Mixed: '*' binds tighter than '+'. First shape is the AND-merged piece.
    shapes_mix = parse_shape_list("a100:4*cpu:32+h100:1")
    assert len(shapes_mix) == 2
    assert shapes_mix[0].gpu_type == "a100" and shapes_mix[0].cpus == 32
    assert shapes_mix[1].gpu_type == "h100" and shapes_mix[1].cpus == DEFAULT_PROBE_CPUS
    # Whitespace around '*' tolerated.
    shapes_and_ws = parse_shape_list(" a100:4 * cpu:32 ")
    assert shapes_and_ws[0].gpu_type == "a100" and shapes_and_ws[0].cpus == 32
    # Same-field collision in AND group: last-wins (consistent with intra-shape tokens).
    shapes_collide = parse_shape_list("a100:4@1h*cpu:32@2h")
    assert shapes_collide[0].time == "2h"
    # Empty/blank input and empty pieces raise (both '+' and '*' separators).
    for bad in (
        "", " ", "+", "a100:4+", "+a100:4", "a100:4++cpu:32",
        "*a100:4", "a100:4*", "a100:4**cpu:32", "a100:4*+h100:1",
    ):
        try:
            parse_shape_list(bad)
        except CommandError:
            pass
        else:
            raise AssertionError(f"parse_shape_list({bad!r}) should have raised")

    # Positional SHAPE_LIST flows into args.shape_pos and is parsed in main().
    a = parser.parse_args(["a100:4"])
    assert a.shape_pos == "a100:4"
    a = parser.parse_args(["a100:4+cpu:32"])
    assert a.shape_pos == "a100:4+cpu:32"

    sh = parse_shape_spec("a100:1@30m")
    assert sh.gpu_type == "a100" and sh.gpu_count == 1 and sh.time == "30m"
    sh = parse_shape_spec("cpu:32@12h")
    assert sh.cpus == 32 and sh.gpu_type is None and sh.time == "12h"
    sh = parse_shape_spec("gpu:4@2h")
    assert sh.gpu_type is None and sh.gpu_count == 4 and sh.time == "2h"
    for bad in ("a100:1@", "@30m", "cpu:32@notatime"):
        try:
            parse_shape_spec(bad)
        except CommandError:
            pass
        else:
            raise AssertionError(f"parse_shape_spec({bad!r}) should have raised")

    # _canon_cpu_arch: short forms pass through, long forms map, others -> None.
    assert _canon_cpu_arch("skl") == "skl"
    assert _canon_cpu_arch("gen") == "gen"
    assert _canon_cpu_arch("genoa") == "gen"
    assert _canon_cpu_arch("rome") == "rom"
    assert _canon_cpu_arch("milan") == "mil"
    assert _canon_cpu_arch("Cascade-Lake") == "csl"
    assert _canon_cpu_arch("zen4") == "zen4"
    assert _canon_cpu_arch("a100") is None
    assert _canon_cpu_arch("") is None

    # _features_match_vendor: substring check against vendor's table.
    assert _features_match_vendor(("zen4",), "amd") is True
    assert _features_match_vendor(("zen4",), "intel") is False
    assert _features_match_vendor(("skl",), "intel") is True
    assert _features_match_vendor((), "intel") is False

    # parse_shape_spec: vendor and arch atoms (positional bare tokens).
    sh = parse_shape_spec("intel")
    assert sh.filter.cpu_vendor == "intel" and sh.filter.cpu_archs == () and sh.gpu_type is None
    sh = parse_shape_spec("amd")
    assert sh.filter.cpu_vendor == "amd"
    sh = parse_shape_spec("genoa")
    assert sh.filter.cpu_archs == ("gen",) and sh.filter.cpu_vendor is None
    sh = parse_shape_spec("zen4")
    assert sh.filter.cpu_archs == ("zen4",)
    # Combined positional: a100:4 with vendor filter.
    sh = parse_shape_spec("a100:4,intel")
    assert sh.gpu_type == "a100" and sh.gpu_count == 4 and sh.filter.cpu_vendor == "intel"
    # key=value forms.
    sh = parse_shape_spec("a100:4,vendor=amd")
    assert sh.filter.cpu_vendor == "amd"
    sh = parse_shape_spec("cpu:32,arch=rome")
    assert sh.cpus == 32 and sh.filter.cpu_archs == ("rom",)
    # Label includes arch (preferred) or vendor.
    assert ",gen" in parse_shape_spec("cpu:32,arch=genoa").label
    assert ",intel" in parse_shape_spec("a100:4,vendor=intel").label
    # arch wins over vendor in the label.
    label = parse_shape_spec("a100:4,vendor=amd,arch=genoa").label
    assert ",gen" in label and ",amd" not in label
    # Bad vendor/arch values raise.
    for bad in ("vendor=nvidia", "arch=potato", "vendor="):
        try:
            parse_shape_spec(bad)
        except CommandError:
            pass
        else:
            raise AssertionError(f"parse_shape_spec({bad!r}) should have raised")

    # parse_shape_list: AND-combine GPU shape with vendor atom.
    shapes_va = parse_shape_list("a100:4*intel")
    assert len(shapes_va) == 1
    assert shapes_va[0].gpu_type == "a100" and shapes_va[0].filter.cpu_vendor == "intel"
    # OR across vendors.
    shapes_or = parse_shape_list("intel+amd")
    assert [s.filter.cpu_vendor for s in shapes_or] == ["intel", "amd"]

    # HardwareFilter.cpu_constraint_expr: arch wins, vendor expands to OR over table.
    assert HardwareFilter().cpu_constraint_expr() is None
    assert HardwareFilter(cpu_archs=("gen",)).cpu_constraint_expr() == "gen"
    assert HardwareFilter(cpu_archs=("rom", "mil")).cpu_constraint_expr() == "rom&mil"
    intel_expr = HardwareFilter(cpu_vendor="intel").cpu_constraint_expr()
    assert intel_expr and "skl" in intel_expr and "csl" in intel_expr and "|" in intel_expr
    amd_expr = HardwareFilter(cpu_vendor="amd").cpu_constraint_expr()
    assert amd_expr and "zen" in amd_expr and "gen" in amd_expr
    # arch takes precedence over vendor when both set.
    assert HardwareFilter(cpu_vendor="intel", cpu_archs=("gen",)).cpu_constraint_expr() == "gen"

    # HardwareFilter helpers: has_*, label_markers, satisfies.
    assert HardwareFilter().has_any() is False
    assert HardwareFilter(cpu_vendor="intel").has_cpu_constraint() is True
    assert HardwareFilter(cpu_vendor="intel").has_gpu_constraint() is False
    assert HardwareFilter(gpu_gen="ampere").has_gpu_constraint() is True
    assert HardwareFilter(gpu_sm_min=80).has_gpu_constraint() is True
    assert HardwareFilter(cpu_vendor="intel").label_markers() == ["intel"]
    assert HardwareFilter(cpu_archs=("gen",)).label_markers() == ["gen"]
    assert HardwareFilter(gpu_gen="ampere", gpu_sm_min=80).label_markers() == ["ampere", "sm80+"]
    assert HardwareFilter(gpu_gen_min="ampere").label_markers() == ["ampere+"]
    # cpu_satisfies: True for empty features (metadata not loaded), else predicate.
    assert HardwareFilter().cpu_satisfies(()) is True
    assert HardwareFilter(cpu_vendor="intel").cpu_satisfies(()) is True
    assert HardwareFilter(cpu_vendor="intel").cpu_satisfies(("zen4",)) is False
    assert HardwareFilter(cpu_vendor="intel").cpu_satisfies(("skl",)) is True

    # to_sbatch_args: --constraint emitted only when vendor/arch set.
    args_intel = ProbeShape(filter=HardwareFilter(cpu_vendor="intel")).to_sbatch_args(cpu_row)
    assert any(a.startswith("--constraint=") for a in args_intel)
    args_plain = ProbeShape().to_sbatch_args(cpu_row)
    assert not any(a.startswith("--constraint=") for a in args_plain)
    args_arch = ProbeShape(filter=HardwareFilter(cpu_archs=("gen",))).to_sbatch_args(cpu_row)
    assert "--constraint=gen" in args_arch

    # should_skip: vendor/arch row predicates.
    intel_row = AllocationRow("notchpeak", "x", "u", "", "q", "q")
    intel_row.tags = ("cpu",)
    intel_row.cpu_features = ("skl",)
    amd_row = AllocationRow("notchpeak", "x", "u", "", "q", "q")
    amd_row.tags = ("cpu",)
    amd_row.cpu_features = ("zen4",)
    no_feat_row = AllocationRow("notchpeak", "x", "u", "", "q", "q")
    no_feat_row.tags = ("cpu",)
    # vendor mismatch skips; match doesn't.
    assert ProbeShape(filter=HardwareFilter(cpu_vendor="intel")).should_skip(amd_row) is True
    assert ProbeShape(filter=HardwareFilter(cpu_vendor="intel")).should_skip(intel_row) is False
    assert ProbeShape(filter=HardwareFilter(cpu_vendor="amd")).should_skip(amd_row) is False
    # arch mismatch skips; substring match (zen4 contains zen) works.
    assert ProbeShape(filter=HardwareFilter(cpu_archs=("gen",))).should_skip(amd_row) is True
    assert ProbeShape(filter=HardwareFilter(cpu_archs=("zen",))).should_skip(amd_row) is False
    assert ProbeShape(filter=HardwareFilter(cpu_archs=("zen4",))).should_skip(amd_row) is False
    # Empty cpu_features: don't skip (metadata not loaded).
    assert ProbeShape(filter=HardwareFilter(cpu_vendor="intel")).should_skip(no_feat_row) is False
    assert ProbeShape(filter=HardwareFilter(cpu_archs=("gen",))).should_skip(no_feat_row) is False

    # _canon_gpu_gen: aliases collapse, unknown -> None.
    assert _canon_gpu_gen("ampere") == "ampere"
    assert _canon_gpu_gen("Ampere") == "ampere"
    assert _canon_gpu_gen("lovelace") == "ada"
    assert _canon_gpu_gen("ada-lovelace") == "ada"
    assert _canon_gpu_gen("blackwell") == "blackwell"
    assert _canon_gpu_gen("foo") is None
    assert _canon_gpu_gen("") is None

    # _parse_sm_token: sm70 / sm_70 / SM89; reject unknown.
    assert _parse_sm_token("sm70") == 70
    assert _parse_sm_token("sm_70") == 70
    assert _parse_sm_token("SM89") == 89
    assert _parse_sm_token("sm120") == 120
    assert _parse_sm_token("sm99") is None  # not in GPU_SM_TOKENS
    assert _parse_sm_token("smfoo") is None
    assert _parse_sm_token("a100") is None
    assert _parse_sm_token("") is None

    # _classify_gpu_token: longest-prefix wins; MIG slices inherit.
    assert _classify_gpu_token("a100") == ("ampere", 80)
    assert _classify_gpu_token("a100_80gb_pcie") == ("ampere", 80)
    assert _classify_gpu_token("a100_80gb_pcie_1g.10gb") == ("ampere", 80)
    assert _classify_gpu_token("a6000") == ("ampere", 86)
    assert _classify_gpu_token("h200") == ("hopper", 90)
    assert _classify_gpu_token("h200_1g.18gb") == ("hopper", 90)
    assert _classify_gpu_token("h100nvl") == ("hopper", 90)
    assert _classify_gpu_token("rtx4000ada") == ("ada", 89)
    assert _classify_gpu_token("rtx6000ada") == ("ada", 89)
    assert _classify_gpu_token("rtx6000") == ("turing", 75)  # bare = Turing
    assert _classify_gpu_token("rtxpr6000bl") == ("blackwell", 120)
    assert _classify_gpu_token("l40s") == ("ada", 89)
    assert _classify_gpu_token("v100") == ("volta", 70)
    assert _classify_gpu_token("titanv") == ("volta", 70)
    assert _classify_gpu_token("p40") == ("pascal", 61)
    assert _classify_gpu_token("2080ti") == ("turing", 75)
    assert _classify_gpu_token("madeupgpu") is None

    # _gpu_token_satisfies: each constraint independently.
    assert _gpu_token_satisfies("a100", gen="ampere", sm=None, gen_min=None, sm_min=None) is True
    assert _gpu_token_satisfies("a100", gen="hopper", sm=None, gen_min=None, sm_min=None) is False
    assert _gpu_token_satisfies("a100", gen=None, sm=80, gen_min=None, sm_min=None) is True
    assert _gpu_token_satisfies("a100", gen=None, sm=89, gen_min=None, sm_min=None) is False
    assert _gpu_token_satisfies("h100", gen=None, sm=None, gen_min="ampere", sm_min=None) is True
    assert _gpu_token_satisfies("v100", gen=None, sm=None, gen_min="ampere", sm_min=None) is False
    assert _gpu_token_satisfies("a6000", gen=None, sm=None, gen_min=None, sm_min=80) is True
    assert _gpu_token_satisfies("v100", gen=None, sm=None, gen_min=None, sm_min=80) is False
    assert _gpu_token_satisfies("madeupgpu", gen="ampere", sm=None, gen_min=None, sm_min=None) is False

    # parse_shape_spec: gen/SM atoms (positional).
    sh = parse_shape_spec("ampere")
    assert sh.filter.gpu_gen == "ampere" and sh.filter.gpu_sm is None
    sh = parse_shape_spec("hopper")
    assert sh.filter.gpu_gen == "hopper"
    sh = parse_shape_spec("lovelace")
    assert sh.filter.gpu_gen == "ada"
    sh = parse_shape_spec("sm80")
    assert sh.filter.gpu_sm == 80 and sh.filter.gpu_gen is None
    sh = parse_shape_spec("sm_89")
    assert sh.filter.gpu_sm == 89
    # parse_shape_spec: gen/SM atoms (key=value).
    sh = parse_shape_spec("gpu:4,gen=hopper")
    assert sh.gpu_count == 4 and sh.filter.gpu_gen == "hopper"
    sh = parse_shape_spec("gpu:1,sm_min=80")
    assert sh.filter.gpu_sm_min == 80 and sh.gpu_count == 1
    sh = parse_shape_spec("gpu:1,gen_min=ampere")
    assert sh.filter.gpu_gen_min == "ampere"
    sh = parse_shape_spec("gpu:4,sm=89")
    assert sh.filter.gpu_sm == 89
    # AND-combine: explicit GPU type plus generation.
    shapes_ag = parse_shape_list("a100:4*ampere")
    assert len(shapes_ag) == 1
    assert shapes_ag[0].gpu_type == "a100" and shapes_ag[0].filter.gpu_gen == "ampere"
    # Bad gen/SM values raise.
    for bad in ("gen=potato", "sm=99", "sm_min=99", "gen_min=foo", "gen=", "sm="):
        try:
            parse_shape_spec(bad)
        except CommandError:
            pass
        else:
            raise AssertionError(f"parse_shape_spec({bad!r}) should have raised")

    # Label: gen/SM markers; min uses '+' suffix.
    assert ",ampere" in parse_shape_spec("ampere").label
    assert ",sm80" in parse_shape_spec("sm80").label
    assert ",sm80+" in parse_shape_spec("gpu:1,sm_min=80").label
    assert ",ampere+" in parse_shape_spec("gpu:1,gen_min=ampere").label
    # Bare gen/SM atoms produce a GPU label, not CPU.
    assert parse_shape_spec("ampere").label.startswith("gpu:1@")
    assert parse_shape_spec("sm80").label.startswith("gpu:1@")

    # to_sbatch_args: gen/SM does NOT emit --constraint.
    amp_filter = HardwareFilter(gpu_gen="ampere")
    args_amp = ProbeShape(filter=amp_filter).to_sbatch_args(gpu_row)
    assert not any(a.startswith("--constraint=") for a in args_amp)

    # should_skip: gen/SM row predicates.
    a100_row = AllocationRow("notchpeak", "x", "u", "", "q", "q")
    a100_row.tags = ("gpu",)
    a100_row.gpu_types = ("a100", "a100_80gb_pcie")
    h100_only = AllocationRow("notchpeak", "x", "u", "", "q", "q")
    h100_only.tags = ("gpu",)
    h100_only.gpu_types = ("h100nvl",)
    v100_row = AllocationRow("notchpeak", "x", "u", "", "q", "q")
    v100_row.tags = ("gpu",)
    v100_row.gpu_types = ("v100",)
    no_gpu_meta = AllocationRow("notchpeak", "x", "u", "", "q", "q")
    no_gpu_meta.tags = ("gpu",)
    # Exact gen / sm: skip on mismatch, don't skip on match.
    assert ProbeShape(filter=HardwareFilter(gpu_gen="hopper")).should_skip(a100_row) is True
    assert ProbeShape(filter=amp_filter).should_skip(a100_row) is False
    assert ProbeShape(filter=HardwareFilter(gpu_sm=80)).should_skip(a100_row) is False
    assert ProbeShape(filter=HardwareFilter(gpu_sm=89)).should_skip(a100_row) is True
    # gen_min / sm_min: ge semantics.
    amp_min = HardwareFilter(gpu_gen_min="ampere")
    sm80_min = HardwareFilter(gpu_sm_min=80)
    assert ProbeShape(filter=amp_min).should_skip(v100_row) is True
    assert ProbeShape(filter=amp_min).should_skip(a100_row) is False
    assert ProbeShape(filter=amp_min).should_skip(h100_only) is False
    assert ProbeShape(filter=sm80_min).should_skip(v100_row) is True
    assert ProbeShape(filter=sm80_min).should_skip(a100_row) is False
    # Empty gpu_types: don't skip (metadata not loaded).
    assert ProbeShape(filter=HardwareFilter(gpu_gen="hopper")).should_skip(no_gpu_meta) is False
    assert ProbeShape(filter=sm80_min).should_skip(no_gpu_meta) is False
    # gen/SM on a CPU row: skip (GPU implied).
    assert ProbeShape(filter=amp_filter).should_skip(cpu_row) is True
    # Combined gpu_type + gen: row must satisfy both on the SAME token.
    a100_hopper = ProbeShape(gpu_type="a100", filter=HardwareFilter(gpu_gen="hopper"))
    a100_ampere = ProbeShape(gpu_type="a100", filter=amp_filter)
    h100_hopper = ProbeShape(gpu_type="h100", filter=HardwareFilter(gpu_gen="hopper"))
    assert a100_hopper.should_skip(a100_row) is True
    assert a100_ampere.should_skip(a100_row) is False
    # Heterogeneous row with both a100 (Ampere) and h100 (Hopper):
    # `a100*hopper` must yield zero candidates because no single token
    # satisfies both predicates.
    mixed_row = AllocationRow("notchpeak", "x", "u", "", "q", "q")
    mixed_row.tags = ("gpu",)
    mixed_row.gpu_types = ("a100", "h100nvl")
    assert a100_hopper.should_skip(mixed_row) is True
    assert h100_hopper.should_skip(mixed_row) is False
    assert a100_ampere.should_skip(mixed_row) is False

    # resolved_gpu_type with gen/SM: pick shortest satisfying token.
    h200_row = AllocationRow("notchpeak", "x", "u", "", "q", "q")
    h200_row.tags = ("gpu",)
    h200_row.gpu_types = ("h200_1g.18gb", "h200_2g.35gb", "h200")
    hopper_shape = ProbeShape(filter=HardwareFilter(gpu_gen="hopper"))
    assert hopper_shape.resolved_gpu_type(h200_row) == "h200"
    # gres_for uses the resolved token.
    assert hopper_shape.gres_for(h200_row) == "gpu:h200:1"
    assert ProbeShape(gpu_count=4, filter=HardwareFilter(gpu_gen="hopper")).gres_for(h200_row) == "gpu:h200:4"

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
    sh = parse_shape_spec("cores=8,mem=16G,gpus=h100nvl:1,time=4h")
    assert sh.cpus == 8 and sh.gpu_type == "h100nvl" and sh.gpu_count == 1
    assert sh.label == "h100nvl:1@4h,16G", sh.label
    # Multi-node prefix.
    sh = parse_shape_spec("nodes=2,cores=4,time=1h")
    assert sh.nodes == 2 and sh.label == "2n*cpu:4@1h", sh.label
    # Wall short-format edges.
    assert _format_wall_short("00:01:00") == "1m"
    assert _format_wall_short("3-00:00:00") == "3d"
    assert _format_wall_short("01:30:00") == "1h30m"
    # Bad shape specs raise. cpus= is no longer accepted.
    for bad in ("", "cores=", "cpus=8", "time=banana", "weird=1", "cores=0"):
        try:
            parse_shape_spec(bad)
        except CommandError:
            pass
        else:
            raise AssertionError(f"parse_shape_spec({bad!r}) should have raised")

    # _to_sbatch_wall canonicalizes compact forms for sbatch -t.
    assert _to_sbatch_wall("1h") == "01:00:00"
    assert _to_sbatch_wall("60") == "01:00:00"
    assert _to_sbatch_wall("24h") == "1-00:00:00"
    assert _to_sbatch_wall("3-00:00:00") == "3-00:00:00"
    assert _to_sbatch_wall("01:30:00") == "01:30:00"
    assert _to_sbatch_wall("garbage") == "garbage"

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

    a100_row = AllocationRow(
        "notchpeak", "x", "u", "", "q-a100", "q-a100",
        cpu_features=("skl",),
    )
    a100_row.gpu_types = ("a100",)
    cpu_only_row = AllocationRow("notchpeak", "x", "u", "", "q-cpu", "q-cpu")
    cpu_only_row.gpu_types = ()

    # Removed flags (--cores/--cpus/--shape/--gpus/--mem/--time/--nodes/
    # --wait-for/--gpu/--cpu/--gpu-type/--cpu-type and legacy aliases) all
    # raise SystemExit at parse time.
    parser = _build_parser()
    for removed in (
        ["--cores", "16"], ["--cpus", "16"], ["--time", "4h"],
        ["--shape", "a100:1"], ["--gpus", "a100:4"], ["--mem", "32G"],
        ["--wait-for", "cpu:32"], ["--nodes", "2"],
        ["--gpu"], ["--cpu"], ["--gpu-type", "a100"], ["--cpu-type", "intel"],
        ["--freecycle"], ["--no-freecycle"], ["--guest"], ["--no-guest"],
        ["--show-unknown"], ["--no-avail"],
        ["--tier", "dev"], ["--list-tiers"],
    ):
        try:
            parser.parse_args(removed)
        except SystemExit:
            pass
        else:
            raise AssertionError(f"removed flag still accepted: {removed}")

    # Positional SHAPE_LIST parses cleanly into args.shape_pos.
    a = parser.parse_args(["a100:4"])
    assert a.shape_pos == "a100:4"
    a = parser.parse_args(["cpu:32"])
    assert a.shape_pos == "cpu:32"
    a = parser.parse_args(["32"])
    assert a.shape_pos == "32"
    a = parser.parse_args(["a100:4+cpu:32@12h"])
    assert a.shape_pos == "a100:4+cpu:32@12h"

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
    # SHAPE_LIST also narrows row output when wait probing is disabled.
    assert filter_rows_by_shapes([cpu_only_row, a100_row], [a100_only]) == [a100_row]
    assert filter_rows_by_shapes([cpu_only_row, a100_row], None) == [cpu_only_row, a100_row]

    # predict_wait_times submits only non-skipped pairs; no sbatch calls for
    # impossible row/shape combinations.
    fake_calls: List[Tuple[str, str]] = []
    orig_predict_wait = globals()["predict_wait"]
    orig_shutil_which = shutil.which

    def fake_predict_wait(row, timeout=10.0, shape=None):
        fake_calls.append((row.qos, shape.label))
        return 0

    def fake_which(name):
        if name == "sbatch":
            return "/bin/true"
        return orig_shutil_which(name)

    try:
        globals()["predict_wait"] = fake_predict_wait
        shutil.which = fake_which
        a100_row.wait_by_shape = {}
        cpu_only_row.wait_by_shape = {}
        predict_wait_times(
            [cpu_only_row, a100_row],
            shapes=[cpu_only_shape, a100_only],
            max_workers=1,
        )
    finally:
        globals()["predict_wait"] = orig_predict_wait
        shutil.which = orig_shutil_which
    assert ("q-cpu", "a100:1@1h") not in fake_calls
    assert len(fake_calls) == 3, fake_calls

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
    # Collapsed shapes preserve hardware filters, and distinct filters never
    # collapse together.
    h_hop_1h = ProbeShape(
        gpu_count=1, time="01:00:00", filter=HardwareFilter(gpu_gen="hopper")
    )
    h_hop_24h = ProbeShape(
        gpu_count=1, time="1-00:00:00", filter=HardwareFilter(gpu_gen="hopper")
    )
    coll_row.wait_by_shape = {h_hop_1h.label: 0, h_hop_24h.label: 0}
    merged_hop = collapse_uniform_walltimes(
        [(coll_row, h_hop_1h), (coll_row, h_hop_24h)]
    )
    assert len(merged_hop) == 1, merged_hop
    assert merged_hop[0][1].filter.gpu_gen == "hopper"
    assert merged_hop[0][1].label == "gpu:1@1h..24h,hopper"
    h_amp_1h = ProbeShape(
        gpu_count=1, time="01:00:00", filter=HardwareFilter(gpu_gen="ampere")
    )
    coll_row.wait_by_shape = {h_hop_1h.label: 0, h_amp_1h.label: 0}
    separated = collapse_uniform_walltimes([(coll_row, h_hop_1h), (coll_row, h_amp_1h)])
    assert len(separated) == 2, separated
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

    # Surviving flags expose their dests.
    a = parser_fmt.parse_args(["--no-availability"])
    assert a.no_availability is True
    a = parser_fmt.parse_args(["--show-all"])
    assert a.show_all is True
    a = parser_fmt.parse_args(["--freecycle-only"])
    assert a.freecycle_only is True and a.exclude_freecycle is False
    a = parser_fmt.parse_args(["--exclude-freecycle"])
    assert a.exclude_freecycle is True
    a = parser_fmt.parse_args(["--guest-only"])
    assert a.guest_only is True
    a = parser_fmt.parse_args(["--exclude-guest"])
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
    # NOT show any of the removed flags or legacy aliases.
    rendered = parser_fmt.format_help()
    for header in (
        "Filtering",
        "Probe shape",
        "Output",
        "Diagnostics & speed",
        "Inventory shortcuts",
        "Common entry points",
        "Quickstart:",
        "Shape grammar:",
        "Filtering rows",
        "Inventory shortcuts (do not consult your allocations; SHAPE_LIST narrows):",
        "Recipes:",
        "Speed (skip probes/queries):",
        "Scripting / output:",
        # Sort key categories surface in --sort help.
        "Time:",
        "Quality:",
    ):
        assert header in rendered, f"expected {header!r} in --help"
    # Removed flags must not appear in --help. Use a word-boundary check so
    # '--no-avail' isn't mistakenly matched against '--no-availability'.
    for removed in ("--no-avail", "--show-unknown", "--freecycle", "--no-freecycle",
                    "--guest", "--no-guest", "--avail", "--cpus", "--cores",
                    "--gpu-type", "--cpu-type", "--gpus", "--shape", "--wait-for",
                    "--tier", "--list-tiers"):
        assert not re.search(rf"{re.escape(removed)}\b(?!-)", rendered), \
            f"removed flag {removed!r} leaked into --help"
    # Surviving flags ARE in help.
    for visible in ("--no-availability", "--show-all", "--freecycle-only",
                    "--exclude-freecycle", "--guest-only", "--exclude-guest",
                    "--explain", "--pivot", "--no-json-help",
                    "--quick"):
        assert visible in rendered, f"expected {visible!r} in --help"

    # Better error messages: mem without unit + bad time + cores=0 + bad gpu spec.
    try:
        parse_shape_spec("a100:4,mem=99")
    except CommandError as exc:
        msg = str(exc)
        assert "mem" in msg and "unit" in msg, msg
        assert "16G" in msg, msg
    else:
        raise AssertionError("parse_shape_spec('a100:4,mem=99') should have raised")
    try:
        parse_shape_spec("cores=0")
    except CommandError as exc:
        assert "positive integer" in str(exc), str(exc)
    else:
        raise AssertionError("cores=0 should have raised")
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

    # _format_applied_filters captures only the surviving filter flags.
    a = parser_fmt.parse_args([])
    assert _format_applied_filters(a) == []
    a = parser_fmt.parse_args([
        "--cluster", "notchpeak", "--account", "foo",
        "--min-wall", "12:00:00",
    ])
    bits = _format_applied_filters(a)
    assert "cluster=notchpeak" in bits
    assert "account=foo" in bits
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
    amd_row = AllocationRow(
        "granite", "x", "u", "", "q-amd", "q-amd",
        cpu_features=("zen4",),
    )
    amd_row.gpu_types = ("h100nvl",)
    explain_rows = [a100_row, amd_row]
    explain_shapes = [
        ProbeShape(gpu_type="a100", gpu_count=1, time="01:00:00"),
        ProbeShape(gpu_type="h100", gpu_count=4, time="1-00:00:00"),
    ]
    a = parser_fmt.parse_args([])
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
    assert "#SBATCH --nodes=1" in best_text
    assert "#SBATCH --ntasks=1" in best_text
    assert "#SBATCH --gres=gpu:a100:1" in best_text
    assert "predicted wait: now" in best_text
    assert "1 alternative" in best_text and "drop --best" in best_text
    best_json = json.loads(best_output([(pivot_row, s_a1), (pivot_row, s_a4)], "json"))
    assert best_json["account"] == "research"
    assert best_json["qos"] == "q-piv"
    assert best_json["predicted_wait_seconds"] == 0
    assert best_json["alternatives"] == 1
    assert best_json["effective_partition"] == "q-piv"
    assert best_json["shape_label"] == "a100:1@1h"
    assert "#SBATCH --gres=gpu:a100:1" in best_json["sbatch_directives"]
    full_best_row = AllocationRow(
        "granite", "acct", "u", "", "granite-gpu-freecycle", "granite-gpu-freecycle"
    )
    full_best_row.tags = ("gpu",)
    full_best_row.gpu_types = ("h100nvl",)
    full_best_shape = ProbeShape(
        nodes=2,
        cpus=8,
        mem="32G",
        gpu_type="h100",
        gpu_count=4,
        time="24h",
        filter=HardwareFilter(cpu_vendor="amd"),
    )
    full_best_row.wait_by_shape = {full_best_shape.label: 0}
    full_best_text = best_output([(full_best_row, full_best_shape)], "text")
    assert "#SBATCH --clusters=granite" in full_best_text
    assert "#SBATCH --partition=granite-gpu" in full_best_text
    assert "#SBATCH --nodes=2" in full_best_text
    assert "#SBATCH --ntasks=8" in full_best_text
    assert "#SBATCH --time=1-00:00:00" in full_best_text
    assert "#SBATCH --mem=32G" in full_best_text
    assert "#SBATCH --gres=gpu:h100nvl:4" in full_best_text
    assert "#SBATCH --constraint=zen|nap|rom|mil|gen" in full_best_text
    guest_best_row = AllocationRow(
        "granite", "acct", "u", "", "granite-gpu-guest", "granite-gpu-guest"
    )
    guest_best_row.tags = ("gpu",)
    guest_best_text = best_output([(guest_best_row, ProbeShape())], "text")
    assert "#SBATCH --partition=granite-gpu-guest" in guest_best_text
    assert "#SBATCH --partition=granite-gpu\n" not in guest_best_text
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

    # --quick parses and produces the expected dest value.
    assert parser_fmt.parse_args(["--quick"]).quick is True

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
    assert "  --list-gpus" in inv_section, "--list-gpus not in Inventory group"

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


def _print_probe_banner(
    args: argparse.Namespace, shapes: Sequence["ProbeShape"]
) -> None:
    """Print a one-line 'Probing:' banner to stderr before probes run.

    Makes the chosen shape set visible upfront. Suppressed under --no-wait
    (no probe), --explain (it has its own plan output), and on non-TTY
    stderr unless --verbose is set.
    """
    if args.no_wait or args.explain or not shapes:
        return
    if not (args.verbose or sys.stderr.isatty()):
        return
    if len(shapes) == 1:
        body = f"single shape ({shapes[0].label})"
    else:
        labels = ", ".join(s.label for s in shapes[:4])
        if len(shapes) > 4:
            labels += f", +{len(shapes) - 4} more"
        body = f"multi-shape · {len(shapes)} shapes ({labels})"
    print(f"[chpc-allocs] Probing: {body}", file=sys.stderr)


def _maybe_emit_gpu_resolution_notice(
    pairs: List[Tuple["AllocationRow", Optional["ProbeShape"]]],
    verbose: bool,
) -> None:
    """Print a one-line stderr notice when a shape's literal `gpu_type` got
    resolved to a different per-row GRES name (e.g. 'h100' → 'h100nvl').

    Quiet when no resolution happened, when stderr isn't a TTY (and verbose
    is off), or when the user already typed the exact GRES name.
    """
    by_literal: Dict[str, Dict[str, Set[str]]] = {}
    for row, shape in pairs:
        if shape is None or not shape.gpu_type:
            continue
        if shape.gpu_type in row.gpu_types:
            continue
        resolved = shape.resolved_gpu_type(row)
        if not resolved or resolved == shape.gpu_type:
            continue
        by_literal.setdefault(shape.gpu_type, {}).setdefault(resolved, set()).add(
            f"{row.cluster}/{row.qos}"
        )
    if not by_literal:
        return
    if not (verbose or sys.stderr.isatty()):
        return
    for literal, mapping in by_literal.items():
        if len(mapping) == 1:
            resolved = next(iter(mapping))
            print(
                f"[chpc-allocs] note: {literal!r} resolved to {resolved!r} "
                f"for matching rows (use {resolved!r} to silence this).",
                file=sys.stderr,
            )
        else:
            parts = [
                f"{','.join(sorted(rows_set))}→{resolved}"
                for resolved, rows_set in mapping.items()
            ]
            print(
                f"[chpc-allocs] note: {literal!r} resolved to: {'; '.join(parts)}.",
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
    if args.quick:
        args.no_wait = True
        args.no_availability = True
        args.no_usage = True
    user_shapes = parse_shape_list(args.shape_pos) if args.shape_pos is not None else None
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

    if args.list_gpus:
        # Fetch features only when shapes carry CPU atoms — the second sinfo
        # call is the same cost as the existing --list-cpus path.
        feats = (
            show_partition_features()
            if user_shapes and any(s.filter.has_cpu_constraint() for s in user_shapes)
            else None
        )
        print(format_gpu_summary(
            show_partition_availability(),
            partition_features=feats,
            shapes=user_shapes,
        ))
        return 0
    if args.list_cpus:
        print(format_cpu_summary(
            show_partition_features(),
            show_partition_availability(),
            shapes=user_shapes,
        ))
        return 0

    include_avail = not args.no_availability
    include_wait = include_avail and not args.no_wait
    if include_wait and user_shapes is None:
        raise CommandError(
            "SHAPE_LIST is required to probe wait times\n"
            "  hint: pass a shape (e.g. 'a100:4', 'cpu:32@12h'), or "
            "use --quick / --no-wait to list allocations without probing"
        )

    user = os.environ.get("USER") or run_command(["id", "-un"]).strip()
    rows = show_associations(user=user, all_visible=args.all_visible)
    partition_avail = show_partition_availability() if include_avail else None
    # When availability data is loaded, derive the gpu-types map from it for
    # free (no second sinfo call) — needed by the 'premium' sort key so
    # a100/h100/h200/a6000 rows surface even without --wide.
    # Matches the shape show_partition_gpus returns.
    if partition_avail is not None:
        partition_gpus: Dict[str, Dict[str, Dict[str, int]]] = {
            c: {p: {g: tot for g, (_free, tot) in bucket.gpus.items()} for p, bucket in parts.items()}
            for c, parts in partition_avail.items()
        }
    elif args.wide:
        partition_gpus = show_partition_gpus()
    else:
        partition_gpus = {}
    # cpu_vendor classification feeds the 'vendor' sort key, so fetch features
    # unless we're skipping availability AND the user didn't ask for --wide.
    partition_features = (
        {} if args.no_availability and not args.wide
        else show_partition_features()
    )
    attach_metadata(
        rows,
        include_usage=(not args.no_usage and not args.all_visible),
        user=user,
        partition_gpus=partition_gpus,
        partition_features=partition_features,
        partition_avail=partition_avail,
        shapes=user_shapes,
    )
    rows = filter_rows(rows, args)
    rows = filter_rows_by_shapes(rows, user_shapes)
    shapes: List[ProbeShape] = list(user_shapes) if include_wait and user_shapes else []

    # --explain: print the resolved plan and exit before any probes run.
    if args.explain:
        explain_fmt = args.format if args.format in ("json",) else "text"
        print(render_explain_plan(rows, shapes, args, explain_fmt))
        return 0

    if include_wait:
        _print_probe_banner(args, shapes)
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
    else:
        show_gpus = any(s is not None and s.gpu_type for _, s in pairs)
        _maybe_emit_gpu_resolution_notice(pairs, args.verbose)
        if fmt == "csv":
            output = csv_output(
                pairs, wide,
                include_avail=include_avail, include_wait=include_wait,
                show_gpus=show_gpus,
            )
        elif fmt == "json":
            output = json_output(
                pairs, wide,
                include_avail=include_avail, include_wait=include_wait,
                include_help=not args.no_json_help,
                show_gpus=show_gpus,
            )
        else:
            output = table_output(
                pairs, wide,
                include_avail=include_avail, include_wait=include_wait,
                show_gpus=show_gpus,
            )

    print(output)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except CommandError as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(2)
