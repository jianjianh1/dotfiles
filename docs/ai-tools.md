# AI Tool Configuration Reference

Sources: [`claude_settings.json`](../ai/claude_settings.json), [`claude_statusline.sh`](../ai/claude_statusline.sh), [`codex_config.toml`](../ai/codex_config.toml), [`writing-guidance.md`](../ai/writing-guidance.md), [`peer-review-hook.mjs`](../scripts/peer-review-hook.mjs), [`codex-mcp-bridge.mjs`](../scripts/codex-mcp-bridge.mjs), [`install_claude_plugins.sh`](../scripts/install_claude_plugins.sh), [`install.sh`](../install.sh)

> **Permissive by default.** The shipped configs (`bypassPermissions`, `sandbox.enabled = false`, `approval_policy = never`, `sandbox_mode = danger-full-access`) run Claude and Codex with **no per-action prompts and no sandbox** — intentional for a single-user dev machine. The shipped Claude deny rules block OpenAlex account and author-profile tools. The file-path patterns below are recommendations for shared hosts, not shipped rules. Before deploying to a shared host, consider adding those patterns and changing `defaultMode` to `default`.

---

## Writing guidance shared by both agents

[`ai/writing-guidance.md`](../ai/writing-guidance.md) gives Claude and Codex
the same default for human-facing prose: lead with the point, connect ideas in
paragraphs, define unfamiliar terms, and keep the context a new reader needs.
It covers documents, plans, PR text, explanations, and chat replies. Explicit
user requests and established document styles take precedence.

`install.sh` links the guide to `~/.claude/rules/writing.md`, which Claude
loads for every project without replacing an existing `~/.claude/CLAUDE.md`.
For Codex, it links the guide as `~/.codex/AGENTS.md` when that file is absent;
otherwise it updates a marked section in the existing file. If
`~/.codex/AGENTS.override.md` exists, it updates that file too, because Codex
reads the override in preference to `AGENTS.md`. An existing external symlink
is backed up and its instructions are copied into a merged file; uninstall
restores the link when that content is unchanged. `CODEX_HOME` replaces
`~/.codex` for these instruction files when set. Re-running the installer
refreshes managed sections. These instructions guide writing but cannot
guarantee prose quality.

### Automatic peer review

The shared guide also requires Codex and Claude to review each other's plans
and Git changes. `install.sh` links `scripts/peer-review-hook.mjs` to
`~/.local/bin/peer-review-hook`; user-level Claude and Codex hooks call it for
each new prompt and before a turn ends. Claude also calls it before presenting
an `ExitPlanMode` plan; both `PreToolUse` and `PermissionRequest` guard that
step because some Claude Code versions ignore a `PreToolUse` denial for
`ExitPlanMode`. In formal plan mode, Claude must call `ExitPlanMode` to show
its approval prompt. Codex must finish with a standalone `<proposed_plan>`
block; its terminal shows “Implement this plan?” only when the completed turn
contains a native Plan item. After peer review continues a Codex turn, the
agent must resend the complete block with its `Peer review:` line. A review
line alone does not restore the approval prompt.

At `Stop`, the hook redirects a completed prose plan toward the native
handoff. It recognizes an explicit “plan is ready” statement, an unclosed
`<proposed_plan>` tag, or at least two action items following either “Here's
what I'll do” or a plan heading and an implementation, test, summary, or
validation section. It ignores fenced examples, short sketches, and ordinary
progress replies. After two missed handoff retries, it reports that approval
was not triggered instead of continuing indefinitely. A valid native plan
resets that retry count. Outside formal plan mode, a plan without
`<proposed_plan>` needs a standalone
`<!-- peer-review:plan -->` marker outside a code fence. Git changes still
receive their normal code review.

Codex can omit `last_assistant_message` in a `Stop` event. The hook reads the
current turn's Plan item and final answer from the Codex transcript. In formal
plan mode, the Plan item confirms the native handoff; the complete
`<proposed_plan>` block in the final answer supplies the reviewed text. This
keeps routine TODO updates out of plan review. The hook combines the final
answer with any direct message for disclosure checks. It accepts transcripts
up to 64 MiB whose filename identifies
the session and skips an incomplete JSONL line. If the transcript cannot be
read and the hook payload has no message text, the hook warns and lets the
turn finish. It cannot verify a plan handoff or Git review disclosure in that
case; if credential-like files changed, the warning also names their exclusion
from review. This fallback depends on the `permission_mode`, `turn_id`, and
`transcript_path` hook fields and the transcript event format. Approval smoke
tests used Codex CLI 0.156.1 and Claude Code 2.1.274; revisit the fixture and
these fields when upgrading either CLI or changing the pinned review models.

These hooks apply across projects. A Codex-authored plan or Git change goes to
Claude's service for review, and a Claude-authored one goes to OpenAI's
service. Use this configuration only for projects whose code may be shared
with both providers. Disabling a hook in the CLI's user settings stops its
automatic review for that CLI.

At prompt submission, the hook records the Git diff and untracked text files
in a private local state directory. At completion, it compares that snapshot
with the current worktree so existing edits do not trigger a review by
themselves. The peer gets both snapshots and may inspect repository files for
context. Known credential filenames and common token patterns are excluded
from the review input and their exclusion must be disclosed. This filter
cannot detect every secret; keep credentials out of project changes. Code
review applies only in Git repositories; plan review works in any directory.
Review feedback and the final `Peer review:` line name their scope: `the proposed plan`
or `Git changes since this prompt`. A pass does not assess existing code outside
that scope.

The delegated reviewer runs read-only through the existing CLI sign-ins:
`codex exec -s read-only` with GPT-6 Sol when Claude is the author, and
`claude -p` with only read tools and Sonnet when Codex is the author. If the
reviewer hits a usage, quota, or rate limit, the hook retries the same review
once with GPT-6 Luna or Claude Haiku, respectively. It names the fallback
model in its feedback, and the author names it in the `Peer review:` line.
If that model hits a usage limit too, the hook tries an independent reviewer
from the author's provider: GPT-6 Luna for Codex-authored work, or Claude
Haiku for Claude-authored work. The result is labeled `same provider` so it
is not presented as a cross-provider review. Other failures do not trigger a
retry, and all attempts share the 300-second review budget.

The two Codex models are pinned together in `scripts/peer-review-hook.mjs`.
Update both pins and this description deliberately when moving reviews to a
newer GPT family. `CLAUDE_REVIEW_MODEL` still overrides the primary Claude
model.

An environment marker prevents recursive reviews. Actionable findings return
to the author, who revises once and sends the revision for review. A shared
account limit can block both models on one provider. If every reviewer fails,
the author reports the unavailable review in a `Peer review:` line. Each
fallback uses its existing CLI sign-in and adds no API credentials or billing.

Codex requires a one-time `/hooks` trust action after installation or a hook
definition change. These user-level hooks can be disabled, so they enforce the
normal configured workflow rather than an immutable policy. The peer review
uses each CLI's existing account; no API key is added by this setup.

---

## Claude Code (`claude_settings.json`)

Copied to `~/.claude/settings.json` by `install.sh` (via `backup_and_copy`, not symlink — allows local overrides).

### Core Settings

| Setting | Value | Purpose |
|---------|-------|---------|
| `model` | `opus` | Default model |
| `defaultMode` | `bypassPermissions` | Skip permission prompts (dangerous mode) |
| `effortLevel` | `high` | Reasoning effort level |
| `alwaysThinkingEnabled` | `true` | Extended thinking always on |
| `editorMode` | `vim` | Vim keybindings in the CLI |
| `respectGitignore` | `false` | Read all files regardless of .gitignore |
| `includeGitInstructions` | `true` | Include git context in prompts |
| `enableAllProjectMcpServers` | `true` | Auto-enable project MCP servers |

### Sandbox

| Setting | Value | Purpose |
|---------|-------|---------|
| `sandbox.enabled` | `false` | No sandboxing |
| `sandbox.failIfUnavailable` | `false` | Don't fail if sandbox unavailable |
| `sandbox.autoAllowBashIfSandboxed` | `true` | Auto-allow bash if somehow sandboxed |
| `skipDangerousModePermissionPrompt` | `true` | Skip the "are you sure?" prompt |

### UI

| Setting | Value | Purpose |
|---------|-------|---------|
| `spinnerTipsEnabled` | `true` | Show tips while thinking |
| `showTurnDuration` | `true` | Show time taken per turn |
| `terminalProgressBarEnabled` | `true` | Progress bar in terminal |
| `autoConnectIde` | `true` | Auto-connect to IDE if available |
| `statusLine` | `~/.claude/statusline.sh` | Two-line model, project, context, usage, cost, and git status |

`install.sh` symlinks the tracked status command into `~/.claude/statusline.sh`.
It renders model/effort/session/project/git/PR on the first line and a ten-cell
context bar, five-hour and seven-day allowance, cache ratio, cost, elapsed time,
and changed-line counts on the second. Missing data is omitted, lower-priority
segments disappear in narrow terminals, and `NO_COLOR` is honored.

### Timeouts

| Setting | Value | Purpose |
|---------|-------|---------|
| `BASH_DEFAULT_TIMEOUT_MS` | `1800000` (30 min) | Default bash command timeout |
| `BASH_MAX_TIMEOUT_MS` | `7200000` (2 hr) | Maximum bash command timeout |

### Updates & Cleanup

| Setting | Value | Purpose |
|---------|-------|---------|
| `autoUpdatesChannel` | `stable` | Auto-update channel |
| `cleanupPeriodDays` | `30` | Clean old data after 30 days |

`autoUpdatesChannel` is Claude Code's own in-app updater. Independently, re-running
`install.sh` keeps both CLIs current. **Claude Code** is a native, self-updating binary
(`~/.local/bin/claude` → `~/.local/share/claude/versions/<v>`), no longer an npm package:
`install.sh` reads `npm view @anthropic-ai/claude-code version` only as the "latest" signal,
then updates via the native `claude update` (or the official install script on a fresh host)
— never `npm install`, which would collide with the native symlink. **Codex** remains an
npm-managed package (`@openai/codex`): `install.sh` compares the installed version against
`npm view @openai/codex version` and reinstalls `@latest` only when outdated. Both are skipped
under `--no-update`, and on CHPC when the tools come from `module load`. See the
[README](../README.md#quickstart) for the full auto-update behavior across all managed CLI tools.

### Attribution

| Setting | Value | Purpose |
|---------|-------|---------|
| `attribution.commit` | `""` | No attribution in commits |
| `attribution.pr` | `""` | No attribution in PRs |

### Permissions

#### Optional file-path restrictions

The shipped `claude_settings.json` denies the five OpenAlex account and author-profile tools, so the research connector cannot use them through Claude. The file-path patterns below are **recommended additions**, not shipped rules:

| Pattern | Protects |
|---------|----------|
| `./.env` | Environment secrets |
| `./.env.*` | Environment variants |
| `./secrets/**` | Secrets directory |
| `~/.aws/**` | AWS credentials |
| `~/.ssh/**` | SSH keys |
| `~/.gnupg/**` | GPG keys |
| `~/.kube/config` | Kubernetes config |
| `~/.netrc` | Machine credentials |
| `~/.docker/config.json` | Docker auth |
| `~/.config/gcloud/**` | Google Cloud auth |

### Hooks

| Event | Action |
|-------|--------|
| `UserPromptSubmit` | Record the starting Git state |
| `PreToolUse` (`ExitPlanMode`) | Have Codex review Claude's plan |
| `PermissionRequest` (`ExitPlanMode`) | Deny an unreviewed or flawed plan before approval |
| `Stop` | Have Codex review plans or Git edits; ring terminal bell (`\a`) |
| `Notification` | Ring terminal bell (`\a`) |

The bell handlers run `printf '\a' > /dev/tty` to produce an audible notification.

---

## Codex CLI (`codex_config.toml`)

Copied to `~/.codex/config.toml` by `install.sh` (mode `600`).

### Reasoning

| Setting | Value | Purpose |
|---------|-------|---------|
| `model_reasoning_effort` | `high` | Default reasoning effort |
| `plan_mode_reasoning_effort` | `xhigh` | Extra-high reasoning when planning |

### Approvals & Sandbox

| Setting | Value | Purpose |
|---------|-------|---------|
| `approval_policy` | `never` | Never ask for approval |
| `sandbox_mode` | `danger-full-access` | Full filesystem/network access |

### Shell

```toml
[shell_environment_policy]
inherit = "all"    # Inherit all env vars (gh, npm, etc. work)
```

### History

| Setting | Value | Purpose |
|---------|-------|---------|
| `persistence` | `save-all` | Save all session history |
| `max_bytes` | `52428800` (50 MB) | Maximum history size |

### Web search

`web_search = "live"` makes Codex fetch current web results by default. This
supports [`research-brief`](../ai/skills/research-brief/SKILL.md),
[`research-project`](../ai/skills/research-project/SKILL.md), and other
questions where the answer may have changed.

### TUI

| Setting | Value |
|---------|-------|
| `notifications` | `true` |
| `animations` | `true` |
| `status_line_use_colors` | `true` |
| `status_line` | Model/reasoning, activity, context/tokens, limits/cost, project/git/PR, permissions, progress, and thread name |

The Codex status line is native TUI configuration. Codex automatically omits
unavailable items and truncates the ordered list to fit the terminal width.

### Trusted Projects

```toml
[projects."/uufs/chpc.utah.edu/common/home/u1446071/.dotfiles"]
trust_level = "trusted"
```

### Skills and delegation

Codex reads user skills from `~/.agents/skills/` and `~/.codex/skills/`. [`scripts/sync_agent_skills.sh`](../scripts/sync_agent_skills.sh) (run by `install.sh`) mirrors every `~/.claude/skills/<name>` into `~/.agents/skills/<name>` and links Codex-installed `~/.codex/skills/<name>` back into `~/.claude/skills/`, so both CLIs see one skill set — see [ai-skills.md](ai-skills.md#codex-skill-sync).

### Repeat work in an open Codex chat

The Codex-only [`$loop`](../ai/codex-skills/loop/SKILL.md) skill uses
[`codex-loop`](../scripts/codex-loop.mjs) and `codex queue` to return to the
same CLI chat on a schedule. For example, `$loop 5m check the deploy` checks
every five minutes; `$loop check the deploy` lets Codex choose a delay after
each check. Use `$loop list`, `$loop stop <id>`, or `$loop once in 45m remind me
to push` to manage jobs. Bare `$loop` runs the maintenance prompt, using
project `.claude/loop.md` or `~/.claude/loop.md` when present.

Codex has no user-defined `/loop` slash command, so invoke the skill with `$`.
The helper stores thread-local jobs under `~/.local/state/dotfiles-codex-loop/`
and uses `UserPromptSubmit`, `Stop`, `SessionStart`, and `SessionEnd` hooks to
validate, reschedule, and pause them. New or changed hooks need one `/hooks`
trust action in Codex. Jobs run with the chat's existing permissions, expire
after seven days, and require the chat to be open for timely delivery. Codex
may not signal session end until 30 minutes after a disconnected chat becomes
idle; a queued run can wait until resume. Use `$loop stop` to cancel a waiting
job; `Esc` does not cancel its timer. Uninstall removes the helper and state.

There is deliberately **no** `[mcp_servers.claude-code]` entry: `claude mcp serve` exposes Claude Code's file and shell tools, not the Claude model, and Codex already has equivalents. Codex asks Claude for a second opinion with headless `claude -p "<prompt>" --output-format text`, as described in the [`agent-delegate`](../ai/skills/agent-delegate/SKILL.md) skill. The opposite direction (Claude calling Codex) is the `codex` MCP server below.

### CHPC behavior

`install.sh` uses the same repo `claude_settings.json` and `codex_config.toml` on CHPC as elsewhere — no separate generated overrides. The `~/.dotfiles-generated/` directory is still used for version-adaptive compat files (tmux, vim, gitconfig, bashrc) but no longer holds AI-tool config.

On CHPC, installation also adds a managed allocation-discovery rule to Codex's
global `AGENTS.md` and, when present, `AGENTS.override.md`. It directs Codex to
run `mychpc batch` for the complete current list before choosing a job triple.
Uninstall removes only that managed rule; existing user instructions remain.

---

## MCP Servers & Plugins (`install_claude_plugins.sh`)

The install script registers four Claude MCP servers (`fetch`, `time`, `codex`, `openalex`) and three marketplace plugins. Codex gets `openalex` from `ai/codex_config.toml`. Anything an older version of the script previously installed (`github`/`filesystem`/`memory`/`git`/`serena` MCPs and several extra plugins) is uninstalled defensively on each run so upgrade hosts converge to the curated set.

> **Reserved names — do not use locally.** The defensive uninstall runs on every `./install.sh`, so manually adding any of these will get silently undone on the next run. Pick a different name for personal MCPs or plugins.
>
> - Reserved MCP names: `github`, `filesystem`, `memory`, `git`, `serena`
> - Reserved plugin names: `github`, `linear`, `sentry`, `notion`, `slack`, `codex`, `agent-sdk-dev`, `clangd-lsp`, `pyright-lsp`, `typescript-lsp`, `gopls-lsp`, `rust-analyzer-lsp`, `explanatory-output-style`
>
> `codex` is reserved only as a *plugin* name (the retired marketplace plugin). The `codex` *MCP server* below is repo-managed and lives in a different store (`claude mcp`, not `claude plugin`).

### Installed MCP servers

| Server | Transport | Package | Purpose |
|--------|-----------|---------|---------|
| `fetch` | stdio/uvx | `mcp-server-fetch` | HTTP fetching (URLs Claude can't otherwise reach) |
| `time` | stdio/uvx | `mcp-server-time` | Current time / timezone conversions (date-stamp memory, reason about SLURM `--time=` budgets) |
| `codex` | stdio | `~/.local/bin/codex-mcp-bridge` | Delegate to current Codex releases: tools `codex` (prompt, cwd, read-only/workspace-write sandbox, model, developer instructions) and `codex-reply` (threadId, prompt). When and how: the [`agent-delegate`](../ai/skills/agent-delegate/SKILL.md) skill |
| `openalex` | HTTP | [Official OpenAlex connector](https://help.openalex.org/access/connector/) | Scholarly work search, citation trails, reference checks, and bibliographic analysis |

The dependency-free bridge is owned by this repo and wraps `codex exec --json`
plus `codex exec resume`. This replaces the deprecated `codex mcp-server`
subcommand removed from current Codex releases. Delegated calls always use
approval policy `never`; new calls default to `read-only`, may explicitly use
`workspace-write`, and cannot request `danger-full-access`. The installer runs
one live `claude mcp list` health check and reports a warning unless the Codex
row says `Connected`.

### OpenAlex sign-in and research scope

After `./install.sh`, sign in with a free OpenAlex account on each host:

```bash
claude mcp login openalex
codex mcp login openalex
```

For SSH or other headless hosts, add `--no-browser` to each command and follow
the printed URL and callback instructions. Check registration with
`claude mcp list` and `codex mcp list`. The installer keeps an unchanged Claude
HTTP registration so later runs do not disrupt its OAuth state. `uninstall.sh`
removes the managed Claude registration; Codex loads the same endpoint from
its managed config. Neither an API key nor OAuth tokens are stored in this repo.

Codex exposes only OpenAlex's nine public research tools. Claude denies all
five account and author-profile tools by name in `ai/claude_settings.json`;
the other OpenAlex tools remain available. The connector uses the signed-in
account's [daily API budget](https://help.openalex.org/api/authentication/).
It returns metadata and links but [does not fetch full-text papers](https://help.openalex.org/access/connector/),
so the agent must open a paper or source before citing its findings. If sign-in
or budget is unavailable, both research skills use web sources and the
existing Crossref workflow, and state the missing scholarly checks.

### Cloud-managed connector catalog (`claude.ai *`)

`claude mcp list` also surfaces a set of OAuth-gated third-party connectors named `claude.ai Notion`, `claude.ai Linear`, `claude.ai Gmail`, `claude.ai Atlassian`, etc. These are **not installed by this repo** — they come from Anthropic's account-level connector catalog, pushed to every Claude Code session.

- **On disk**: only an auth-state cache at `~/.claude/mcp-needs-auth-cache.json` (entries like `mcpsrv_01BgztWKuyz1pm6auaCzhvv9`). The canonical catalog lives server-side at claude.ai.
- **Status**: each entry shows `! Needs authentication` and is inert until you OAuth in through claude.ai's web settings.
- **Installer output**: the final "Installed MCP servers (repo-managed)" block in `install_claude_plugins.sh` is filtered to show only entries this repo owns, so the cloud catalog no longer appears there. Run `claude mcp list` directly to see the catalog alongside repo-managed servers.
- **To disable individual catalog entries**: do it in claude.ai's connector settings (web UI) — the dotfiles cannot un-publish them.

### Installed marketplace plugins

On a fresh host, the installer adds Anthropic's `claude-plugins-official`
marketplace before installing these plugins. Later runs refresh the existing
marketplace when possible. A failed marketplace or plugin installation is
reported in the top-level `install.sh` warning summary.

| Plugin | Purpose |
|--------|---------|
| `context7` | Live API docs lookup for libraries (PyTorch, NumPy, MPI, CUDA, …) |
| `commit-commands` | Curated commit + push + PR helpers |
| `pr-review-toolkit` | PR review workflow + specialized review agents |

### Capability handling

Each step is best-effort:

- If `claude mcp` is unavailable the MCP step is skipped.
- If `claude plugin` is unavailable the marketplace step is skipped.
- If `uvx` is missing the `fetch` and `time` MCPs are skipped (`uv` is installed by `install.sh`, so this is rare).
- If `codex` or the installed bridge is missing the `codex` MCP is skipped; re-run `./install.sh` after Codex is installed and it registers.
- `openalex` is registered without local package dependencies; it needs a separate OAuth sign-in before research tools can connect.
