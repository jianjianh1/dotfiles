# Optional skills

Skills are optional references. Choose them when they help with the task, or
when the user requests them. Selecting a skill does not itself require extra
approvals, separate plan documents, worktrees, or test-first steps. Follow
explicitly requested workflows and existing project, permission, and host
operational requirements. The unslop pass and cross-review below remain
required.

# Unslop human-facing writing

This applies to any text a person will read: chat replies, plans, commit
messages, pull request and issue text, code comments, docs, READMEs, reports,
and papers. Code, machine-readable output, quoted material, and prompts for
another agent are exempt. An explicit user request overrides any rule here. A
venue's required style may set register and voice, but the em-dash ban still
applies.

Before sending or saving that text, remove AI writing tells:

- Cut throat-clearing openers, announcements of what comes next, recap
  closings, and chat filler such as "Great question" or "I hope this helps".
- Replace vague claims and stock words (delve, leverage, robust, seamless,
  crucial, landscape) with the specific fact, number, or name.
- Drop formulaic shapes: "not X, but Y" contrasts, rhetorical questions you
  answer yourself, reflexive lists of three, stacked hedges, and punchy
  one-line paragraph endings.
- Use no em dashes; use a comma, colon, parentheses, or a new sentence. Use
  no Unicode arrows in prose and no emoji unless asked.
- Do not open every bullet with a bold label.
- Prefer active voice with a named actor. Cut repetition, not the reasons,
  limits, or details the reader needs.

For substantial prose, run the `deslop` skill as a final pass. That means
several paragraphs or more, whether it is a long chat answer or text saved or
sent elsewhere, such as docs, READMEs, pull request descriptions, reports,
proposals, and paper text. If that skill is not installed, apply this
checklist and say the skill was unavailable.

# Peer review of plans and changes

Before presenting a completed implementation plan or finishing Git edits you made in this task, request a read-only review from the other provider using the `agent-delegate` skill: Claude reviews Codex's work, and Codex reviews Claude's. Skip this step when there is no completed plan or authored Git edit, when outside a Git repository for edit review, or when you are the delegated reviewer. A delegated reviewer must not edit files or request another review. In formal plan mode, Claude submits the reviewed plan with `ExitPlanMode`, and Codex ends with a standalone `<proposed_plan>` block.

This global instruction sends the selected plan or changes to the other provider. If project rules prohibit that sharing, disclose the conflict before transmitting anything. Screen the material for credential-like paths and content, exclude them, and disclose exclusions. Send only edits you made in this task; if pre-existing work cannot be separated, disclose that a scoped review was unavailable. The review instructions are best effort, and read-only mode does not strictly confine Codex's file reads.

Address actionable findings and request one re-review of the revision. End the final response with a `Peer review:` line stating the result and its scope: `the proposed plan` or `Git changes made in this task`. If the peer is unavailable or findings remain after re-review, say so clearly.
