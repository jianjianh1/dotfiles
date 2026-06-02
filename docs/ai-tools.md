# AI Tool Configuration Reference

Sources: [`claude_settings.json`](../ai/claude_settings.json), [`codex_config.toml`](../ai/codex_config.toml), [`install_claude_plugins.sh`](../scripts/install_claude_plugins.sh)

> **Permissive by default.** The shipped configs (`bypassPermissions`, `sandbox.enabled = false`, `approval_policy = never`, `sandbox_mode = danger-full-access`) run Claude and Codex with **no per-action prompts and no sandbox** — intentional for a single-user dev machine. The "Denied Patterns" table below documents a **recommended hardening pattern**, not what the shipped JSON contains (the shipped `permissions.deny` array is empty). Before deploying these configs to a shared host, copy that table's patterns into `permissions.deny` and consider flipping `defaultMode` to `default`.

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

### Attribution

| Setting | Value | Purpose |
|---------|-------|---------|
| `attribution.commit` | `""` | No attribution in commits |
| `attribution.pr` | `""` | No attribution in PRs |

### Permissions

#### Denied Patterns (recommended — NOT shipped)

The shipped `claude_settings.json` has `permissions.deny = []` to match the permissive default mode noted at the top of this doc. The table below is the **recommended deny-list to copy in** when hardening for a shared host:

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
| `Stop` | Ring terminal bell (`\a`) |
| `Notification` | Ring terminal bell (`\a`) |

Both hooks run `printf '\a' > /dev/tty` to produce an audible notification.

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

### Attribution

| Setting | Value |
|---------|-------|
| `commit_attribution` | `""` (empty — no attribution) |

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

### TUI

| Setting | Value |
|---------|-------|
| `notifications` | `true` |
| `animations` | `true` |

### Trusted Projects

```toml
[projects."/uufs/chpc.utah.edu/common/home/u1446071/.dotfiles"]
trust_level = "trusted"
```

### CHPC behavior

`install.sh` uses the same repo `claude_settings.json` and `codex_config.toml` on CHPC as elsewhere — no separate generated overrides. The `~/.dotfiles-generated/` directory is still used for version-adaptive compat files (tmux, vim, gitconfig, bashrc) but no longer holds AI-tool config.

---

## MCP Servers & Plugins (`install_claude_plugins.sh`)

The install script registers one MCP server and three marketplace plugins. Anything an older version of the script previously installed (`github`/`filesystem`/`memory`/`git`/`serena` MCPs and several extra plugins) is uninstalled defensively on each run so upgrade hosts converge to the curated set.

> **Reserved names — do not use locally.** The defensive uninstall runs on every `./install.sh`, so manually adding any of these will get silently undone on the next run. Pick a different name for personal MCPs or plugins.
>
> - Reserved MCP names: `github`, `filesystem`, `memory`, `git`, `serena`
> - Reserved plugin names: `github`, `linear`, `sentry`, `notion`, `slack`, `codex`, `agent-sdk-dev`, `clangd-lsp`, `pyright-lsp`, `typescript-lsp`, `gopls-lsp`, `rust-analyzer-lsp`, `explanatory-output-style`

### Installed MCP servers

| Server | Transport | Package | Purpose |
|--------|-----------|---------|---------|
| `fetch` | stdio/uvx | `mcp-server-fetch` | HTTP fetching (URLs Claude can't otherwise reach) |
| `time` | stdio/uvx | `mcp-server-time` | Current time / timezone conversions (date-stamp memory, reason about SLURM `--time=` budgets) |

### Cloud-managed connector catalog (`claude.ai *`)

`claude mcp list` also surfaces a set of OAuth-gated third-party connectors named `claude.ai Notion`, `claude.ai Linear`, `claude.ai Gmail`, `claude.ai Atlassian`, etc. These are **not installed by this repo** — they come from Anthropic's account-level connector catalog, pushed to every Claude Code session.

- **On disk**: only an auth-state cache at `~/.claude/mcp-needs-auth-cache.json` (entries like `mcpsrv_01BgztWKuyz1pm6auaCzhvv9`). The canonical catalog lives server-side at claude.ai.
- **Status**: each entry shows `! Needs authentication` and is inert until you OAuth in through claude.ai's web settings.
- **Installer output**: the final "Installed MCP servers (repo-managed)" block in `install_claude_plugins.sh` is filtered to show only entries this repo owns, so the cloud catalog no longer appears there. Run `claude mcp list` directly to see the catalog alongside repo-managed servers.
- **To disable individual catalog entries**: do it in claude.ai's connector settings (web UI) — the dotfiles cannot un-publish them.

### Installed marketplace plugins

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
