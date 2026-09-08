---
name: agent-delegate
description: Use when one coding agent should hand work to the other — "ask codex", "have codex review this", "get a second opinion", "delegate this to codex", "run this in parallel", or, inside Codex, "ask claude". Covers the `codex` MCP tool (`codex` / `codex-reply`) from Claude Code, headless `claude -p` from Codex, sandbox and approval choices, prompt hygiene, and what not to delegate.
---

# Agent delegate

Apply when Claude Code should hand a task to Codex CLI, or Codex should hand
one to Claude Code. Both directions are one-shot: the other agent starts with
no memory of this conversation, so the prompt must carry everything it needs.

## When to delegate

- **Second opinion** on a design choice, a suspected bug, or a proof sketch —
  a different model with no anchoring on this session's reasoning.
- **Review of a diff you just wrote** (read-only sandbox). Treat the result
  like a colleague's review, not a verdict.
- **A well-specified parallel subtask** that touches files this session is
  not editing: a test file, a script, a doc section.
- **Long refactors** you would otherwise babysit — hand off, keep working,
  collect the diff.

## When not to

- Anything involving secrets, tokens, or auth files.
- Both agents editing the same files at once. Give the delegate its own
  worktree ([[using-git-worktrees]]) or a disjoint file list.
- Tasks that need more context than fits in one prompt.
- Trivial edits — the round trip costs more than doing it yourself.

## From Claude Code → Codex (MCP tool `codex`)

`scripts/install_claude_plugins.sh` registers `codex mcp-server` as the
user-scope MCP `codex`. Two tools appear: `codex` (start a thread) and
`codex-reply` (continue it).

| Parameter | Use |
|---|---|
| `prompt` | Self-contained task: goal, files, constraints, acceptance criteria, report format |
| `cwd` | Absolute project root; Codex resolves relative paths against it |
| `sandbox` | `read-only` for reviews and opinions; `workspace-write` for edits. Never `danger-full-access` from a delegate |
| `approval-policy` | Always `"never"` — anything else blocks waiting for a human who is not there |
| `model` | Omit unless the user names one |
| `developer-instructions` | Pin conventions: "do not commit", "no new dependencies", "report as a unified diff" |

Example call:

```json
{"prompt": "Review the uncommitted diff (git diff) in this repo for correctness bugs. Report file:line, the bug, and a one-line fix. Do not edit files.",
 "cwd": "/home/user/project", "sandbox": "read-only", "approval-policy": "never"}
```

The result carries a `threadId`. Iterate with `codex-reply {threadId, prompt}`
instead of starting over; keep one thread per task.

**Fallback without the MCP** (`claude mcp list` lacks `codex`): run the CLI
through Bash. `approval_policy = "never"` comes from `~/.codex/config.toml`,
so `exec` never prompts.

```bash
codex exec --json -C "$PWD" -s read-only -o /tmp/codex-review.md \
  "Review the diff in HEAD~1..HEAD for correctness bugs. Report file:line."
codex exec resume --last "Propose a fix for the first finding."
codex review            # non-interactive review of the working tree
```

## From Codex → Claude Code (headless `claude -p`)

Codex has full shell access, so it calls Claude Code as a command. There is no
MCP entry for this on purpose: `claude mcp serve` exposes Claude Code's file
and shell tools, not the Claude model, and Codex already has equivalents.

```bash
cd /path/to/project        # so CLAUDE.md and ~/.claude/skills load
claude -p "Second opinion: does the locking in src/queue.c avoid the ABA problem? Answer in under 200 words with file:line references." \
  --output-format text
claude -p "..." --output-format json     # machine-readable; includes cost and session id
claude -p "..." --model opus             # pick a model
```

Add `--dangerously-skip-permissions` only when Claude must edit files; for
opinions and reviews leave it off. Each call is a fresh session with no shared
context, so restate the task fully.

## Prompt hygiene

State, in this order: the goal, the file list, hard constraints (no commits,
no new deps, keep the public API), acceptance criteria (tests that must pass),
and the report format you want back (unified diff, file list, or prose).

## After it returns

Read the diff yourself. Run the tests. Summarize the delegate's answer for the
user in your own words; do not paste raw transcripts.

## See also

- [[systematic-debugging]] — when the second opinion is about a bug
- [[verification-before-completion]] — the delegate's "done" is a claim, not evidence
- [[using-git-worktrees]] — isolate the delegate's edits from this session's
- [[paper-review]] — second opinions on prose rather than code
