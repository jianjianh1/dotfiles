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

## MCP Servers (`install_claude_plugins.sh`)

The install script sets up Model Context Protocol servers for Claude Code. It detects the installed Claude CLI version and uses the marketplace when available, falling back to manual `npx`/`uvx` registration.

On CHPC systems, MCP installation is skipped by default because servers need local approval first. After approval, run `install_claude_plugins.sh --allow-chpc` or set `DOTFILES_ALLOW_CHPC_MCP=true`.

### Installed Servers

| Server | Transport | Package | Purpose |
|--------|-----------|---------|---------|
| `github` | stdio/npx | `@modelcontextprotocol/server-github` | GitHub API access |
| `filesystem` | stdio/npx | `@modelcontextprotocol/server-filesystem` | Local filesystem operations |
| `memory` | stdio/npx | `@modelcontextprotocol/server-memory` | Persistent memory across sessions |
| `fetch` | stdio/uvx | `mcp-server-fetch` | HTTP fetching |
| `git` | stdio/uvx | `mcp-server-git` | Git operations |

### Marketplace Plugins

When `claude mcp add --from-marketplace` is available, these are also installed:

`github`, `linear`, `sentry`, `notion`, `slack`, `codex`, `commit-commands`, `pr-review-toolkit`, `agent-sdk-dev`, `clangd-lsp`, `pyright-lsp`, `typescript-lsp`, `gopls-lsp`, `rust-analyzer-lsp`, `explanatory-output-style`

### Capability Detection

The script checks three capability levels:

1. **MCP support** — Does `claude mcp` exist?
2. **Plugin command** — Does `claude mcp add` work?
3. **Marketplace** — Does `claude mcp add --from-marketplace` work?

Falls back gracefully at each level. Skips entirely if `npx` is not available.
