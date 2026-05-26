---
name: paper-review
description: Use when the user is reviewing a research paper — drafting reviewer comments, scoring along NeurIPS/ICML/conference rubrics, critiquing a draft, identifying weaknesses in claims/experiments/related work, or checking reproducibility.
---

# Paper review

Apply when the user wants Claude to act as a reviewer (their own draft or
someone else's), or is integrating reviewer feedback.

## Reviewer mental model

You are a **knowledgeable peer**, not the authors' adversary or their
cheerleader. The goal is to help the reader decide:

1. Is the claim true? (Technical soundness)
2. Is the claim significant? (Novelty + impact)
3. Is the paper clear enough that someone could build on it?

If the answer to any of these is "no", say so concretely and propose what
would change your mind.

## Five-axis rubric (NeurIPS-style)

Score 1-10 on each. Most papers should land 4-7; reserve 8-10 and 1-3 for
genuine outliers. Always pair the number with one sentence of justification.

| Axis | What it measures | Common failure modes |
|---|---|---|
| **Soundness** | Are the technical claims correct? | Math errors, missing assumptions, statistical artifacts misread as effects |
| **Novelty** | What is genuinely new? | Reframes prior work, marginal delta over existing baselines |
| **Significance** | Does this matter to the field? | Toy domain, doesn't transfer, no one will read this in 2 years |
| **Clarity** | Could a careful reader reproduce this? | Missing hyperparameters, ambiguous notation, key figures unlabeled |
| **Experiments** | Do the experiments support the claims? | Single seed, missing ablations, unfair baseline tuning, wrong benchmark |

## Review structure (use this template)

```markdown
## Summary
[2-3 sentences: what the paper does, in your own words, not theirs. Forces
you to verify you actually understood the contribution.]

## Strengths
- [Specific, e.g.: "The orthogonal-projection ablation in Table 3 cleanly
  isolates the gain from the new regularizer."]
- [...]

## Weaknesses
- [Specific, ranked by severity. Lead with the most consequential.]
- [...]

## Questions for the authors
- [Each one should be actionable in a rebuttal. "Could you clarify X?",
  "Why was Y chosen over Z?", "Does the result hold for W?"]

## Detailed comments
- §3.2, paragraph 2: notation collides with §2.1
- Figure 4: missing legend; what does the dashed line represent?
- [Page/section-anchored. These are revision requests, not blocking issues.]

## Recommendation
[Accept / Weak accept / Borderline / Weak reject / Reject — venue-specific —
with one sentence on the deciding factor.]
```

## Common failure modes by paper type

### ML / empirical

- **Single-seed results**: ask for ≥3 seeds with std bars; on small effects,
  insist on a significance test.
- **Cherry-picked hyperparameters**: if the baseline used the original
  paper's HPs and the proposed method got a sweep, the comparison is unfair.
  Ask for matched HP search budgets.
- **Missing ablation**: each new architectural piece needs to be removed in
  isolation. "Method A+B+C beats baseline" is uninformative without A, B, C
  alone.
- **Wrong benchmark**: SOTA on CIFAR-10 in 2026 is borderline-meaningless;
  ask for ImageNet-1k or a domain-relevant benchmark.
- **Train-test contamination**: when scraping web data, did the eval set
  leak into training? Verify the de-dup protocol.

### Systems / HPC

- **Speedup on one node ≠ scaling**: ask for strong and weak scaling plots,
  ≥4 node counts, efficiency on the y-axis.
- **Hardware mismatch**: A100 vs V100 baseline; insist on same-hardware
  comparison or a clear normalization.
- **No comparison to the obvious baseline**: e.g., a new training optimizer
  that doesn't compare to AdamW; a new I/O scheme without comparing to
  parallel HDF5.
- **Microbenchmark only**: synthetic kernel speedup without an end-to-end
  app result.
- **Missing roofline / arithmetic-intensity discussion**: claims of
  efficiency need to land on a roofline.

### Theory

- **Restrictive assumptions buried**: read every "Assume…" and ask whether
  any of them are violated by the empirical setup they motivate the result
  with.
- **Tight vs loose bounds**: is the bound non-vacuous on realistic problem
  sizes? A bound that's $O(\sqrt{n})$ but $10^{10}$ at $n=100$ is unhelpful.
- **Asymptotic ≠ practical**: $\tilde{O}(n)$ with a giant constant; ask for
  wall-clock numbers.

## Reviewing your own draft

The strongest technique: read the paper end-to-end as if you'd never seen
it. Make notes only on things that confuse you on first reading — those are
real defects, not "I knew what I meant" defects. Then:

1. List what a hostile reviewer would say.
2. For each, either fix the paper or write a rebuttal sentence.
3. The ones you can't fix and can't defend are your honest weaknesses;
   surface them in the limitations section, don't bury them.

## What good reviewer comments look like

- **Bad**: "The novelty is limited."
- **Good**: "The proposed loss is a re-parameterization of the contrastive
  loss in Chen et al. (2020, eq. 4) under temperature → 0. The empirical
  gain in Table 2 (1.3%) is within the noise envelope of the seeds reported
  by Chen et al. Could the authors clarify the relationship?"

The good version is **specific**, **citable**, **falsifiable** by the
authors, and **scoped to the actual concern**.

## See also

- [[latex-paper]] when you'll be revising the draft based on the review
- [[bibtex-fetch]] when verifying that cited works exist and say what the
  authors claim
- [[technical-writing]] for prose-level critique
