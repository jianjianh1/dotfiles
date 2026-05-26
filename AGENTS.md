# Repository Guidelines

## Project Structure & Module Organization

Configs are grouped by topic into subdirectories:

- `shell/` — bash/zsh rc files, readline, dircolors, starship prompt
- `editor/` — `vimrc` and the `nvim/` Neovim tree (one plugin spec per file in `lua/plugins/`)
- `tmux/`, `git/`, `ai/` — single-tool configs
- `scripts/` — `install_claude_plugins.sh`, `detect-theme.sh`, `chpc-allocs.py`, `test_regressions.sh`
- `lib/` — shared shell helpers (`common.sh`, `vscode-tunnel.sh`)
- `docs/` — per-tool reference tables

Operational logic lives in three top-level scripts: `install.sh` (local install + symlinks + render compat configs), `deploy.sh` (remote SSH bootstrap), `uninstall.sh` (clean removal + backup restore). When adding a new config file, drop it into the matching topical subdir and wire it from `install.sh`.

## File Ownership & Editing Guide

| File(s) | Safe to edit | Notes |
|---------|-------------|-------|
| Config files under `shell/`, `editor/`, `tmux/`, `git/`, `ai/` | Yes | Test with `install.sh` after changes |
| `editor/nvim/lua/plugins/*.lua` | Yes | Each file = one plugin spec. Add new plugins as new files. Run `:Lazy! sync` after |
| `editor/nvim/lua/config/*.lua` | Yes | Options, keymaps, autocmds. Changes affect all nvim users |
| `lib/common.sh` | Careful | Shared by all scripts — changes affect `install.sh`, `deploy.sh`, `scripts/install_claude_plugins.sh`, `uninstall.sh` |
| `install.sh` `render_*()` functions | Careful | Changes affect all generated compat files in `~/.dotfiles-generated/` |
| `deploy.sh` auth/copy steps | Careful | Test with `--help` and `--yes` flags. Auth logic is security-sensitive |
| `~/.dotfiles-generated/*` | Never | Overwritten by `install.sh` on every run |
| Auth files (`.credentials.json`, `auth.json`, `hosts.yml`) | Never committed | Listed in `.gitignore`. Copied securely by `deploy.sh` |

## Build, Test, and Development Commands

Use the scripts directly from the repo root.

- `./install.sh` installs tools and symlinks configs into `$HOME`.
- `./install.sh --force` reinstalls tools even if they already exist.
- `./install.sh --dry-run` shows planned setup steps without changing files.
- `./deploy.sh --help` shows deploy options for remote server setup.
- `./deploy.sh --yes` skips confirmation prompts during deploy.
- `./uninstall.sh --yes` removes symlinks and tool installs non-interactively.
- `bash -n install.sh deploy.sh uninstall.sh scripts/install_claude_plugins.sh lib/common.sh .githooks/pre-commit scripts/test_regressions.sh shell/bashrc_exports shell/bashrc_aliases` runs a syntax check.

## Script Flag Conventions

| Script | Flag | Purpose |
|--------|------|---------|
| `install.sh` | `--force` | Reinstall CLI tools even if already present |
| `install.sh` | `--dry-run`, `-n` | Show planned setup steps without changing files |
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
bash -n shell/bashrc_exports shell/bashrc_aliases
shellcheck --severity=warning --exclude=SC1091 shell/bashrc_exports shell/bashrc_aliases
# Source in a fresh shell to verify no errors
```

### Script changes (`install.sh`, `deploy.sh`, `uninstall.sh`)

```bash
bash -n install.sh deploy.sh uninstall.sh scripts/install_claude_plugins.sh lib/common.sh .githooks/pre-commit scripts/test_regressions.sh shell/bashrc_exports shell/bashrc_aliases
shellcheck --severity=warning --exclude=SC1091 install.sh deploy.sh uninstall.sh scripts/install_claude_plugins.sh lib/common.sh .githooks/pre-commit scripts/test_regressions.sh shell/bashrc_exports shell/bashrc_aliases
bash scripts/test_regressions.sh
# Run affected script to smoke test
./install.sh --dry-run          # after install.sh changes (safe, no side effects)
./install.sh                    # after install.sh changes
./deploy.sh --help              # after deploy.sh changes (safe, no side effects)
./uninstall.sh --help           # after uninstall.sh changes
```

### Neovim changes

```bash
nvim --headless '+Lazy! sync' +qa     # Regenerate lock file if plugin specs changed
nvim -c ':messages' -c ':qa'          # Check for startup errors
# Open nvim normally and verify no errors in :messages
```

### Install.sh compat changes

```bash
./install.sh                    # Regenerates ~/.dotfiles-generated/
ls -la ~/.dotfiles-generated/   # Verify expected files exist
# Inspect generated files for correctness
```

Document the exact commands you ran in the PR.

## Commit & Pull Request Guidelines

Recent commits use short, imperative, sentence-case subjects such as `Fix setup-token command to claude auth setup-token` and `Install Codex from GitHub binary release instead of npm`. Keep commits focused on one behavior change. PRs should summarize user-visible impact, list manual validation steps, call out any changes to prompts/authentication/token handling, and link related issues when applicable. Screenshots are unnecessary unless terminal output formatting is the main change.

When modifying config files, update the corresponding doc in `docs/` to keep references accurate.

## Security & Configuration Tips

These scripts modify `$HOME`, install binaries, and may handle SSH, OAuth, or GitHub tokens. Never commit real credentials, and avoid changing default install paths or remote-copy behavior without explaining the risk and rollback path.
