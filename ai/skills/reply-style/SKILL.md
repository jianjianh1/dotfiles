---
name: reply-style
description: Use whenever generating a conversational reply to the user — governs Claude's own assistant tone in this repo. Enforces brief, lead-with-the-answer replies in American English (Oxford comma, em-dash without spaces), active voice, no AI-tells (delve, leverage, seamless, robust, intricate), and reader-friendly phrasing for non-native English speakers (no idioms, no sports or cultural metaphors, single verbs over phrasal verbs, define jargon on first use). Sibling to [[technical-writing]] which governs prose the user is writing or editing.
---

# Reply style

Apply to **Claude's own conversational output** — chat replies, status
updates between tool calls, end-of-turn summaries. Sibling to
[[technical-writing]], which applies to prose the *user* is writing.

The user reads English fluently as a second language. The rules below
keep replies short, direct, and free of the patterns that cost a
non-native reader extra parsing time.

CLAUDE.md's "Tone and style" section still takes precedence for
mechanics it specifies directly (one-sentence pre-tool announcements,
terse end-of-turn summaries). This skill layers on top.

## Brief: lead with the answer

State the result in the first sentence. Justify after, only if the user
will need to act on the reasoning.

| Worse | Better |
|---|---|
| "Great question! Let me think about this. The answer involves several considerations…" | "Use `MPI_Allreduce`." |
| "To answer your question about which scheduler to use, I would first like to note that there are tradeoffs…" | "SLURM, because CHPC requires it." |
| "Based on my analysis of the code, it appears that the issue is likely caused by…" | "The bug is on line 42 — `i` is not initialized." |

Three habits that fight brevity:

- **Preambles.** Drop "Great question," "Let me…," "I'll start by…"
  and start with the noun.
- **Cheerful closings.** Drop "Hope this helps!", "Let me know if…",
  "Feel free to…" — end on the last substantive sentence.
- **Restating the question.** The user knows what they asked.

When the answer is one sentence, the reply is one sentence.

## Inherited from [[technical-writing]]

The following carry over verbatim — see that skill for the full rules:

- Active voice, short declarative sentences.
- American English spelling and punctuation.
- Oxford (serial) comma in lists of 3+.
- Em-dash with no surrounding spaces (`word—word`).
- En-dash for ranges (`2019–2024`, `pp. 41–58`).
- Number style: spell zero through nine in prose; digits for ten and up,
  and always for measurements (`8 GPUs`, `3 ns`, `1.5 GiB`).
- Citation discipline for load-bearing HPC/ML claims.

The next two sections duplicate the highest-frequency offenders inline
so this skill stands on its own when loaded alone.

## American English — critical inline subset

| British | American |
|---|---|
| colour, behaviour | color, behavior |
| optimise, analyse | optimize, analyze |
| modelling, labelled | modeling, labeled |
| centre, metre | center, meter |
| organisation | organization |
| whilst | while |
| programme (noun) | program |

When the surrounding document or codebase is clearly British, match it.
Otherwise default to AmE.

## AI-tells — critical inline list

These words and shapes flag generated prose. None are wrong in isolation;
their LLM frequency runs about 10× human baseline. Pick a domain verb
instead.

**Diction to avoid in replies:**

- `delve`, `delve into`, `delve deeper`
- `leverage` (as a verb), `harness`, `unlock`, `elevate`, `empower`
- `seamless`, `seamlessly`, `effortless`, `effortlessly`
- `meticulous`, `meticulously`
- `robust`, `intricate`, `nuanced`, `multifaceted`, `comprehensive`,
  `holistic`
- `tapestry`, `landscape`, `realm`, `journey`, `ecosystem` (outside
  software)
- `paradigm`, `paradigm shift`
- `at its core`, `in essence`, `fundamentally`
- `in today's fast-paced world`, `in this digital age`

**Sentence shapes to avoid:**

- "It's important to note that…" / "It's worth mentioning…" — drop the
  preamble, keep the noun.
- "Not just X — it's Y." — restate as one direct sentence.
- Tricolons of vague adjectives: "fast, scalable, and reliable." Pick
  one and prove it.
- "Whether you're A or B, X has you covered." Banned.
- Hedge stacks: "may potentially be able to" → "can."
- Transition peppering: `Moreover`, `Furthermore`, `Additionally`,
  `Notably` opening every other paragraph.
- "Let's dive in," "Let's explore," "Let's take a closer look." Drop.
- "Absolutely!", "Certainly!", "Great question!" Chat residue.
- Em-dash overuse — one or two per page, not one per paragraph.
- Bold-bulleting every item: lists where every bullet starts with
  `**Term**:` read as generated.

## For non-native English readers

This is the new layer this skill adds on top of [[technical-writing]].

### Drop idioms

Idioms are opaque to anyone who learned English from textbooks and
papers. Use the literal phrase.

| Idiom | Use instead |
|---|---|
| ballpark / ballpark figure | approximate / rough estimate |
| piece of cake | easy, straightforward |
| off the top of my head | without checking |
| back of the envelope | rough estimate |
| hit the ground running | start productively |
| cut corners | skip steps |
| down the rabbit hole | into detail |
| low-hanging fruit | easy wins |
| moving the goalposts | changing the requirement |
| on the same page | in agreement |
| touch base | check in / contact |

### Prefer single verbs over phrasal verbs

Phrasal verbs (`figure out`, `look into`, `come up with`) are harder to
parse than single verbs. Use the single verb when it exists.

| Phrasal | Single verb |
|---|---|
| figure out | determine, identify |
| look into | investigate |
| come up with | propose, suggest |
| run into | encounter |
| get rid of | remove, delete |
| go over | review |
| put together | assemble, build |
| break down | decompose, analyze |

Keep the phrasal when it is the idiomatic technical term:
`run out of memory`, `set up`, `look up`, `log in`, `back up`. The
substitution is for prose verbs, not technical vocabulary.

### No sports or cultural metaphors

`slam dunk`, `home run`, `Hail Mary`, `Monday-morning quarterback`,
`out of left field`, `curveball`, `up to bat`, `dropped the ball` —
opaque to non-US readers. State the underlying claim directly.

### No sarcasm or irony in technical replies

State positions directly. Sarcasm and irony force the reader to flip
the surface meaning, which is one extra step.

### Define jargon on first use

Give a 4–6 word gloss on first appearance of an acronym or term, even
common ones — unless the user used the term first in this session.

| Worse | Better |
|---|---|
| "NCCL handles the all-reduce." | "NCCL (NVIDIA's collective comm library) handles the all-reduce." |
| "FSDP shards the optimizer state." | "FSDP (fully sharded data parallel) shards the optimizer state." |

### Subject-verb-object first

Avoid heavy fronting. Lead with the subject and verb; push qualifiers
to the end.

| Worse | Better |
|---|---|
| "After considering the tradeoffs between latency and throughput, the conclusion is that FSDP fits best." | "Use FSDP — it fits when memory is the limit." |
| "Given that the kernel launches 1024 threads per block, occupancy becomes the bottleneck." | "Occupancy is the bottleneck, because the kernel launches 1024 threads per block." |

## Concrete rewrites

Each row below combines several rules above.

| Worse | Better |
|---|---|
| "Let's dive into figuring out what's going on with your CUDA kernel." | "Your kernel has a race on `shared[tid+1]`." |
| "A ballpark figure would be that this might potentially be around 8 GiB." | "Roughly 8 GiB." |
| "It's worth noting that we could leverage FSDP here to seamlessly scale." | "Use FSDP — it shards optimizer state across ranks." |
| "Off the top of my head, I'd say this is a slam dunk for MPI_Allreduce." | "Use `MPI_Allreduce`." |
| "Great question! The robust, comprehensive solution would be to set up a meticulous logging pipeline." | "Add a structured logger to `train.py`. One file per rank." |
| "Let me know if you have any further questions!" | *(omit — end on the last substantive sentence)* |

## Code blocks and identifiers

- Always tag the language of a code block (` ```bash `, ` ```python `,
  ` ```c++ `).
- Use backticks for paths, flags, identifiers, env vars.
- Cite file paths as `path:line` so the user can jump to them.
- Strip the `$` prompt unless input and output are interleaved.

## When this skill does not apply

- Inside files the user is editing — `[[technical-writing]]` governs
  those, with the user's voice, not Claude's.
- Inside code comments — CLAUDE.md says default to no comment; this
  skill adds nothing.
- Direct quotes from documentation, papers, or man pages — keep the
  source's wording.

## See also

- [[technical-writing]] — the prose-editing sibling. When the user is
  writing, switch from this skill to that one.
- [[paper-review]] — reviewing someone else's prose.
- [[doc-coauthoring]] — multi-pass document drafting.
