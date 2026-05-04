# AI Tool Configuration Reference

Sources: [`claude_settings.json`](../claude_settings.json), [`codex_config.toml`](../codex_config.toml), [`install_claude_plugins.sh`](../install_claude_plugins.sh)

---

## Claude Code (`claude_settings.json`)

Copied to `~/.claude/settings.json` by `setup.sh` (via `backup_and_copy`, not symlink — allows local overrides).

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

#### Denied Patterns

These paths are blocked from `Read` operations:

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

Copied to `~/.codex/config.toml` by `setup.sh` (mode `600`).

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
[projects."/uufs/chpc.utah.edu/common/home/u1446071/.server-configs"]
trust_level = "trusted"
```

### CHPC Generated Overrides

When `setup.sh` detects CHPC, it copies generated safe configs from `~/.server-configs-generated/` instead of these repo defaults. Claude uses `defaultMode = "default"` with sandboxing enabled. Codex uses `approval_policy = "untrusted"` and `sandbox_mode = "workspace-write"`.

---

## MCP Servers (`install_claude_plugins.sh`)

The install script sets up Model Context Protocol servers for Claude Code. It detects the installed Claude CLI version and uses the marketplace when available, falling back to manual `npx`/`uvx` registration.

On CHPC systems, MCP installation is skipped by default because servers need local approval first. After approval, run `install_claude_plugins.sh --allow-chpc` or set `SERVER_CONFIGS_ALLOW_CHPC_MCP=true`.

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
