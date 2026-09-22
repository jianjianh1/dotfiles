---
name: research-project
description: Carry a computational research question through source review, hypothesis design, budgeted experiments, analysis, and a cited report. Use when the user wants new empirical results; use research-brief for literature-only investigations.
---

# Computational research project

Use this skill when the user wants original computational evidence, such as a
software benchmark, ML experiment, or HPC study. Deliver a cited Markdown
report and reproducible project artifacts unless the user asks for another
format. Follow the project's existing layout; otherwise keep `plan.md`,
`sources.md`, `experiments.tsv`, and `report.md` in
`research-runs/<YYYY-MM-DD>-<topic>/`. If changing an existing codebase, use
an isolated worktree and leave the user's checkout intact. Keep large
datasets, checkpoints, and temporary outputs out of Git.

## Scope and budget

1. Turn the question into a testable claim and identify the project, data,
   available compute, and deliverable. Record the scope and budget in
   `plan.md`. If the user already supplied a usable budget, start the workflow
   without seeking phase-by-phase approval.
2. Before launching experiments, establish a limit for the resources they
   will consume: wall time or compute allocation, and any paid experiment API
   spend. If no usable limit was supplied, complete the source review and
   experiment design, then ask once for a budget. Do not launch a job while
   its relevant limit is unknown. Treat paid experiment APIs as unavailable
   unless the user includes a spending limit.
3. Before each run, check that its worst-case allocation fits the remaining
   budget. Bound local commands with a timeout and cluster jobs with scheduler
   walltime and resource requests. Record both reserved and actual use; stop
   when the budget or the plan's stopping rule is reached. If a tool cannot
   bound or measure a proposed expense, use a bounded alternative or leave it
   out of the experiment.

## Sources and design

1. Search current literature with OpenAlex and native web tools. Follow
   citation trails and open accessible papers or other primary sources before
   relying on their results. OpenAlex metadata and abstracts help discovery;
   they do not establish a paper's findings. Use [[bibtex-fetch]] to check
   DOI and citation details. In `sources.md`, record each source's link,
   version or date, supported claim, and full-text access status.
   If OpenAlex is unavailable, use available web sources and Crossref, and
   state which checks were unavailable.
2. Record the hypothesis, comparison baseline, dataset and version, evaluation
   metric, procedure, and stopping rule before running code. Identify data
   splits, seeds, and controls where they affect the claim. If the proposed
   comparison cannot answer the question, revise the plan before spending
   compute.

## Experiments and analysis

1. Run the baseline first, then bounded comparisons. Use CHPC when it is
   reachable, has a suitable allocation, and fits the budget; otherwise use
   local compute when feasible. Reuse [[chpc-job]] for CHPC allocation and
   submission, or [[slurm-job]] for other clusters. Never run compute on a
   CHPC login node. Monitor submitted jobs and record their IDs so work can
   resume after a session interruption.
2. Keep `experiments.tsv` as a durable ledger with each run's hypothesis or
   change, code revision, command and configuration, data version, seed,
   hardware, status, metrics, runtime, resource use, and log path. Preserve
   failed and negative runs. Capture a patch or commit for code used in each
   reported result; do not reset or overwrite the user's work.
3. Analyze the runs against the stated metric. Repeat or check variability
   when the budget permits; otherwise state that the result is preliminary.
   Separate observed results from explanations and do not select only the
   favorable runs. If tools, sources, or experiments fail, record the gap and
   continue with what remains feasible inside the budget.

## Report and handoff

Write `report.md` beside the run plan, source record, experiment ledger, code,
figures, and logs. Lead with the answer, then describe prior work, methods,
all relevant results, uncertainty, limitations, compute used, and exact
reproduction commands. Link each literature claim to a checked source and
each empirical claim to a run or figure. Audit the report against the recorded
evidence before presenting it. If the run ends early, deliver a clearly
labeled partial report and the next reproducible step. Use [[latex-paper]]
only when the user requests a paper; do not publish or upload the work unless
asked.
