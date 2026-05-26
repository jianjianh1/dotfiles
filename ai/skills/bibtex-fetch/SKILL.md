---
name: bibtex-fetch
description: Use when the user needs a BibTeX entry — fetching from a DOI, arXiv ID, or paper title; appending to references.bib; deduplicating entries; or auditing citations in a paper (orphan citations, missing fields, self-citation ratio).
allowed-tools: Bash(curl *) Bash(grep *) Bash(awk *)
---

# BibTeX fetching & citation hygiene

Apply for any operation on `.bib` files or citation references.

## Fetching from a DOI

CrossRef's content negotiation endpoint returns BibTeX directly:

```bash
curl -sLH "Accept: application/x-bibtex" \
     "https://doi.org/10.1145/3458817.3476209"
```

Pipe to your `.bib`:

```bash
curl -sLH "Accept: application/x-bibtex" \
     "https://doi.org/10.1145/3458817.3476209" \
     | tee -a references.bib
```

If CrossRef returns an empty/HTML response, the DOI is either invalid or
not in CrossRef (some venues use DataCite or are publisher-only). Fall back
to a title search:

```bash
curl -sG "https://api.crossref.org/works" \
     --data-urlencode "query.title=Attention Is All You Need" \
     --data-urlencode "rows=3" | jq '.message.items[].DOI'
```

## Fetching from arXiv

```bash
# Given arXiv ID 1706.03762 (with or without version suffix)
curl -s "https://arxiv.org/bibtex/1706.03762"
```

arXiv's BibTeX is minimal; if the paper has since appeared at a venue,
prefer the venue DOI's BibTeX (more complete metadata).

## Cleaning the entry

After fetching, normalize:

1. **Set a stable key**. CrossRef hands back things like `Author2024Sometitle`.
   Rewrite to `lastname-shorttopic-YYYY` (e.g., `vaswani-attention-2017`).
2. **Drop noisy fields**: `url`, `month`, `issn`, `language`, `eprinttype`
   if you're using natbib (biblatex tolerates more).
3. **Fix Unicode**: replace `\"o` with `{ö}` or vice versa to match your
   document's encoding (most modern LaTeX uses UTF-8 source — keep Unicode).
4. **Wrap title casing**: `title = {The {BERT} paper title}` — extra braces
   around acronyms and proper nouns prevent BibTeX from lowercasing them.

A typical clean entry:

```bibtex
@inproceedings{vaswani-attention-2017,
  title     = {Attention Is All You Need},
  author    = {Vaswani, Ashish and Shazeer, Noam and Parmar, Niki and others},
  booktitle = {Advances in Neural Information Processing Systems},
  year      = {2017},
  url       = {https://arxiv.org/abs/1706.03762},
}
```

## Deduplication

A `.bib` accumulates duplicates fast. Quick audit:

```bash
# Find duplicate citation keys
grep -oE "^@[a-z]+\{[^,]+," references.bib | sort | uniq -d

# Find probable duplicate entries by title
awk '/title *=/ {gsub(/[{}",]/, ""); print tolower($0)}' references.bib \
    | sort | uniq -c | sort -rn | awk '$1 > 1'
```

For thorough work: `biber --tool --output_resolve_xdata=1 references.bib`
(part of biblatex's `biber`) normalizes and reports collisions.

## Citation hygiene in a paper

**Orphan citations** (entries in `.bib` never cited in `.tex`):

```bash
# Keys in .bib
grep -oE "^@[a-z]+\{[^,]+," references.bib | sed 's/^@[a-z]*{//; s/,$//' | sort -u > /tmp/bib_keys

# Keys referenced in .tex
grep -rhoE '\\cite[pt]?\{[^}]+\}' *.tex sections/*.tex 2>/dev/null \
    | grep -oE '\{[^}]+\}' | tr -d '{}' | tr ',' '\n' | tr -d ' ' | sort -u > /tmp/tex_keys

# Orphans: in bib, not in tex
comm -23 /tmp/bib_keys /tmp/tex_keys

# Missing: in tex, not in bib (would already fail compile, but useful for big diffs)
comm -13 /tmp/bib_keys /tmp/tex_keys
```

**Self-citation ratio** (for review panels that ask):

```bash
# Count cites whose first author matches your name
your_name="huang"
grep -rhoE '\\cite[pt]?\{[^}]+\}' *.tex sections/*.tex \
    | grep -oE '\{[^}]+\}' | tr -d '{}' | tr ',' '\n' | sort -u \
    | while read key; do
        author=$(grep -A1 "^@[a-z]\+{$key," references.bib | grep author | head -1)
        case "$(echo "$author" | tr '[:upper:]' '[:lower:]')" in
            *"$your_name"*) echo "$key" ;;
        esac
      done | wc -l
```

Aim for under ~25% self-citations in a typical paper; flag at 35%+.

## Common pitfalls

- **`@misc` for an arXiv preprint that's now published** — switch to
  `@inproceedings` / `@article` once the venue is known. Reviewers notice.
- **Inconsistent venue names**: `Proceedings of NeurIPS` vs
  `Advances in Neural Information Processing Systems`. Pick one form and use
  `bibtex-tidy` (npm) or a sed pass to enforce.
- **Author order corruption**: BibTeX uses ` and ` as the separator, not
  commas. `{Smith, J. and Doe, A.}` is correct; `{Smith, J., Doe, A.}`
  silently parses as a single author "Smith, J., Doe, A.".
- **Missing pages on `@inproceedings`**: most styles render this as
  "pp. ??--??"; fetch the published version's metadata.

## See also

- [[latex-paper]] for the paper that consumes the `.bib`
- [[paper-review]] when checking that someone's citations actually exist
