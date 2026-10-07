---
name: agent-delegate
description: Cross-review completed plans or Git changes; also supports requested delegation and second opinions between Claude and Codex.
---

# Agent delegate

Claude reviews Codex's completed plans and Git changes; Codex reviews Claude's.
The author requests the review directly, without a lifecycle hook. Delegated
reviewers do not edit files or request another review.

## Review procedure

1. Check the starting worktree so the review includes only changes from this
   task. If they cannot be separated, report that scoped review is unavailable.
2. Check project sharing rules. Screen filenames and content for credentials;
   omit sensitive material and disclose exclusions. Send the complete plan or
   the task's screened diff, with enough context to assess it.
3. Begin the prompt with: "Delegated read-only reviewer: do not edit files or
   request another review. Review only the supplied material." Ask for
   actionable findings with locations and fixes, or "No actionable findings."
4. Address actionable findings and request one re-review. Report unresolved
   findings or provider unavailability. End with a `Peer review:` line naming
   the result and scope: `the proposed plan` or `Git changes made in this task`.

## Codex to Claude

Pass screened material through stdin with tools disabled:

```bash
claude -p --tools "" --strict-mcp-config --no-session-persistence \
  --output-format text <<'REVIEW'
Delegated read-only reviewer: do not edit files or request another review.
Review only the supplied material. Report actionable findings with locations
and fixes, or say "No actionable findings."

<screened plan or diff>
REVIEW
```

For a requested second opinion, `claude -p "<self-contained prompt>"
--output-format text` also works. Leave edit permissions off for reviews.

## Claude to Codex

Create an empty temporary directory and call the `codex` MCP tool with that
`cwd`, `sandbox: "read-only"`, and the review prompt plus screened material.
Remove the temporary directory afterward. The repo's `codex-mcp-bridge`
provides `codex` and `codex-reply`; the latter accepts a `threadId` for follow-up.
If MCP is unavailable, pass the prompt through stdin:

```bash
codex exec --skip-git-repo-check -s read-only -C "$review_dir" -
```

Read-only mode does not strictly confine Codex's file reads; the prompt limits
its review to supplied material. Omit a model override unless requested.

For requested implementation delegation, use disjoint files or an isolated
checkout and `sandbox: "workspace-write"`. The bridge forces approval policy
`never` and rejects `danger-full-access`. Give a self-contained goal, relevant
files, constraints, acceptance checks, and report format. Inspect returned
changes and run appropriate checks before accepting them.
