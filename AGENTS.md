# Repository Guidelines

## Project Structure & Module Organization

This repository is flat and script-driven. Top-level files are the product: shell configs such as `vimrc`, `tmux.conf`, `gitconfig`, `sshconfig`, `bashrc_exports`, and `bashrc_aliases`, plus JSON/TOML settings for Claude and Codex. Operational logic lives in `setup.sh`, `deploy.sh`, `uninstall.sh`, and `install_claude_plugins.sh`. Shared helpers live in `lib/common.sh`. Neovim config lives in `nvim/` (one plugin spec per file in `lua/plugins/`). There is no `src/` or `tests/` tree; keep new files at the top level unless a subdirectory clearly improves organization.

## File Ownership & Editing Guide

| File(s) | Safe to edit | Notes |
|---------|-------------|-------|
| Config files (`vimrc`, `tmux.conf`, `gitconfig`, etc.) | Yes | Test with `setup.sh` after changes |
| `nvim/lua/plugins/*.lua` | Yes | Each file = one plugin spec. Add new plugins as new files. Run `:Lazy! sync` after |
| `nvim/lua/config/*.lua` | Yes | Options, keymaps, autocmds. Changes affect all nvim users |
| `lib/common.sh` | Careful | Shared by all scripts — changes affect `setup.sh`, `deploy.sh`, `install_claude_plugins.sh`, `uninstall.sh` |
| `setup.sh` `render_*()` functions | Careful | Changes affect all generated compat files in `~/.server-configs-generated/` |
| `deploy.sh` auth/copy steps | Careful | Test with `--help` and `--yes` flags. Auth logic is security-sensitive |
| `~/.server-configs-generated/*` | Never | Overwritten by `setup.sh` on every run |
| Auth files (`.credentials.json`, `auth.json`, `hosts.yml`) | Never committed | Listed in `.gitignore`. Copied securely by `deploy.sh` |

## Build, Test, and Development Commands

Use the scripts directly from the repo root.

- `./setup.sh` installs tools and symlinks configs into `$HOME`.
- `./setup.sh --force` reinstalls tools even if they already exist.
- `./deploy.sh --help` shows deploy options for remote server setup.
- `./deploy.sh --yes` skips confirmation prompts during deploy.
- `./uninstall.sh --yes` removes symlinks and tool installs non-interactively.
- `bash -n setup.sh deploy.sh uninstall.sh install_claude_plugins.sh lib/common.sh` runs a syntax check.

## Script Flag Conventions

| Script | Flag | Purpose |
|--------|------|---------|
| `setup.sh` | `--force` | Reinstall CLI tools even if already present |
| `deploy.sh` | `-y`, `--yes` | Skip all interactive confirmations |
| `deploy.sh` | `--force-copy` | Re-copy files even if remote content matches |
| `deploy.sh` | `-h`, `--help` | Show usage information |
| `uninstall.sh` | `--yes` | Skip confirmations (non-interactive removal) |
| `uninstall.sh` | `--help` | Show usage information |

## Coding Style & Naming Conventions

Scripts use Bash with `#!/usr/bin/env bash` and `set -uo pipefail`. Follow the existing style: 4-space indentation, lowercase function names, uppercase variables for exported or global state (`DIR`, `FAILURES`, `BIN_DIR`), and quoted expansions. Keep paths relative to `"$DIR"` inside scripts rather than hardcoding absolute paths. Prefer idempotent helpers such as `backup_and_link` and `run_step` over inline repeated logic.

## Error Handling Pattern

All scripts use a consistent error handling approach:

1. **`FAILURES=()`** array tracks non-fatal errors across the run.
2. **`run_step "name" command`** wraps each major operation — logs success/failure, appends to `FAILURES` on error, and optionally prompts to continue (unless `AUTO_YES=true`).
3. **`retry command`** wraps network calls with 3 attempts and a 2-second delay between retries.
4. Scripts **do not use `set -e`**. Individual step failures are recorded but don't abort the script. A summary of all failures is printed at the end.
5. `AUTO_YES=true` (set by `--yes` flag) suppresses interactive failure prompts for non-interactive use.

## Testing Guidelines

There is no automated test harness. Contributors should treat syntax checks and manual smoke tests as required.

### Shell config changes

```bash
bash -n bashrc_exports bashrc_aliases
shellcheck --severity=warning --exclude=SC1091 bashrc_exports bashrc_aliases
# Source in a fresh shell to verify no errors
```

### Script changes (`setup.sh`, `deploy.sh`, `uninstall.sh`)

```bash
bash -n setup.sh deploy.sh uninstall.sh install_claude_plugins.sh lib/common.sh
shellcheck --severity=warning --exclude=SC1091 setup.sh deploy.sh uninstall.sh install_claude_plugins.sh lib/common.sh
# Run affected script to smoke test
./setup.sh                    # after setup.sh changes
./deploy.sh --help            # after deploy.sh changes (safe, no side effects)
./uninstall.sh --help         # after uninstall.sh changes
```

### Neovim changes

```bash
nvim --headless '+Lazy! sync' +qa     # Regenerate lock file if plugin specs changed
nvim -c ':messages' -c ':qa'          # Check for startup errors
# Open nvim normally and verify no errors in :messages
```

### Setup.sh compat changes

```bash
./setup.sh                            # Regenerates ~/.server-configs-generated/
ls -la ~/.server-configs-generated/   # Verify expected files exist
# Inspect generated files for correctness
```

Document the exact commands you ran in the PR.

## Commit & Pull Request Guidelines

Recent commits use short, imperative, sentence-case subjects such as `Fix setup-token command to claude auth setup-token` and `Install Codex from GitHub binary release instead of npm`. Keep commits focused on one behavior change. PRs should summarize user-visible impact, list manual validation steps, call out any changes to prompts/authentication/token handling, and link related issues when applicable. Screenshots are unnecessary unless terminal output formatting is the main change.

When modifying config files, update the corresponding doc in `docs/` to keep references accurate.

## Security & Configuration Tips

These scripts modify `$HOME`, install binaries, and may handle SSH, OAuth, or GitHub tokens. Never commit real credentials, and avoid changing default install paths or remote-copy behavior without explaining the risk and rollback path.
