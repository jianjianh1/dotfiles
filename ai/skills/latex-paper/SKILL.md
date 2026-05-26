---
name: latex-paper
description: Use when the user is editing .tex files, building a paper with latexmk/pdflatex/xelatex/lualatex, scaffolding a NeurIPS/ICML/IEEE/ACM template, fixing compile errors, managing figures or bibliographies, or asking about LaTeX best practices.
---

# LaTeX paper authoring

Apply for any LaTeX paper, thesis, or technical-report work.

## Use `latexmk`. Always.

```bash
latexmk -pdf paper.tex             # auto-detects bibtex/biber, multi-pass
latexmk -pdf -pvc paper.tex        # continuous build; rebuilds on file save
latexmk -c                         # clean aux files
latexmk -C                         # also clean PDF
```

Add a project-local `.latexmkrc`:

```perl
$pdf_mode = 1;
$pdflatex = 'pdflatex -interaction=nonstopmode -synctex=1 %O %S';
$bibtex_use = 2;                # always run bibtex if .bib is referenced
$clean_ext = 'synctex.gz bbl run.xml';
```

`-synctex=1` enables editor↔PDF jump (vimtex, VS Code LaTeX Workshop). The
`$pdflatex` line keeps compiles non-interactive so CI doesn't hang on a
prompt.

## Project skeleton

```
paper/
├── paper.tex                    # \documentclass + \input macros
├── sections/
│   ├── 01_intro.tex             # one \input per section
│   ├── 02_method.tex
│   └── ...
├── figures/                     # .pdf / .png; never commit binaries you can rebuild
├── references.bib
├── macros.tex                   # custom \newcommand definitions
├── .latexmkrc
└── .gitignore                   # *.aux *.log *.out *.bbl *.blg *.pdf
```

`\input{sections/02_method}` (no `.tex`) — splits the file without changing
the line-number trail in compile errors.

## Conference / venue templates

| Venue | Class | Notes |
|---|---|---|
| NeurIPS | `\documentclass{neurips_2024}` | `\usepackage[final]{neurips_2024}` for camera-ready (removes line numbers) |
| ICML | `\documentclass[twoside]{icml2024}` | run `\twocolumn`-aware; uses `natbib` |
| ACL/EMNLP | `\documentclass[11pt]{article}` + `acl.sty` | `\usepackage[review]{acl}` until acceptance |
| IEEE | `\documentclass[conference]{IEEEtran}` | `\usepackage{cite}` for IEEE numeric style |
| ACM | `\documentclass[sigconf,review,anonymous]{acmart}` | strip `review,anonymous` for camera-ready |
| arXiv preprint | `arxiv.sty` (Eduard Bopp) | minimal; good for v1 |

Don't modify class files. Override behavior via `\renewcommand` in
`macros.tex` instead — keeps you compliant when the venue updates the class.

## Figures

```latex
\begin{figure}[t]
    \centering
    \includegraphics[width=0.95\linewidth]{figures/scaling.pdf}
    \caption{Strong-scaling efficiency on 1-1024 GPUs.
             Dashed line shows ideal linear speedup.}
    \label{fig:scaling}
\end{figure}
```

- Always set `width=...\linewidth`, never absolute lengths.
- `.pdf` figures (from matplotlib `savefig("...pdf")` or tikz/PGFPlots) scale
  cleanly. `.png` only for screenshots and rasters that genuinely need raster.
- Caption goes *below* figures, *above* tables (LaTeX convention).
- Reference with `Figure~\ref{fig:scaling}` — non-breaking space, never
  "Fig. \ref{...}".

## Tables — booktabs, never \hline

```latex
\usepackage{booktabs}

\begin{tabular}{lrrr}
    \toprule
    Method & Acc. & Params & FLOPs \\
    \midrule
    Baseline & 92.1 & 25M & 1.2G \\
    Ours     & 94.3 & 27M & 1.3G \\
    \bottomrule
\end{tabular}
```

`\toprule` / `\midrule` / `\bottomrule` produce typographically correct
rules. Never use vertical bars (`|c|c|c`) in tables — they're considered
visual noise in scientific publishing.

## Math — `align` over `eqnarray`, always

```latex
\begin{align}
    \mathcal{L}(\theta) &= \frac{1}{N} \sum_{i=1}^{N} \ell(f_\theta(x_i), y_i) \\
                       &\quad + \lambda \|\theta\|_2^2.
\end{align}
```

Use `align*` (no number) for derivations the reader doesn't need to cite.
Number equations only when you reference them.

## Compile errors: where to look

| Error | What it usually means |
|---|---|
| `Undefined control sequence \X` | Missing `\usepackage`, or typo |
| `! LaTeX Error: File 'X.sty' not found` | Install the package (`tlmgr install X` or `apt install texlive-...`) |
| `Missing $ inserted` | Math symbol outside math mode |
| `Overfull \hbox (... too wide)` | Long word in narrow column; use `\sloppy` or rewrite |
| `Citation 'X' on page ... undefined` | Forgot to re-run bibtex; latexmk handles this |
| `! Package biblatex Warning: ...` | natbib vs biblatex mismatch; pick one and stick with it |

For citation-management, mention [[bibtex-fetch]] when generating `.bib`
entries.

## Style notes

- **Use `\citet{key}` for "Smith et al. (2024) showed…", `\citep{key}` for
  "(Smith et al., 2024)"**. natbib syntax — biblatex equivalents are
  `\textcite` / `\autocite`.
- **Non-breaking spaces (`~`) before refs**: `Section~\ref{sec:method}`,
  `Equation~\ref{eq:loss}`. Prevents bad line breaks.
- **Use `\eg`, `\ie`, `\etc`** macros (defined in `xspace` package) to handle
  spacing after abbreviations correctly.
- **One sentence per line** in source. Makes diffs and version control
  bearable; LaTeX renders identically.

## See also

- [[bibtex-fetch]] for DOI/arXiv → BibTeX entries
- [[paper-review]] when reviewing someone else's paper draft
- [[technical-writing]] for the prose itself (active voice, etc.)
