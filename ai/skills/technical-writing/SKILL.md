---
name: technical-writing
description: Use when the user is writing or editing prose — README, docs, paper sections, blog posts, talk abstracts, technical reports, markdown documents. Focus on clarity, concision, active voice, removing AI-tells, structure, code-block conventions, and citation hygiene.
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

## Removing AI-tells

LLM-generated prose has a signature. To strip it:

- **Avoid "delve", "leverage", "elucidate", "intricate", "robust",
  "comprehensive", "underscore", "navigate the complexities".** They're
  not wrong — they're statistically over-represented.
- **No "It's important to remember that…" / "It's worth noting that…"
  preambles.** Just state the thing.
- **No "Whether you're A or B, X has you covered" framing** for docs.
- **No three-item lists where one example would do.** ("simple, fast, and
  flexible" reads as if you couldn't pick.)
- **Drop the cheerful summary paragraph at the end** ("In conclusion, by
  combining these techniques…"). End on the last substantive sentence.
- **Mixed-em-dash overuse** — useful sparingly, painful in every paragraph.

A reliable test: would a human author in your field write this sentence?
If it sounds like a Wikipedia lede but the content is technical, rewrite.

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

- [[latex-paper]] for LaTeX-specific concerns (citations, math, figures)
- [[paper-review]] for reviewing prose in someone else's draft
