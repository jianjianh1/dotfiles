# Repository Guidelines

## Project Structure & Module Organization
This repository is flat and script-driven. Top-level files are the product: shell configs such as `vimrc`, `tmux.conf`, `gitconfig`, `sshconfig`, `bashrc_exports`, and `bashrc_aliases`, plus JSON/TOML settings for Claude and Codex. Operational logic lives in `setup.sh`, `deploy.sh`, `uninstall.sh`, and `install_claude_plugins.sh`. There is no `src/` or `tests/` tree; keep new files at the top level unless a subdirectory clearly improves organization.

## Build, Test, and Development Commands
Use the scripts directly from the repo root.

- `./setup.sh` installs tools and symlinks configs into `$HOME`.
- `./setup.sh --force` reinstalls tools even if they already exist.
- `./deploy.sh --help` shows deploy options for remote server setup.
- `./deploy.sh --yes` skips confirmation prompts during deploy.
- `./uninstall.sh --yes` removes symlinks and tool installs non-interactively.
- `bash -n setup.sh deploy.sh uninstall.sh install_claude_plugins.sh` runs a syntax check for the maintained scripts.

## Coding Style & Naming Conventions
Scripts use Bash with `#!/usr/bin/env bash` and `set -uo pipefail`. Follow the existing style: 4-space indentation, lowercase function names, uppercase variables for exported or global state (`DIR`, `FAILURES`, `BIN_DIR`), and quoted expansions. Keep paths relative to `"$DIR"` inside scripts rather than hardcoding absolute paths. Prefer idempotent helpers such as `backup_and_link` and `run_step` over inline repeated logic.

## Testing Guidelines
There is no automated test harness today. Contributors should treat syntax checks and manual smoke tests as required:

- run `bash -n ...` on edited scripts;
- run `./setup.sh` or `./deploy.sh --help` when changing entrypoints or flags;
- verify interactive prompt flows when editing deploy or auth logic.

Document the exact commands you ran in the PR.

## Commit & Pull Request Guidelines
Recent commits use short, imperative, sentence-case subjects such as `Fix setup-token command to claude auth setup-token` and `Install Codex from GitHub binary release instead of npm`. Keep commits focused on one behavior change. PRs should summarize user-visible impact, list manual validation steps, call out any changes to prompts/authentication/token handling, and link related issues when applicable. Screenshots are unnecessary unless terminal output formatting is the main change.

## Security & Configuration Tips
These scripts modify `$HOME`, install binaries, and may handle SSH, OAuth, or GitHub tokens. Never commit real credentials, and avoid changing default install paths or remote-copy behavior without explaining the risk and rollback path.
