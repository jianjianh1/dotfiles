---
name: technical-writing
description: Use when the user is writing or editing prose — README, docs, paper sections, blog posts, talk abstracts, technical reports, markdown documents. Enforces American English (spelling, Oxford comma, em-dash use), strips AI-tells, and anchors HPC/ML claims to canonical papers. Cross-cuts academic writing (with [[latex-paper]]) and code documentation.
---

# Technical writing & markdown style

Apply to any prose the user is generating, editing, or asking feedback on.
Cross-cuts academic writing (with [[latex-paper]]) and code documentation.

## Default to short, declarative, active voice

| Worse | Better |
|---|---|
| "It can be observed that the latency was reduced." | "Latency dropped 40%." |
| "We perform an evaluation of the method." | "We evaluate the method." |
| "In order to address this issue, we propose…" | "We propose…" |
| "This is a method that allows…" | "This method allows…" |
| "It should be noted that X is also true." | "X is also true." |

Active voice is shorter, attributes responsibility, and is easier to scan.
Passive is appropriate when the actor is unknown, irrelevant, or the topic
is the object ("The samples were stored at 4°C" in a methods section).

## Concision: cut 30% on the second pass

Edit by deletion. A draft is overlong because writing-to-think emits filler.
Lines that almost always cost more than they earn:

- "It is important to note that …" → start with the note
- "As mentioned previously …" → trust the reader's memory or restructure
- "very", "really", "actually", "quite", "rather" — most can go
- "in order to" → "to"
- "due to the fact that" → "because"
- "a number of" → "several" or the actual number

The 30% rule: after the first draft, count words; the second draft should be
30% shorter without losing content.

## Structure: lead with the answer

For docs, READMEs, abstracts, and PR descriptions, the **first paragraph
states the result**. Everything after is justification.

```markdown
# tool-x

`tool-x` rewrites stale config files in place. It runs in ~50ms on a
laptop and is safe to invoke from a pre-commit hook.

## Install
…
```

Not: "Configuration files often go stale. Many tools exist to address
this, but they have limitations. In this work, we introduce tool-x…"

Same for paper abstracts: claim first, motivation second.

## Spelling & punctuation: American English

Default to **American English** for all output unless the surrounding document is
clearly British (e.g., a paper for an Oxford collaborator, or `.tex` files where
prior content uses `colour`). When in doubt, match the existing document; when
starting fresh, use AmE.

| British | American |
|---|---|
| colour, behaviour, neighbour | color, behavior, neighbor |
| optimise, analyse, parameterise | optimize, analyze, parameterize |
| modelling, labelled, cancelled | modeling, labeled, canceled |
| centre, metre, fibre | center, meter, fiber |
| catalogue, dialogue, analogue | catalog, dialog, analog |
| organisation, generalisation | organization, generalization |
| whilst, amongst, learnt | while, among, learned |
| aluminium, sulphur | aluminum, sulfur |
| programme (noun) | program |

Other conventions:

- **Oxford (serial) comma** in lists of 3+: "MPI, OpenMP, and CUDA" — not
  "MPI, OpenMP and CUDA". Disambiguation matters in technical prose where
  the last item is often the operative one.
- **Straight quotes** (`"` `'`) in code, identifiers, paths, and shell snippets.
  Smart quotes ("…") only in body prose, and only if the rendering target supports them.
- **Em-dash** with no surrounding spaces: `word—word`. Not `word — word` (that's
  a journalistic convention) and not `word -- word` (LaTeX raw; render it).
- **En-dash** for ranges: `pp. 41–58`, `2019–2024`, `Algorithm 3–5`.
- **Dates as ISO-8601** when machine-readable (`2026-05-26`); spelled-out month
  for prose ("May 26, 2026" — AmE order, not "26 May 2026").
- **Times in 24h** for logs, schedules, and SLURM walltime; 12h with `a.m./p.m.`
  (lowercase, periods) in body prose.
- **Number style**: spell out zero through nine in prose; use digits for ten and
  above, and always for measurements (`8 GPUs`, `3 ns`, `1.5 GiB`). Hard rule:
  never start a sentence with a digit — rewrite or spell out.
- **Units with non-breaking space** in LaTeX (`8\,GB`) or a regular space in
  markdown (`8 GB`). Use SI/binary correctly: `GB` = 10⁹ bytes, `GiB` = 2³⁰.

## Removing AI-tells

LLM-generated prose has a signature. The 2025-26 tells are not the same as
the 2023 tells — strip both.

**Diction tells** — statistically over-represented words that flag generated prose:

- `delve`, `delve into`, `delve deeper`
- `leverage` (as a verb), `harness`, `unlock`, `elevate`, `empower`
- `elucidate`, `illuminate`, `shed light on`
- `intricate`, `nuanced`, `multifaceted`, `comprehensive`, `holistic`, `robust`
- `seamless`, `seamlessly`, `effortless`, `meticulous`, `meticulously`
- `underscore`, `underpin`, `navigate the complexities`
- `tapestry`, `landscape`, `realm`, `journey`, `ecosystem` (in non-software contexts)
- `paradigm`, `paradigm shift`
- `at its core`, `in essence`, `fundamentally speaking`
- `in today's fast-paced world`, `in this digital age`

None are wrong in isolation — banned because their frequency in LLM output is
~10× human baseline. If you reach for one, pause and pick a domain-specific verb.

**Structural tells** — sentence shapes that read as generated:

- **Preambles**: "It's important to note that…" / "It's worth mentioning…" /
  "One key consideration is…" → delete the preamble, keep the noun.
- **"Not just X, it's Y"** frame: "This isn't just an optimization — it's a
  rethinking of memory access patterns." → "This rethinks memory access patterns."
- **Tricolons of vague adjectives**: "fast, scalable, and reliable" /
  "simple, flexible, and powerful". Pick one and prove it.
- **"Whether you're A or B, X has you covered."** Banned outright in docs.
- **Cheerful closing paragraphs**: "In conclusion, by combining these
  techniques…" / "Ultimately, this approach…" — end on the last substantive
  sentence and stop.
- **Hedge stacks**: "may potentially be able to" → "can". "It is possible that
  this might" → "this might".
- **Transition word peppering**: `Moreover`, `Furthermore`, `Additionally`,
  `Notably` opening every other paragraph. Use at most one per page, only
  when the logical link is actually adversative or additive.
- **"Let's dive in" / "Let's explore" / "Let's take a closer look"** — drop.
- **"I hope this helps!" / "Feel free to…" / "Certainly!" / "Absolutely!"** —
  chat-assistant residue; never appears in shipped docs.
- **Em-dash overuse** — one or two per page is fine; one per paragraph is not.
- **Bold-bulleting everything** — bold the term being defined, then plain prose.
  Bullet lists where every item starts with `**Bold thing**: …` look generated.
- **Emoji in technical prose** — none unless the user explicitly asked.

**The "would a human in this field write this?" test**: read the sentence
aloud. If it sounds like a Wikipedia lede but the content is technical, or
like a LinkedIn post but the content is research, rewrite.

**Concrete rewrites:**

| AI-tell | Rewrite |
|---|---|
| "Let's delve into the intricate world of NCCL collectives." | "NCCL implements MPI-style collectives over NVLink and InfiniBand." |
| "This robust, comprehensive framework empowers researchers to seamlessly scale." | "This framework scales from one to 1024 GPUs without code changes." |
| "It's worth noting that FlashAttention reduces memory by recomputing." | "FlashAttention reduces memory by recomputing the softmax in tiles." |
| "In the ever-evolving landscape of distributed training, ZeRO has emerged as a paradigm shift." | "ZeRO partitions optimizer state across ranks; for 13B+ models it is the standard." |

## Markdown conventions

````markdown
# H1 — only once per doc (the title)
## H2 — major sections
### H3 — subsections; avoid going deeper

**bold** for the first appearance of a defined term.
*italic* for emphasis; use sparingly — overused italic loses force.
`code` for identifiers, paths, flags, commands.

`code blocks` for anything ≥1 line OR with shell prompts:

    $ tool-x --flag value
    output line 1
    output line 2

Tagged fences for syntax highlighting:

```bash
echo "hi"
```

> Blockquote for cited material or important asides. Don't use it for
> general emphasis — that's what bold/italic are for.
````

Tables for genuinely tabular data (≥2 dimensions). For a 1-D list, use a
bullet list.

## Code blocks

- **Always tag the language**: ` ```bash `, ` ```python `, ` ```c++ `.
  Untagged blocks render plain and skip highlighting.
- **Strip the prompt for copy-paste blocks** (` $ ls ` becomes `ls`). Add the
  `$` only when output is shown interleaved, to distinguish input from output.
- **Show the output** when behavior is the point; **omit it** when the
  command itself is the point.
- **Don't paste 200-line files** — show the diff, the changed function, or
  link to the source. Long code blocks lose readers.

## Hyperlinks

- Inline links over reference-style for short docs: `[Crossref](https://www.crossref.org/)`.
- Reference-style `[Crossref][1]` … `[1]: https://…` is better in long
  documents where the URLs are reused or distract from the prose.
- **Never link bare words** like "click [here](…)"; link the thing the user
  is going to.
- For academic prose, use `\citep{}` / `\citet{}` in LaTeX; reserve inline
  hyperlinks for blog/web targets.

## Anchor citations for HPC/ML claims

When prose makes a load-bearing claim about a method, model, or system, cite
the canonical source rather than paraphrasing it as common knowledge. Fetching
BibTeX is `[[bibtex-fetch]]`'s job; *deciding what to cite* is this section's.

| Claim about… | Cite |
|---|---|
| Roofline performance model | Williams, Waterman & Patterson, *Roofline: An Insightful Visual Performance Model*, CACM 2009 |
| Strong vs weak scaling | Amdahl 1967 (strong); Gustafson 1988 (weak) |
| MPI semantics, collectives | MPI Standard 4.1 (2023) — cite the standard, not a tutorial |
| OpenMP semantics, pragmas | OpenMP API Specification 5.2 (2021) |
| NCCL collectives over NVLink/IB | Jeaugey, *Optimized Inter-GPU Collective Operations with NCCL*, GTC 2017 (no peer-reviewed paper; cite NVIDIA tech report) |
| Megatron-LM tensor/pipeline parallelism | Shoeybi et al., *Megatron-LM*, arXiv:1909.08053 (2019); Narayanan et al., SC '21 for the pipeline schedule |
| ZeRO / DeepSpeed memory partitioning | Rajbhandari et al., *ZeRO*, SC '20; Rasley et al., *DeepSpeed*, KDD '20 |
| FSDP | Zhao et al., *PyTorch FSDP*, VLDB '23 |
| FlashAttention / FlashAttention-2 | Dao et al., NeurIPS '22; Dao, ICLR '24 |
| Mixed-precision / bf16 training | Micikevicius et al., ICLR '18; Kalamkar et al., arXiv:1905.12322 (bf16) |
| Transformer architecture | Vaswani et al., *Attention Is All You Need*, NeurIPS '17 |
| GPU architecture details | NVIDIA H100/Hopper, A100/Ampere whitepapers — cite the whitepaper, not a blog post |
| Parallel I/O patterns | Lofstead et al. on ADIOS; HDF5 / NetCDF user guides; Carns et al., *Darshan*, SC '11 |
| LINPACK / Top500 / Green500 | Dongarra et al.; the current list URL with an access date |
| SLURM scheduling | Yoo, Jette & Grondona, *SLURM: Simple Linux Utility for Resource Management*, JSSPP '03 |

Two rules:

- **Cite primary sources, not blogs.** Vendor whitepapers and conference
  papers beat Medium articles. If only a blog exists (e.g., the original
  NCCL announcement), say so in a footnote.
- **Defer to the spec when one exists.** "MPI_Allreduce is collective" cites
  the MPI standard, not a textbook chapter that paraphrases it.

For fetching the actual BibTeX and managing `references.bib`, see
[[bibtex-fetch]]. For LaTeX-side `\citep`/`\citet` choice, see [[latex-paper]].
For evaluating someone else's citations during review, see [[paper-review]].

## Lists vs prose

- **Use a list when**: items are parallel, ≥3 items, the order doesn't
  carry argument-of-the-form-A-therefore-B.
- **Use prose when**: items are 1-2, you're making an argument, or the items
  need connective tissue.

A list of two items is almost always two sentences in disguise.

## Section length

For docs and READMEs:

- **Sections of 100-300 words.** If a section is longer, split. If shorter,
  merge.
- **Paragraphs of 2-5 sentences.** A one-sentence paragraph is fine for
  emphasis; an eight-sentence paragraph is unread.

## Comments in code

A standing rule: **default to no comment**. Add one when the *why* is
non-obvious — a constraint not visible in the code, a workaround for a
specific bug, behavior that would surprise a reader. Don't narrate the
*what*; good names already do that.

Bad: `// Increment counter`
Good: `// The third write must precede the fence; see issue #4421.`

This rule is in the user's CLAUDE.md and worth re-applying everywhere prose
meets code.

## See also

**Sibling skills in this repo**

- [[latex-paper]] — LaTeX syntax, conference templates, math, figures
- [[bibtex-fetch]] — fetching BibTeX from DOI/arXiv/title, deduping references
- [[paper-review]] — reviewing prose in someone else's draft

**Upstream Claude skills** (installed via `scripts/install_claude_skills.sh`)

- [[doc-coauthoring]] — iterative drafting workflow for longer docs; use when
  the deliverable is a multi-section spec, proposal, or design doc rather
  than a single README or paragraph rewrite
- [[writing-plans]] — pre-implementation planning docs; sibling to this skill
  for engineering-process writing
- [[brainstorming]] — ideation phase before drafting
- [[brand-guidelines]] — Anthropic visual identity if the artifact is for
  Anthropic-branded surfaces
- [[skill-creator]] — for editing skills (including this one)

**Style canon** — reach for these when the model needs a tiebreaker on a
style judgment call:

- Strunk & White, *The Elements of Style* (4th ed.) — concision, omit
  needless words, active voice. Dated on some points; still the baseline.
- Joseph M. Williams, *Style: Lessons in Clarity and Grace* — the best
  single source on subject-verb-object discipline and "characters as
  subjects."
- William Zinsser, *On Writing Well* — nonfiction prose; the chapter on
  clutter is the canonical reference for the "cut 30%" rule above.
- *The Chicago Manual of Style* (17th ed.) for hyphenation, capitalization,
  and serial-comma edge cases. For STEM, the IEEE Style Manual and
  ACM Style Guide override CMOS where they differ.

**Venue style guides** — when writing for a specific venue, the venue's
guide overrides everything above:

- ACM (SIGCOMM, SC, SIGCSE, PPoPP, HPDC, ICS): ACM Master Article Template;
  ACM Style Guide; use `acmart` document class.
- IEEE (SC, IPDPS, Cluster, CCGrid): IEEE Editorial Style Manual;
  `IEEEtran` class.
- USENIX (OSDI, ATC, NSDI): USENIX submission style (single column);
  `usenix-conf` class.
- NeurIPS, ICML, ICLR, AAAI: per-year style file; check that year's
  CFP — formatting rules change.

See [[latex-paper]] for the LaTeX-side template scaffolding.
