---
name: explain-concepts
description: Use when the user asks Claude to explain a concept — phrasings include "explain X", "what is Y", "why does Z work", "intuition behind W", "I'm learning about V", "walk me through R", "how does Q work under the hood". Governs how Claude explains HPC, CS, and math concepts: punchline first, intuition before formalism, notation defined before use, abstractions anchored to hardware or geometry. Sibling to [[reply-style]] (overall reply tone) and [[technical-writing]] (prose the user is writing). Does not duplicate domain skills (slurm-job, cuda-kernels, mpi-openmp, scientific-io, gpu-profile, distributed-training).
---

# Explain concepts

Apply when the user asks Claude to explain an HPC, CS, or math concept —
"explain X", "what is Y", "why does Z work", "intuition behind W". Audience
is graduate-student level in scientific computing: calculus, basic linear
algebra, and intro CS are assumed; advanced topics are built up from first
principles.

Sibling to [[reply-style]] (overall reply tone) and [[technical-writing]]
(prose the user is editing). This skill governs the *structure* of an
explanation. Brevity, AmE, and no-AI-tells carry over from those skills
without restating.

## Lead with the punchline

State the one-sentence "what is it" before any setup. The first sentence
of an explanation is what the reader remembers if they stop after the
first sentence.

| Worse | Better |
|---|---|
| "An eigenvector is a vector that, when a linear transformation is applied, results in a scalar multiple of itself…" | "An eigenvector is a direction the matrix only stretches, never rotates." |
| "The roofline model is a visual performance model that relates achievable performance to arithmetic intensity and peak hardware capabilities…" | "Roofline says: your kernel is either compute-bound or bandwidth-bound, and which one depends on FLOPs per byte." |

When the explanation is one sentence, the reply is one sentence.

## Build intuition before formalism

Concrete example, then general rule, then notation — in that order. The
formula is the compressed form of the intuition; uncompressing it is the
reader's job, not the start of yours.

- Show numbers on a small case before symbols on the general case.
- Show n = 2 before n.
- Show one rank before many ranks; one block before a grid.
- Skip the degenerate n = 1 case — it hides the structure.

## Anchor abstractions to physical reality

Every abstraction maps to something the reader can point at. Name it.

- **HPC** — anchor to hardware. "Shared memory is fast because it lives
  on the SM, one hop from the ALU. Global memory is slow because every
  load crosses the memory controller."
- **CS** — anchor to the machine model. Say which model: RAM, external
  memory, PRAM, message passing. "Quicksort is `O(n log n)` *comparisons*
  in the RAM model — not wall-clock time, not cache misses."
- **Math** — anchor to geometry or a small numerical example. "A
  positive-definite matrix is one where `x^T A x > 0` for any nonzero
  `x` — geometrically, the quadratic form is a bowl pointing up."

## Define notation before using it

Every symbol gets a name, a type, and a physical meaning the first time
it appears. Undefined notation is the top cause of skimmed-over
explanations.

| Worse | Better |
|---|---|
| "Let `A` be a matrix and `x` a vector." | "Let `A` be an `n×n` symmetric matrix (the system's stiffness), and `x` an `n`-vector (the displacements)." |
| "Define `T_p` as the parallel time." | "Define `T_p` as the wall-clock time on `p` ranks, in seconds." |

If a symbol carries units, state the units. If a function has a type,
state the type.

## Show the simplest non-trivial case first

The smallest case that still exhibits the structure. Examples:

- Ring-allreduce: draw three GPUs, not two (two is just a swap), not
  eight (the picture stops fitting).
- Cache-oblivious matrix multiply: a 4×4 problem with a 2×2 base case.
- Gradient descent: a 2D quadratic with elliptical contours, not 1D.

After the small case lands, generalize. The reader can now check the
general claim against a case they understand.

## Distinguish what, why, and how

Three labeled answers per concept. Mixing them is the source of most
muddled explanations.

- **What** — the definition or interface. *What is a cache-oblivious
  algorithm?* A recursive algorithm that matches no specific cache size.
- **Why** — the reason it exists or works. *Why does it matter?* It is
  optimal across every level of the cache hierarchy at once, without
  tuning.
- **How** — the mechanism. *How does it achieve that?* Divide-and-conquer
  down to a base case; the recursion eventually fits whichever cache
  level you care about.

When the user asks "what", do not lead with "how". When they ask "why",
do not lead with "what".

## Pick the right representation

Match the representation to the kind of claim.

| Claim type | Representation |
|---|---|
| Control flow, algorithm | Pseudocode or short code block |
| Geometric or spatial | ASCII diagram or sketch |
| Algebraic identity | Math notation (inline `$…$` or display) |
| Trade-off or design choice | Prose, with a two-column table for the comparison |
| Performance bound | Roofline-style plot in prose, or a formula with units |

Picking the wrong representation buries the answer. A control-flow claim
written in prose reads as hand-waving; a geometric claim written in math
notation reads as opaque.

## Common failure modes

- **Hand-waving.** "Intuitively, this just works." Replace with the step
  you skipped, or cite the source that proves it.
- **Naming before defining.** Using `FSDP` or `roofline` in the first
  sentence without a 4–6 word gloss. Define then use.
- **Burying the lede.** Two paragraphs of motivation before the
  definition. Put the punchline first; move motivation after.
- **Formula dump.** Three equations with no prose. Each equation needs a
  one-line gloss naming what it computes and why.
- **False precision.** "`O(n log n)`" without naming which operation is
  counted. "Twice as fast" without naming the baseline. Unitless numbers
  read as authoritative but say nothing.

## Citation discipline

Load-bearing claims get an anchor — a paper, a spec, or a hardware
whitepaper. Defer the full table of canonical sources to
[[technical-writing]] (section "Anchor citations for HPC/ML claims").
Three high-frequency examples:

- Roofline model → Williams, Waterman & Patterson, CACM 2009.
- Ring-allreduce bandwidth-optimality → Patarasuk & Yuan, JPDC 2009.
- Cache-oblivious algorithms → Frigo, Leiserson, Prokop & Ramachandran,
  FOCS 1999.

Citations live in the explanation, not in a separate "references"
section at the end — the reader checks the source where the claim
appears.

## Domain patterns

### HPC

Hardware intuition first, then the scaling claim. Order: what the
hardware does, why a naive algorithm hits a wall on it, what the
better algorithm does instead.

- Always distinguish strong scaling (fixed problem, more ranks) from
  weak scaling (problem grows with ranks). A claim of "scales to 1024
  GPUs" is meaningless without one of the two.
- Name the bottleneck: bandwidth, latency, occupancy, synchronization,
  or load imbalance. "Slow" alone is not a diagnosis.

### CS

State the machine model, then the asymptotic. Asymptotic complexity is
unitless; name the operation counted.

- "`O(n log n)` comparisons" — compares.
- "`O(n)` cache misses" — misses in the external-memory model.
- "`O(log p)` rounds" — communication rounds in the PRAM or BSP model.

Without the operation, the bound is decorative.

### Math

Low-dim case, then the picture, then the algebraic generalization.

- Name the symbol types: scalar (`α`), vector (`x`), matrix (`A`),
  operator (`T`). Mixing the levels confuses the reader.
- When a proof reduces to a one-line algebraic step, show the step.
  When it does not, say which technique it uses (induction, contradiction,
  pigeonhole) and cite the source.

## Worked rewrites

**Roofline model.**

- Before: "The roofline model relates arithmetic intensity to performance
  via a piecewise-linear bound combining peak FLOP/s and peak bandwidth."
- After: "Roofline says: your kernel is either compute-bound or
  bandwidth-bound, and which one depends on FLOPs per byte. Plot
  performance vs. FLOPs per byte; the ceiling is two lines that meet at
  the ridge point. Below the ridge, more cache reuse helps; above it,
  only more FLOPs help. (Williams et al., 2009.)"

**NCCL ring-allreduce.**

- Before: "Ring-allreduce achieves bandwidth-optimal collective reduction
  with `2(p-1)N/p` bytes per rank."
- After: "Ring-allreduce sends each rank's chunk around a ring of GPUs,
  accumulating as it goes. With `p` ranks and message size `N` bytes,
  each rank sends roughly `2N` bytes — independent of `p` for large `p`.
  The picture is a circle of GPUs; the math is just bookkeeping on that
  circle. (Patarasuk & Yuan, 2009.)"

**Lagrange multipliers.**

- Before: "At a constrained optimum, `∇f = λ∇g` where `g(x) = 0`."
- After: "At a constrained optimum, the gradient of `f` points along the
  gradient of the constraint — you cannot move along the constraint
  surface and still increase `f`. The multiplier `λ` is the exchange
  rate: how much `f` changes per unit relaxation of the constraint.
  Draw the level sets of `f` tangent to the surface `g = 0`."

## What this skill does not do

- **Does not restate [[reply-style]] rules.** AmE, no AI-tells, brief
  replies, no idioms, no phrasal verbs for prose — those still apply.
  This skill adds explanation structure on top.
- **Does not dump domain knowledge.** When the question is "write an
  `sbatch` script", [[slurm-job]] loads; this skill governs how the
  surrounding explanation reads, not the script itself.
- **Does not generate tutorials, course notes, or lecture handouts.**
  A reply is still a reply — one concept, graduate-student depth,
  bounded length. For multi-section docs use [[doc-coauthoring]].

## See also

- [[reply-style]] — overall conversational tone; carries over verbatim.
- [[technical-writing]] — prose the user is editing; full citation table
  for HPC/ML claims lives there.
- [[paper-review]] — critiquing someone else's explanation in a draft.
- Domain skills the explanation may sit beside: [[slurm-job]],
  [[cuda-kernels]], [[mpi-openmp]], [[scientific-io]], [[gpu-profile]],
  [[distributed-training]].
