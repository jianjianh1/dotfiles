# Miscellaneous Configuration Reference

Covers SSH, readline, and dircolors — smaller configs grouped in one file.

---

## SSH (`sshconfig`)

Source: [`sshconfig`](../sshconfig) — symlinked to `~/.ssh/config`.

All settings apply to `Host *` (every connection).

### Connection Multiplexing

| Setting | Value | Purpose |
|---------|-------|---------|
| `ControlMaster` | `auto` | Reuse existing connections automatically |
| `ControlPath` | `~/.ssh/sockets/%r@%h-%p` | Socket file location (by user@host-port) |
| `ControlPersist` | `600` | Keep master connection alive for 10 minutes after last session |

First SSH to a host authenticates normally. Subsequent connections to the same host reuse the socket — no re-authentication, near-instant connect.

**Prerequisite:** Create the socket directory:

```bash
mkdir -p ~/.ssh/sockets
```

### Keep-Alive

| Setting | Value | Purpose |
|---------|-------|---------|
| `ServerAliveInterval` | `60` | Send keep-alive every 60 seconds |
| `ServerAliveCountMax` | `3` | Disconnect after 3 missed keep-alives (3 minutes) |

### Key Management

| Setting | Value | Purpose |
|---------|-------|---------|
| `AddKeysToAgent` | `yes` | Auto-add keys to ssh-agent on first use |
| `IdentitiesOnly` | `yes` | Only offer keys explicitly configured (prevents agent key spam) |

---

## Readline (`inputrc`)

Source: [`inputrc`](../inputrc) — symlinked to `~/.inputrc`.

Configures all readline-based programs (bash, python REPL, gdb, etc.).

### Settings

| Setting | Value | Effect |
|---------|-------|--------|
| `completion-ignore-case` | `on` | Case-insensitive tab completion |
| `completion-map-case` | `on` | Treat `-` and `_` as equivalent in completion |
| `show-all-if-ambiguous` | `on` | Show all completions on first Tab (no double-tap) |
| `menu-complete-display-prefix` | `on` | Show common prefix, then cycle through options |
| `colored-stats` | `on` | Color completions by file type (like `ls`) |
| `colored-completion-prefix` | `on` | Highlight the common prefix in completions |
| `bell-style` | `none` | No audible or visual bell |
| `mark-symlinked-directories` | `on` | Append `/` to symlinked directories in completion |
| `visible-stats` | `on` | Show file type indicators in completions (like `ls -F`) |

### Keybindings

| Key | Action |
|-----|--------|
| `Up Arrow` | Search history backward (by prefix typed so far) |
| `Down Arrow` | Search history forward (by prefix typed so far) |
| `Ctrl+Right` | Move cursor forward one word |
| `Ctrl+Left` | Move cursor backward one word |

The history search bindings are especially useful: type the beginning of a command, then press Up to find matching commands from history.

---

## Dircolors (`dircolors`)

Source: [`dircolors`](../dircolors) — symlinked to `~/.dircolors`.

Loaded by `bashrc_exports` via `eval "$(dircolors -b ~/.dircolors)"`. Defines `LS_COLORS` for `ls`, `tree`, and other tools.

### Color Assignments by Category

| Category | Style | Examples |
|----------|-------|---------|
| Directories | Blue, bold | All directories |
| Symbolic links | Cyan, bold | All symlinks |
| Executables | Green, bold | Scripts, binaries |
| Archives | Red, bold | `.tar`, `.gz`, `.zip`, `.7z`, `.deb`, `.rpm` |
| Images | Magenta, bold | `.jpg`, `.png`, `.gif`, `.svg`, `.bmp`, `.ico` |
| Audio/Video | Cyan, bold | `.mp3`, `.flac`, `.mp4`, `.mkv`, `.avi`, `.mov` |
| Documents | Yellow | `.pdf`, `.doc`, `.xls`, `.ppt`, `.odt` |
| Source code | Green | `.py`, `.js`, `.c`, `.h`, `.rb`, `.go`, `.rs` |
| Config files | — (default) | `.conf`, `.cfg`, `.ini`, `.yaml`, `.toml` |
