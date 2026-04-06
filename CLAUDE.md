# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Personal dotfiles/server configuration repo. Contains vim, tmux, and a setup script that symlinks configs into `$HOME` and installs CLI tools (glow, Claude Code).

## Setup

```bash
./setup.sh
```

This symlinks `vimrc` → `~/.vimrc` and `tmux.conf` → `~/.tmux.conf` (backing up existing files), creates `~/.vim/undodir`, and installs glow + Claude Code if missing.

## Key Details

- **setup.sh** uses `set -euo pipefail` and derives its own directory via `$(cd "$(dirname "$0")" && pwd)` — keep paths relative to `$DIR`, not hardcoded.
- **vimrc** is plugin-free (uses only built-in vim features + netrw). Don't add plugin manager or plugin dependencies.
- **tmux prefix** is `Ctrl-a` (not the default `Ctrl-b`).
- **Indentation**: vimrc defaults to 4-space tabs; web filetypes (html/css/js/ts/json/yaml) use 2-space via autocmd.
- Glow is used for markdown preview in vim (`<leader>m`).
