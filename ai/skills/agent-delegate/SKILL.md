---
name: agent-delegate
description: Use when one coding agent should hand work to the other — "ask codex", "have codex review this", "get a second opinion", "delegate this to codex", "run this in parallel", or, inside Codex, "ask claude". Covers the `codex` MCP tool (`codex` / `codex-reply`) from Claude Code, headless `claude -p` from Codex, sandbox and approval choices, prompt hygiene, and what not to delegate.
---

# Agent delegate

Apply when Claude Code should hand a task to Codex CLI, or Codex should hand
one to Claude Code. Both directions are one-shot: the other agent starts with
no memory of this conversation, so the prompt must carry everything it needs.

The global writing rule asks the author to request cross-provider review when
an implementation plan or Git edits are ready. The author makes that request
directly; no lifecycle hook starts or enforces it. Review a revision once after
addressing actionable findings, then report the result or unavailability.

## Peer review procedure

Send the complete plan or only Git changes you made in this task. Check the
starting worktree state when edits already exist; if you cannot separate your
changes, disclose that a scoped review was unavailable. Screen the material
for credential-like filenames and contents, leave those files out, and name
the exclusions. Check project instructions before sending code to the other
provider. The opening of every review prompt must say: "Delegated read-only
reviewer: do not edit files or request another review. Review only the supplied
material." Ask for actionable findings with locations and fixes, or an
explicit statement that none were found.

For a Codex-authored plan or diff, pass the screened text to Claude through
stdin and disable its tools:

```bash
claude -p --tools "" --strict-mcp-config --no-session-persistence \
  --output-format text <<'REVIEW'
Delegated read-only reviewer: do not edit files or request another review.
Review only the supplied material. Report actionable findings with locations
and fixes, or say "No actionable findings."

<screened plan or diff>
REVIEW
```

For Claude-authored work, create an empty temporary directory and call the
`codex` MCP tool with `sandbox: "read-only"`, that directory as `cwd`, and the
same review prompt plus screened material. Remove the directory afterward.
If the MCP tool is unavailable, use
`codex exec --skip-git-repo-check -s read-only -C "$review_dir" -`
with the prompt on stdin. This keeps the reviewer
outside the target repository, but Codex's read-only mode does not strictly
confine file reads; the prompt's limit remains an instruction.

If the other provider cannot run, disclose that no cross-provider review was
completed. End the author's final response with a `Peer review:` line that
names the result and the exact scope reviewed.

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
- Trivial optional delegation outside the required plan and change review.

## From Claude Code → Codex (MCP tool `codex`)

`scripts/install_claude_plugins.sh` registers the repo-owned
`~/.local/bin/codex-mcp-bridge` as the user-scope MCP `codex`. The bridge wraps
current `codex exec` releases; it replaces the removed `codex mcp-server`
subcommand. Two tools appear: `codex` (start a thread) and `codex-reply`
(continue it).

| Parameter | Use |
|---|---|
| `prompt` | Self-contained task: goal, files, constraints, acceptance criteria, report format |
| `cwd` | Absolute working directory; use an empty temporary directory for the peer review procedure above |
| `sandbox` | `read-only` for reviews and opinions; `workspace-write` for edits. Never `danger-full-access` from a delegate |
| `approval-policy` | Optional compatibility field; the only accepted value is `"never"` |
| `model` | Omit unless the user names one |
| `developer-instructions` | Pin conventions: "do not commit", "no new dependencies", "report as a unified diff" |

Example call:

```json
{"prompt": "Inspect the locking in src/queue.c for a race. Report file:line and a one-line fix. Do not edit files.",
 "cwd": "/home/user/project", "sandbox": "read-only", "approval-policy": "never"}
```

The bridge itself always forces approval policy `never`, rejects delegated
`danger-full-access`, and defaults new threads to `read-only`. The result
carries a `threadId`. Iterate with `codex-reply {threadId, prompt}` instead of
starting over; keep one thread per task.

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
For prose tasks, also name the intended reader and the question the writing
must answer. Ask for connected paragraphs when the result needs explanation.

## After it returns

Read the diff yourself. Run the tests. Summarize the delegate's answer for the
user in your own words; do not paste raw transcripts.

## See also

- [[systematic-debugging]] — when the second opinion is about a bug
- [[verification-before-completion]] — the delegate's "done" is a claim, not evidence
- [[using-git-worktrees]] — isolate the delegate's edits from this session's
- [[paper-review]] — second opinions on prose rather than code
