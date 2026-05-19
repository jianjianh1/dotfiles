# Miscellaneous Configuration Reference

Covers SSH, readline, and dircolors — smaller configs grouped in one file.

---

## SSH (`sshconfig`)

Source: [`sshconfig`](../sshconfig) — wired into `~/.ssh/config` via an
`Include` directive (not a symlink). `setup.sh` ensures the line
`Include /path/to/this-repo/sshconfig` exists in `~/.ssh/config`; the file
itself stays user-owned, so per-host blocks you add never dirty the repo
working tree. `uninstall.sh` removes only the `Include` line and leaves
your host entries alone.

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

### Generated `notchpeak-compute` alias

`setup.sh` renders `~/.server-configs-generated/sshconfig.compute` and the repo's `sshconfig` `Include`s it. The alias auto-allocates a compute node behind a single Remote-SSH connect — see [VS Code remote helpers](shell.md#vs-code-remote-helpers) for the full flow. No manual stanzas needed.

### Suggested per-host stanzas (CHPC, manual compute-node path)

If you'd rather connect to a specific compute node by name (e.g., after `vscode-ssh-alloc` prints `notch324`), paste these into your own `~/.ssh/config` above the `Include` line — they're outside the auto-managed config because they're personal preferences:

```ssh-config
Host notchpeak
    HostName notchpeak.chpc.utah.edu

# Compute nodes (notch001, notch324, notch369, ...). OpenSSH Host
# patterns support only * and ?, so negate notchpeak rather than using
# a character class.
Host notch* !notchpeak
    ProxyJump notchpeak
```

Verify with `ssh -G notch324 | grep -iE '^proxyjump|^hostname'` — expect `proxyjump notchpeak` and `hostname notch324`.

### IntelliSense for CUDA/CMake projects

`setup.sh` seeds `~/.vscode-server/data/Machine/settings.json` with a non-recursive cpptools `browse.path`, an exclude list covering the HPC dotfile/installdir trees under `$HOME`, and — when nvcc is found via `$CUDA_HOME`/`$PATH`/the CHPC install tree — `compilerPath`, CUDA include dir, and `.cu`/`.cuh` -> `cpp` associations. The seed also points `C_Cpp.default.compileCommands` at `${workspaceFolder}/build/compile_commands.json`; to feed it from a CMake project, add `set(CMAKE_EXPORT_COMPILE_COMMANDS ON)` to `CMakeLists.txt` (or pass `-DCMAKE_EXPORT_COMPILE_COMMANDS=ON` to `cmake`) and configure into `build/`. The live file is left alone after the first hand-edit; re-running `setup.sh` only refreshes it while it still matches the recorded template.

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

Source: [`dircolors`](../dircolors) and [`dircolors.light`](../dircolors.light) — symlinked to `~/.dircolors` and `~/.dircolors.light`.

Loaded by shell exports via `dircolors -b`. The light palette is selected when `detect-theme` reports a light terminal; otherwise the dark palette is used. Defines `LS_COLORS` for `ls`, `tree`, and other tools.

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
