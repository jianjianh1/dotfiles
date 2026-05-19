# Shell Configuration Reference

Sources: [`bashrc_exports`](../bashrc_exports), [`bashrc_aliases`](../bashrc_aliases)

Both files are symlinked into `$HOME` and sourced from `~/.bashrc`. Each also sources `~/.server-configs-generated/bashrc_compat` at the end for version-adaptive settings.

---

## Environment (`bashrc_exports`)

### Guard

Only runs in interactive shells (`[[ $- == *i* ]] || return`).

### PATH

```
~/.local/bin prepended to $PATH
```

### History

| Variable | Value | Purpose |
|----------|-------|---------|
| `HISTSIZE` | `50000` | Commands kept in memory |
| `HISTFILESIZE` | `100000` | Commands kept on disk |
| `HISTCONTROL` | `ignoreboth:erasedups` | Skip duplicates and space-prefixed commands |
| `HISTIGNORE` | `ls:cd:cd -:pwd:exit:clear` | Don't record trivial commands |
| `HISTTIMEFORMAT` | `%F %T  ` | Timestamp each entry (YYYY-MM-DD HH:MM:SS) |

```bash
shopt -s histappend   # Append, don't overwrite, on shell exit
```

### Shell Options

| Option | Effect |
|--------|--------|
| `checkwinsize` | Update LINES/COLUMNS after each command |
| `globstar` | `**` matches recursively in pathnames |
| `cdspell` | Autocorrect minor `cd` typos |
| `dirspell` | Autocorrect directory name typos in completion |
| `autocd` | Type a directory name to `cd` into it |

`globstar` and `autocd` are guarded so older Bash builds, including macOS Bash 3.2, skip them without startup errors.

### Colors

| Variable | Value | Purpose |
|----------|-------|---------|
| `CLICOLOR` | `1` | Enable color output (macOS convention) |
| `GCC_COLORS` | `error=01;31:warning=01;35:...` | Colored GCC diagnostics |

### Less

```bash
LESS='-iRQ'   # case-insensitive search, raw colors, no bell
```

Also enables `lesspipe` for non-text file previewing if available.

### Locale

Tries these UTF-8 locales in order: `C.UTF-8` → `en_US.UTF-8` → `en_US.utf8`. Falls back silently if none are available.

### FZF

| Variable | Value | Condition |
|----------|-------|-----------|
| `FZF_DEFAULT_OPTS` | `--height 40% --layout=reverse --border` | Always |
| `FZF_DEFAULT_COMMAND` | `fd --type f --hidden --exclude .git` | If `fd` installed |
| `FZF_CTRL_T_COMMAND` | Same as `FZF_DEFAULT_COMMAND` | If `fd` installed |
| `FZF_ALT_C_COMMAND` | `fd --type d --hidden --exclude .git` | If `fd` installed |

### Bat

```bash
BAT_THEME="auto"
BAT_THEME_DARK="TwoDark"
BAT_THEME_LIGHT="GitHub"
```

Bat auto-detects the terminal background and uses the configured dark/light palettes.

### Theme detection & override

`SERVER_CONFIGS_THEME` (`light`|`dark`) is set at shell startup via the shared `detect-theme` helper (OSC 11 → VS Code `storage.json` → Apple Terminal → `COLORFGBG` → dark fallback). On VS Code Remote-SSH the helper also reads `~/.vscode-server/data/User/globalStorage/storage.json`. When auto-detect picks wrong (common on tmux < 3.3 inside Remote-SSH with no remote `storage.json`), use:

```bash
theme light   # force light palette
theme dark    # force dark palette
theme auto    # clear cache and re-detect
```

Inside tmux the function propagates the value via `tmux set-environment -g` and re-sources `~/.tmux-theme.conf` to repaint existing panes. Running nvim/vim instances cache `&background` at startup; flip them with `:set background=light` / `:set background=dark` (handled by the colorscheme's `OptionSet` autocmd).

### Dircolors

Loads `~/.dircolors` or `~/.dircolors.light` via `dircolors -b` if both the file and command exist. The light palette is selected when `detect-theme` reports a light terminal.

### Prompt

Format: `user:~/dir (branch)$`

- Green bold username, blue bold working directory, yellow git branch (via `__git_branch()`)
- Terminal title set to `user: ~/dir` for xterm/rxvt terminals
- `__report_current_dir()` reports `$PWD` to tmux and iTerm2 for directory tracking

### Bash Completion

Sources `/usr/share/bash-completion/bash_completion` or `/etc/bash_completion` if available.

### Default Editor

Prefers `nvim` if available, falls back to `vim`. Sets both `EDITOR` and `VISUAL`.

---

## Aliases (`bashrc_aliases`)

### Navigation

| Alias | Expands to |
|-------|------------|
| `..` | `cd ..` |
| `...` | `cd ../..` |
| `....` | `cd ../../..` |

### File Listing

| Alias | With `eza` | GNU `ls` fallback | macOS fallback |
|-------|-----------|-------------------|----------------|
| `ls` | `eza --group-directories-first` | `ls --color=auto` | `ls -G` |
| `ll` | `eza -la --group-directories-first --git` | `ls -alFh --color=auto` | `ls -alFhG` |
| `la` | `eza -a --group-directories-first` | `ls -A --color=auto` | `ls -AG` |
| `lt` | `eza -T --level=2` | *(not defined)* | *(not defined)* |
| `l` | `ls -CF` | `ls -CF` | `ls -CF` |

### Grep

| Alias | Expands to |
|-------|------------|
| `grep` | `grep --color=auto` |
| `fgrep` | `fgrep --color=auto` |
| `egrep` | `egrep --color=auto` |

### Git

| Alias | Expands to |
|-------|------------|
| `gs` | `git status -sb` |
| `ga` | `git add` |
| `gc` | `git commit` |
| `gp` | `git push` |
| `gpu` | `git pull` |
| `gl` | `git log --oneline --graph --decorate -20` |
| `gla` | `git log --oneline --all --graph -20` |
| `gd` | `git diff` |
| `gds` | `git diff --staged` |
| `gco` | `git checkout` |
| `gcb` | `git checkout -b` |
| `gb` | `git branch` |
| `lg` | `lazygit` |

See also: [Git config aliases](git.md#aliases-gitconfig)

### Safety Nets

| Alias | Expands to | Purpose |
|-------|------------|---------|
| `rm` | `rm -I` | Prompt before removing >3 files |
| `mv` | `mv -i` | Prompt before overwrite |
| `cp` | `cp -i` | Prompt before overwrite |

### Disk Usage

| Alias | Expands to |
|-------|------------|
| `df` | `df -h` |
| `du` | `du -h` |
| `dud` | `du -d 1 -h \| sort -hr` |

### System / Quick Look

| Alias | Expands to | Purpose |
|-------|------------|---------|
| `h` | `history \| tail -30` | Recent history |
| `j` | `jobs -l` | Running jobs |
| `ports` | `ss -tulnp` or `lsof -nP -iTCP -sTCP:LISTEN` | Listening ports |
| `myip` | `curl -s ifconfig.me` | Public IP |
| `cls` | `clear` | Clear terminal |
| `path` | `echo -e ${PATH//:/\\n}` | PATH entries, one per line |
| `now` | `date +"%Y-%m-%d %H:%M:%S"` | Current timestamp |
| `open` | `xdg-open` | Linux default-app opener when available; macOS keeps native `open` |

### tmux

| Alias | Expands to | Purpose |
|-------|------------|---------|
| `ta` | `tmux attach -t` | Attach to session |
| `tn` | `tmux new -s` | New named session |
| `tl` | `tmux list-sessions` | List sessions |
| `tk` | `tmux kill-session -t` | Kill session |

### Modern Tool Replacements (guarded)

These only activate if the tool is installed:

| Alias | Replacement | Original |
|-------|-------------|----------|
| `cat` | `bat --paging=never` | `cat` |
| `ff` | `fd` | fast file search helper |
| `vim` / `vi` | `nvim` | `vim` / `vi` |

### Tool Integrations

| Tool | Integration |
|------|-------------|
| `zoxide` | `eval "$(zoxide init bash)"` — enhanced `cd` with `z` command |
| `fzf` | `eval "$(fzf --bash)"` — Ctrl+T (file), Ctrl+R (history), Alt+C (cd) |
| `.fzf.bash` | Legacy fzf integration file (fallback) |

### VS Code remote helpers

| Function | Purpose |
|----------|---------|
| `vscode-tunnel [name]` | Run `code tunnel` on the current host. Default tunnel name = short hostname. |
| `vscode-tunnel-compute [name] [dir]` | Submit a detached `sbatch` job that runs `code tunnel` on a compute node. Idempotent: reuses any RUNNING `vscode-tunnel-<name>` job. Default tunnel name = `notch-dev`. |
| `vscode-tunnel-release [name]` | `scancel` the `vscode-tunnel-<name>` job (default name: `notch-dev`). |
| `vscode-ssh-alloc [name]` | Submit a long-lived `sbatch --wrap='sleep infinity'` allocation and print the assigned compute node so Remote-SSH can dial it. Default job name = `vscode-ssh`. |
| `vscode-ssh-release [name]` | `scancel` all jobs matching the name (default: `vscode-ssh`). |
| `vscode-doctor` | Print hostname (with login-node warning), `vscode-*` SLURM allocations, cpptools cache path/size, and a tail of the latest cpptools log. Read-only. |
| `vscode-cache-clear` | Confirm-then-delete the cpptools IntelliSense index (`intelliSenseCachePath`). Use when results go stale or the parser wedges. |
| `prefetch-vscode-server <commit>` | Stage `~/.vscode-server/bin/<commit>` so first Remote-SSH connect is fast or works offline. |

**Never let `vscode-server` run on a CHPC login node.** Arbiter caps login-node processes at 4 cores / 8 GB, which is not enough for the C/C++ extension's IntelliSense scan to complete — it gets stuck on "scanning" indefinitely. The shipped fix is the `notchpeak-compute` Remote-SSH alias below; `vscode-tunnel-compute` and `vscode-ssh-alloc` are the older manual paths.

#### Remote-SSH path (`notchpeak-compute` alias)

`setup.sh` writes `~/.server-configs-generated/sshconfig.compute`, included by the universal `sshconfig`, which defines:

```
Host notchpeak-compute
    HostName notchpeak.chpc.utah.edu
    User <you>
    ProxyCommand <repo>/bin/vscode-compute-ssh-proxy.sh notchpeak.chpc.utah.edu <you>
```

When you connect (`ssh notchpeak-compute`, or VS Code → "Remote-SSH: Connect to Host → `notchpeak-compute`"), the ProxyCommand:

1. SSHes once into `notchpeak.chpc.utah.edu`.
2. Runs `~/.server-configs/bin/ensure-vscode-alloc.sh`, which reuses any existing RUNNING `vscode-ssh` SLURM job or submits a new `sbatch --wrap='sleep infinity'` and waits for a node.
3. `exec`s `ssh -W <node>:22 notchpeak…` so the outer client lands on the assigned compute node.

The allocation persists across disconnects; release it with `vscode-ssh-release` (or it walltime-expires). Override sbatch defaults with the same `VSCODE_SSH_{ACCOUNT,PARTITION,QOS,CORES,MEM,TIME}` env vars used by `vscode-ssh-alloc`, exported on the login node (e.g. via `~/.bashrc`).

#### Tunnel path (`vscode-tunnel-compute`)

`vscode-tunnel-compute [<name>] [<dir>]` submits the tunnel as a **detached** `sbatch` job and returns within a few seconds. The function:

1. If a `vscode-tunnel-<name>` job is already RUNNING, reuses it and reprints the `https://vscode.dev/tunnel/<name>` URL — no second sbatch.
2. Otherwise `sbatch --wrap="exec code tunnel --name <name> --accept-server-license-terms"`, names the job `vscode-tunnel-<name>`, and points `-o`/`-e` at `~/.local/share/vscode-tunnel-<name>.log` so the URL banner and any errors are recoverable after scrollback ends.
3. Polls `squeue` for node assignment, then tails the log for up to 30 s and surfaces whichever of the following lands first: the **device-code prompt** (one-time first run from a compute node — see below) or the **`Open this link in your browser`** banner (success).

The tunnel survives the launching terminal closing. Stop it with `vscode-tunnel-release [<name>]` (or `scancel <jobid>`); the SLURM allocation also ends when walltime expires.

**First-run auth from a compute node.** `code tunnel user show` on a login node passes because the token decrypts via the gnome-keyring daemon running on that login node. Compute nodes have no keyring service, so the *first* tunnel job there can't read the existing token and falls back to a device-code login. `vscode-tunnel-compute` surfaces the device-code URL + 8-character code prominently — visit `https://github.com/login/device`, paste the code, approve. After that, `code tunnel` re-stores the token in a keyringless mode that subsequent compute-node runs can read silently. Bonus side effect: the same stored token still works on the login node too (the keyring backend reads through to the file fallback).

Default allocation is `notchpeak-shared-short` (no account needed, 8 h max, 8 cores / 32 GB). Override per-invocation:

| Variable | Default |
|----------|---------|
| `VSCODE_TUNNEL_ACCOUNT` | `notchpeak-shared-short` |
| `VSCODE_TUNNEL_PARTITION` | `notchpeak-shared-short` |
| `VSCODE_TUNNEL_QOS` | `notchpeak-shared-short` |
| `VSCODE_TUNNEL_CORES` | `8` |
| `VSCODE_TUNNEL_MEM` | `32G` |
| `VSCODE_TUNNEL_TIME` | `8:00:00` |

#### Manual Remote-SSH path (`vscode-ssh-alloc`)

Predates `notchpeak-compute`. Use only if you need a hand-controlled allocation (e.g., custom partition/account triples beyond the alias defaults, or you want to land on a specific compute node):

```
# on notchpeak1:
vscode-ssh-alloc                  # prints: Allocation ready on: notch324
# from local VS Code:
#   Cmd/Ctrl-Shift-P → "Remote-SSH: Connect to Host" → notch324
# when done:
vscode-ssh-release
```

For the bare node name to work in VS Code, your `~/.ssh/config` needs `Host notchpeak` + a `Host notch* !notchpeak` ProxyJump block — see the [suggested CHPC stanzas](misc-configs.md#suggested-per-host-stanzas-chpc) to paste in. Unlike the tunnel path this uses `sbatch --wrap='sleep infinity'`, so the allocation survives terminal disconnects and reconnects until you `vscode-ssh-release` (or wall-time expires). Override the SLURM triple/limits with `VSCODE_SSH_{ACCOUNT,PARTITION,QOS,CORES,MEM,TIME}` (same defaults as the tunnel variables).

#### Shared cpptools settings

`setup.sh` seeds `~/.vscode-server/data/Machine/settings.json` (only if absent) with cpptools-friendly defaults: cache path on `/scratch/general/vast/$USER`, lower cache size, low-priority workspace parse, and exclusion patterns for `build/`, `.venv/`, `node_modules/`. These apply to both transport paths (tunnel and Remote-SSH share the same `~/.vscode-server` tree on the compute node). The canonical source lives at `~/.server-configs-generated/vscode-machine-settings.json`; edit the seeded file freely (it is never overwritten by re-runs).

### Compat Layer

`~/.server-configs-generated/bashrc_compat` is sourced at the end of both files. It carries a load-once guard and any environment-module load lines emitted by `setup.sh` (e.g. `module load claude-code`) when tools were satisfied via Lmod.
