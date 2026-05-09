# server-configs

Personal dotfiles and server bootstrap scripts for Linux/HPC and macOS systems.

## Quickstart

### Fresh machine (local)

```bash
git clone <this-repo> ~/.server-configs
cd ~/.server-configs
./setup.sh               # idempotent — re-run is safe
./setup.sh --force       # reinstall CLI tools even if present
./setup.sh --dry-run     # show planned steps without changing files
```

On macOS, `setup.sh` uses Homebrew for managed CLI tools when `brew` is already installed. It does not install Homebrew automatically.

### Remote server

```bash
./deploy.sh              # interactive: pick host, auth method, steps
./deploy.sh --yes        # non-interactive (accept defaults)
./deploy.sh --force-copy # re-copy files even if remote matches
```

`deploy.sh` authenticates once via SSH ControlMaster, then multiplexes all subsequent commands. Supports password, SSH key, custom key path, 2FA/DUO, and SSH config aliases. Use `--help` for full usage.

GitHub CLI auth is recreated on the remote from the local `gh auth token` before cloning, bootstrapping `gh` to `~/.local/bin` on Linux remotes when needed. If the token is already stored in plaintext locally, `deploy.sh` can fall back to copying `hosts.yml`. Claude and Codex copy only known auth files (`~/.claude/.credentials.json`, `~/.codex/auth.json`); keychain-backed Claude auth is reported as non-transferable and must be set up on the remote with `claude auth login` or `claude setup-token`.

### Uninstall

```bash
./uninstall.sh           # interactive per-component removal
./uninstall.sh --yes     # remove everything non-interactively
```

Restores `.bak` backups of any files that were replaced.

### Validation

```bash
bash -n setup.sh deploy.sh uninstall.sh install_claude_plugins.sh lib/common.sh .githooks/pre-commit test_regressions.sh bashrc_exports bashrc_aliases
shellcheck --severity=warning --exclude=SC1091 setup.sh deploy.sh uninstall.sh install_claude_plugins.sh lib/common.sh .githooks/pre-commit test_regressions.sh bashrc_exports bashrc_aliases
bash test_regressions.sh
HOME="$(mktemp -d)" ./setup.sh --dry-run
```

---

## What Gets Installed

### Config Files

| Repo file | Installed to | Method |
|-----------|-------------|--------|
| `bashrc_exports` | `~/.bashrc_exports` | symlink |
| `bashrc_aliases` | `~/.bashrc_aliases` | symlink |
| `vimrc` | `~/.vimrc` | symlink |
| `nvim/` | `~/.config/nvim/` | symlink |
| `tmux.conf` | `~/.tmux.conf` | symlink |
| `gitconfig` | `~/.gitconfig` | symlink |
| `sshconfig` | `~/.ssh/config` | symlink |
| `inputrc` | `~/.inputrc` | symlink |
| `dircolors` | `~/.dircolors` | symlink |
| `claude_settings.json` | `~/.claude/settings.json` | copy |
| `codex_config.toml` | `~/.codex/config.toml` | copy |

Both `bashrc_exports` and `bashrc_aliases` are sourced from `~/.bashrc` (lines appended by `setup.sh` if not already present).

### CLI Tools

| Tool | Purpose |
|------|---------|
| `gh` | GitHub CLI |
| `glow` | Terminal markdown renderer |
| `nvim` | Neovim editor |
| `node` | Node.js LTS (for npx, Neovim plugins) |
| `uv` / `uvx` | Python package manager |
| `fzf` | Fuzzy finder (Ctrl+T, Ctrl+R, Alt+C) |
| `rg` | ripgrep — fast file content search |
| `fd` | find replacement |
| `bat` | cat replacement with syntax highlighting |
| `delta` | Git diff pager (side-by-side, syntax-highlighted) |
| `zoxide` | Smart `cd` replacement (`z` command) |
| `lazygit` | Git TUI |
| `btop` | System monitor |
| `jq` | JSON processor |
| `starship` | Cross-shell prompt |
| `atuin` | Shell history sync and search |
| `claude` | Claude Code CLI |
| `codex` | Codex CLI |

All tools install to `~/.local/bin/`. Installed via GitHub releases (no root required). On Linux, Neovim uses the official release tarball under `~/.local/opt/nvim` with a `~/.local/bin/nvim` symlink; old x86_64 glibc systems use Neovim's legacy glibc 2.17 release tarball.

---

## Repository Structure

```
.server-configs/
├── setup.sh                    # Local install: tools + symlinks
├── deploy.sh                   # Remote SSH bootstrap
├── uninstall.sh                # Clean removal + backup restore
├── install_claude_plugins.sh   # MCP servers for Claude Code
├── lib/
│   └── common.sh               # Shared helpers (run_step, retry, backup_and_link, ...)
├── bashrc_exports              # Shell environment, prompt, history
├── bashrc_aliases              # Shell aliases (git, nav, safety, modern tools)
├── vimrc                       # Vim config (plugin-free)
├── nvim/                       # Neovim config (lazy.nvim, 20 plugins)
│   ├── init.lua
│   ├── lazy-lock.json
│   └── lua/
│       ├── config/
│       │   ├── options.lua
│       │   ├── keymaps.lua
│       │   ├── autocmds.lua
│       │   └── lazy.lua
│       └── plugins/             # One file per plugin spec
│           ├── colorscheme.lua
│           ├── telescope.lua
│           ├── gitsigns.lua
│           ├── oil.lua
│           ├── treesitter.lua
│           ├── lualine.lua
│           ├── fugitive.lua
│           ├── diffview.lua
│           ├── editing.lua
│           ├── markdown.lua
│           ├── which-key.lua
│           └── indent-blankline.lua
├── tmux.conf                   # tmux config (prefix: Ctrl-a)
├── gitconfig                   # Git config (delta pager, rebase, aliases)
├── sshconfig                   # SSH multiplexing + keep-alive
├── inputrc                     # Readline (case-insensitive, history search)
├── dircolors                   # LS color scheme
├── claude_settings.json        # Claude Code settings
├── codex_config.toml           # Codex CLI settings
├── .githooks/
│   └── pre-commit              # bash -n + shellcheck on staged .sh files
├── .gitignore
├── CLAUDE.md                   # AI agent guidance
├── AGENTS.md                   # Contributor guidelines
└── docs/                       # Reference documentation
    ├── shell.md
    ├── vim.md
    ├── neovim.md
    ├── tmux.md
    ├── git.md
    ├── misc-configs.md
    └── ai-tools.md
```

---

## Key Concepts

### Version-Adaptive Compatibility

`setup.sh` detects tool versions and generates compatibility configs in `~/.server-configs-generated/`:

| Generated file | Source config | Adapts for |
|---------------|-------------|------------|
| `tmux.compat.conf` | `tmux.conf` | Terminal type, true color, passthrough |
| `vimrc.compat` | `vimrc` | Clipboard, listchars, Neovim features |
| `gitconfig.compat` | `gitconfig` | Credential helper |
| `bashrc_compat` | `bashrc_aliases` | Tool-specific flags by version |

The main configs `source`/`include` these generated files. Never edit the generated files directly — edit the `render_*()` functions in `setup.sh`.

### Backup & Restore

When `setup.sh` replaces an existing file with a symlink, the original is saved as `<filename>.bak`. Running `uninstall.sh` removes the symlinks and restores the `.bak` files.

### Vim vs Neovim

| | Vim (`vimrc`) | Neovim (`nvim/`) |
|---|---|---|
| Plugins | None (intentionally) | 20 via lazy.nvim |
| File explorer | netrw (built-in) | oil.nvim |
| Fuzzy finder | fzf (if installed) | Telescope |
| Status line | Custom `statusline` | lualine.nvim |
| Leader | Space | Space |

Both share the same core keybindings. See [docs/vim.md](docs/vim.md) and [docs/neovim.md](docs/neovim.md).

---

## Reference Documentation

Comprehensive lookup tables for every keybinding, alias, option, and setting:

| Document | Covers |
|----------|--------|
| [docs/shell.md](docs/shell.md) | All shell aliases, environment variables, prompt, history, fzf, tool integrations |
| [docs/vim.md](docs/vim.md) | Every vim option, keybinding, autocmd, color theme, status line |
| [docs/neovim.md](docs/neovim.md) | All 20 plugins, their keybindings, architecture, differences from vim |
| [docs/tmux.md](docs/tmux.md) | Every tmux keybinding, option, status bar, copy mode |
| [docs/git.md](docs/git.md) | Git config, delta, behavior settings, all aliases (git + shell) |
| [docs/misc-configs.md](docs/misc-configs.md) | SSH multiplexing, readline settings, dircolors |
| [docs/ai-tools.md](docs/ai-tools.md) | Claude Code settings, Codex config, MCP servers |
