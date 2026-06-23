# Claude Code Skills Reference

Sources: [`ai/skills/`](../ai/skills/), wired by [`install.sh::link_claude_skills`](../install.sh).

Each subdirectory of [`ai/skills/`](../ai/skills/) is a [Claude Code skill](https://code.claude.com/docs/en/skills) — a folder containing a `SKILL.md` whose YAML frontmatter declares when Claude should load it. `install.sh` symlinks every skill directory into `~/.claude/skills/<name>` so that:

- The skill is available to every Claude Code session on the host.
- Edits to a `SKILL.md` in this repo are picked up immediately (Claude Code watches the skills directory).
- `deploy.sh` propagates the same skills to every remote host without extra setup — the symlinks point at the cloned repo's `ai/skills/`.

Skills are **symlinks**, not copies (unlike `~/.claude/settings.json` and `~/.codex/config.toml`). Skills are shared knowledge that should track the repo; settings need per-host overrides without dirtying the working tree.

## What's bundled

### HPC core

| Skill | Triggers on |
|---|---|
| [`chpc-job`](../ai/skills/chpc-job/SKILL.md) | CHPC end-to-end: find allocation (chpc-allocs), choose modules (compiler→MPI), write + submit sbatch on notchpeak/kingspeak/granite |
| [`slurm-job`](../ai/skills/slurm-job/SKILL.md) | sbatch, srun, squeue, sacct, job arrays, partitions, QoS, CHPC clusters |
| [`cuda-kernels`](../ai/skills/cuda-kernels/SKILL.md) | `.cu` / `.cuh` files, `__global__` / `__device__`, kernel launches, shared memory, warps, nvcc |
| [`gpu-profile`](../ai/skills/gpu-profile/SKILL.md) | nsys, ncu, nvprof, `.nsys-rep` / `.ncu-rep` reports, occupancy, roofline |
| [`python-profile`](../ai/skills/python-profile/SKILL.md) | cProfile, pyinstrument, py-spy, scalene, line_profiler, memray, tracemalloc, snakeviz, flame graphs |
| [`cpp-profile`](../ai/skills/cpp-profile/SKILL.md) | perf record/report/stat/annotate, callgrind, heaptrack, massif, HPCToolkit, Score-P, Tracy, flame graphs, frame pointers |
| [`mpi-openmp`](../ai/skills/mpi-openmp/SKILL.md) | MPI_*, ranks, communicators, deadlocks, `pragma omp`, `OMP_NUM_THREADS`, hybrid programming |
| [`scientific-io`](../ai/skills/scientific-io/SKILL.md) | HDF5, NetCDF, Zarr, parallel I/O, MPI-IO, chunking, Darshan |

### Distributed ML

| Skill | Triggers on |
|---|---|
| [`distributed-training`](../ai/skills/distributed-training/SKILL.md) | PyTorch DDP/FSDP, torchrun, NCCL, multi-node training, accelerate, deepspeed |

### Explanation style

| Skill | Triggers on |
|---|---|
| [`explain-concepts`](../ai/skills/explain-concepts/SKILL.md) | "explain X", "what is Y", "why does Z work", "intuition behind W" — governs how Claude explains HPC, CS, and math concepts (punchline first, intuition before formalism, defined notation, anchored claims) |

### Academic writing

| Skill | Triggers on |
|---|---|
| [`latex-paper`](../ai/skills/latex-paper/SKILL.md) | `.tex` files, latexmk, pdflatex, NeurIPS/ICML/IEEE/ACM templates, figures, math, citations |
| [`bibtex-fetch`](../ai/skills/bibtex-fetch/SKILL.md) | DOI, arXiv ID, `.bib`, BibTeX entries, citation auditing |
| [`paper-review`](../ai/skills/paper-review/SKILL.md) | drafting reviewer comments, scoring rubrics, critiquing a draft, reproducibility checks |
| [`technical-writing`](../ai/skills/technical-writing/SKILL.md) | READMEs, docs, paper sections, blog posts, markdown style, active voice, AI-tell removal |
| [`reply-style`](../ai/skills/reply-style/SKILL.md) | Assistant-side counterpart to `technical-writing` — governs Claude's own conversational tone: brief, AmE, no AI-tells, no idioms or sports metaphors, single verbs over phrasal verbs |

Skills cross-link (`[[other-name]]`) so chaining several stays cheap — invoking `cuda-kernels` reminds Claude that `gpu-profile` exists for the optimization phase. The style triad `reply-style` ↔ `explain-concepts` ↔ `technical-writing` works the same way: each defers to the others rather than restating shared rules.

## How skills are discovered

When you type `/` in Claude Code, all enabled skills appear in the menu. When you ask a question, Claude reads each skill's `description` (always in context, ~one line per skill) and loads the body only when the description matches your request. Bodies stay in context for the rest of the session after they're loaded.

To list skills explicitly:

```bash
ls -l ~/.claude/skills/         # → 10 symlinks into ai/skills/
```

To force-invoke a skill:

```
/slurm-job
```

## Authoring a new skill

1. Create `ai/skills/<name>/SKILL.md` with frontmatter (`name`, `description`, optionally `when_to_use`, `allowed-tools`) plus markdown body. Keep the body under 500 lines per Claude Code guidance; move bulky reference material to `ai/skills/<name>/references/*.md` if needed.
2. Re-run `./install.sh` (or just `./install.sh --dry-run` to preview). The new directory gets symlinked automatically; existing skills are idempotent.
3. `scripts/test_regressions.sh` validates that every `SKILL.md` has the required frontmatter fields, that `name:` matches its directory, and that `description:` is non-empty.

Use the existing skills as templates — particularly [`slurm-job`](../ai/skills/slurm-job/SKILL.md) for "knowledge with command examples" or [`paper-review`](../ai/skills/paper-review/SKILL.md) for "prompt-style guidance with no code."

## Upstream skills (cloned at install time)

In addition to the in-tree skills under `ai/skills/`, [`scripts/install_claude_skills.sh`](../scripts/install_claude_skills.sh) clones two upstream skill repos to `~/.local/share/claude-skills/` and symlinks a curated set into `~/.claude/skills/` alongside the custom ones. They appear under their natural names (e.g. `/systematic-debugging`, not `/superpowers:systematic-debugging`).

The cache and symlinks are refreshed on every `./install.sh` run; pass `--force` to re-clone from upstream.

### From [obra/superpowers](https://github.com/obra/superpowers) (Jesse Vincent)

Engineering-process skills, pure markdown, MIT licensed.

| Skill | What it covers |
|---|---|
| `systematic-debugging` | Four-phase root-cause investigation: reproduce → isolate → fix → verify |
| `test-driven-development` | RED-GREEN-REFACTOR cycle, when to write the test first |
| `using-git-worktrees` | Parallel branches via worktrees; avoids stash juggling |
| `writing-plans` | How to draft an implementation plan worth executing |
| `executing-plans` | Following a plan step-by-step; handling drift mid-execution |
| `verification-before-completion` | Don't claim "done" without running it; what verification looks like |
| `brainstorming` | Structured idea generation: divergent then convergent |

### From [anthropics/skills](https://github.com/anthropics/skills) — markdown-only

Official Anthropic skills with no external dependencies.

| Skill | What it covers |
|---|---|
| `skill-creator` | Guided authoring of new skill folders + scripts |
| `mcp-builder` | Building MCP servers (stdio, sse, HTTP) with proper schema |
| `doc-coauthoring` | Multi-pass document drafting with structured revision |
| `brand-guidelines` | Applying a brand style guide to generated content |

`claude-api` (also in the Anthropic repo) is intentionally **not** symlinked — Claude Code already ships it as a bundled skill in every session.

### From [anthropics/skills](https://github.com/anthropics/skills) — document creators

One Office/PDF skill is included; the bundled script uses `uv run --with <package>` to fetch Python deps on first invocation, so no `pip install` step is needed at install time. `uv` is wired in by the main `install.sh`.

| Skill | What it covers | First-use deps |
|---|---|---|
| `pdf` | Read, extract, split, merge PDF files | `pypdf`, `reportlab` |

## Related plugin (installed by `scripts/install_claude_plugins.sh`)

- **[context7](https://github.com/upstash/context7)** (marketplace plugin) — live API documentation lookup (PyTorch, NumPy, MPI, CUDA, …). Ships its own skill + `/context7:docs` command + a `docs-researcher` subagent.

## Not included

- **Other `obra/superpowers` skills** — `requesting-code-review`, `receiving-code-review`, `finishing-a-development-branch`, `subagent-driven-development`, `dispatching-parallel-agents`, `writing-skills`. Available in the upstream repo if needed; add the name back to `SUPERPOWERS_SKILLS` in [`scripts/install_claude_skills.sh`](../scripts/install_claude_skills.sh).
- **Other `anthropics/skills` document creators** — `xlsx`, `docx`, `pptx`. Add to `ANTHROPIC_SKILLS_PYDEPS` if needed.
- **`anthropics/skills` heavy-deps skills** — `webapp-testing` (Playwright), `slack-gif-creator` (`requirements.txt`), `algorithmic-art` / `canvas-design` / `theme-factory` / `frontend-design` / `internal-comms` / `claude-api` (already bundled).
- **`anthropics/skills` `using-superpowers`** — meta-readme, not actionable as a skill.
- **Project-level skills** (`.claude/skills/` in this repo) — bundled skills are user-level so they apply to every project.

## Related

- [Anthropic skill spec](https://code.claude.com/docs/en/skills) — full frontmatter reference (invocation control, `allowed-tools`, subagent execution).
- [`docs/ai-tools.md`](ai-tools.md) — Claude Code settings, Codex config, MCP servers.
