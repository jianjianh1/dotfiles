# Neovim Configuration Reference

Source: [`nvim/`](../nvim/) directory, symlinked to `~/.config/nvim/`.

Uses [lazy.nvim](https://github.com/folke/lazy.nvim) for plugin management. For the plugin-free Vim config, see [vim.md](vim.md).

`setup.sh` installs Neovim on Linux from the official release tarball into `~/.local/opt/nvim` and links `~/.local/bin/nvim`. On old x86_64 glibc systems, it falls back to Neovim's legacy glibc 2.17 release tarball instead of the AppImage path.

---

## Architecture

```
nvim/
├── init.lua                          # Entry point — loads config modules
├── lazy-lock.json                    # Plugin version lock
└── lua/
    ├── config/
    │   ├── options.lua               # vim.opt settings
    │   ├── keymaps.lua               # Core keybindings
    │   ├── autocmds.lua              # Autocommands
    │   └── lazy.lua                  # lazy.nvim bootstrap
    └── plugins/
        ├── colorscheme.lua           # tokyonight
        ├── lualine.lua               # Status line
        ├── telescope.lua             # Fuzzy finder
        ├── gitsigns.lua              # Git gutter
        ├── treesitter.lua            # Syntax parsing
        ├── oil.lua                   # File explorer
        ├── markdown.lua              # Markdown preview
        ├── editing.lua               # autopairs, surround
        ├── fugitive.lua              # Git wrapper
        ├── diffview.lua              # Diff viewer
        ├── which-key.lua             # Keybinding hints
        └── indent-blankline.lua      # Indent guides
```

**Load order:** `init.lua` → `config/options` → `config/keymaps` → `config/autocmds` → `config/lazy` → all `plugins/*.lua` specs (lazy-loaded).

---

## Differences from Vim Config

| Feature | Vim (`vimrc`) | Neovim (`nvim/`) |
|---------|---------------|-------------------|
| Status line | Custom `statusline` | lualine.nvim (mode, branch, diff, diagnostics) |
| `laststatus` | `2` (per-window) | `3` (global) |
| `showmode` | on | off (lualine shows mode) |
| Listchars | ASCII (via compat) | Unicode: `tab:>>·,trail:·,extends:›,precedes:‹,nbsp:␣` |
| File explorer | netrw (built-in) | oil.nvim (netrw disabled) |
| `<leader>m` | `!glow %` (terminal) | `MarkdownPreviewToggle` (browser) |
| Fuzzy finder | fzf (if installed) | Telescope |
| Color scheme | slate + custom highlights | tokyonight-storm + custom bg |
| Plugins | None | 20 (lazy-loaded) |

---

## Core Keybindings (`config/keymaps.lua`)

**Leader:** `Space`

These mirror the vimrc keybindings. See [vim.md keybindings](vim.md#keybindings) for shared mappings.

### General

| Key | Mode | Action |
|-----|------|--------|
| `<leader><space>` | n | Clear search highlight |
| `<leader>w` | n | Save file |
| `<leader>q` | n | Quit |
| `Y` | n | Yank to end of line |

### Window Navigation

| Key | Mode | Action |
|-----|------|--------|
| `Ctrl+h` | n | Move to left window |
| `Ctrl+j` | n | Move to below window |
| `Ctrl+k` | n | Move to above window |
| `Ctrl+l` | n | Move to right window |

### Window Resizing

| Key | Mode | Action |
|-----|------|--------|
| `Ctrl+Up` | n | Increase height by 2 |
| `Ctrl+Down` | n | Decrease height by 2 |
| `Ctrl+Left` | n | Decrease width by 2 |
| `Ctrl+Right` | n | Increase width by 2 |

### Visual Mode

| Key | Mode | Action |
|-----|------|--------|
| `J` | v | Move selection down |
| `K` | v | Move selection up |
| `p` | v | Paste without losing register |

### Scrolling & Search

| Key | Mode | Action |
|-----|------|--------|
| `Ctrl+d` | n | Half-page down (centered) |
| `Ctrl+u` | n | Half-page up (centered) |
| `n` | n | Next search match (centered) |
| `N` | n | Previous search match (centered) |
| `*` | n | Search word under cursor (stay put) |
| `#` | n | Reverse search word (stay put) |

### Folding

| Key | Mode | Action |
|-----|------|--------|
| `zO` | n | Open all folds |
| `zC` | n | Close all folds |
| `<leader>fi` | n | Switch to indent-based folding |
| `<leader>fm` | n | Switch to manual folding |

### Buffers

| Key | Mode | Action |
|-----|------|--------|
| `<leader>bn` | n | Next buffer |
| `<leader>bp` | n | Previous buffer |
| `<leader>bd` | n | Delete buffer |
| `<leader>bl` | n | List buffers |

### Neovim-Specific

| Key | Mode | Action |
|-----|------|--------|
| `<leader>m` | n | Preview markdown with glow (overridden by markdown-preview.nvim for `.md` files) |
| `<leader>t` | n | Open terminal |
| `<Esc><Esc>` | t | Exit terminal mode |

---

## Plugins

### Colorscheme: tokyonight

**File:** `plugins/colorscheme.lua`

- Style: `storm`
- Background override: `#1b2b34` (matches vimrc's Oceanic Next palette)
- Dark variant: `#162028`
- Comments: italic
- Functions: bold
- Keywords: not italic
- Loads eagerly (`lazy = false`, `priority = 1000`)

### Lualine (status line)

**File:** `plugins/lualine.lua`

| Section | Content |
|---------|---------|
| A (left) | Mode |
| B | Branch, diff stats, diagnostics |
| C | Filename (relative path) |
| X (right) | Filetype |
| Y | Progress (%) |
| Z | Location (line:col) |

- Theme: `tokyonight`
- Separators: `│` (no powerline arrows)
- Global status line (`globalstatus = true`)
- Loads eagerly

### Telescope (fuzzy finder)

**File:** `plugins/telescope.lua`

#### Keybindings

| Key | Action |
|-----|--------|
| `<leader>ff` | Find files |
| `<leader>fg` | Live grep (search file contents) |
| `<leader>fb` | Open buffers |
| `<leader>fh` | Help tags |
| `<leader>fr` | Resume last search |
| `<leader>fo` | Recent files (oldfiles) |
| `<leader>fw` | Grep word under cursor |
| `<leader>fd` | Diagnostics |
| `<leader>/` | Fuzzy search in current buffer |

#### Inside Telescope

| Key | Action |
|-----|--------|
| `Ctrl+j` | Move to next result |
| `Ctrl+k` | Move to previous result |
| `Esc` | Close Telescope |

#### Config

- Layout: horizontal, preview takes 55% width
- Ignored: `node_modules`, `.git/`, `build/`, `dist/`, `.cache/`
- Extension: `fzf-native` (requires `make` to build)
- Dependencies: plenary.nvim, nvim-web-devicons

### Oil (file explorer)

**File:** `plugins/oil.lua`

Replaces netrw as the default file explorer. Treats directories as editable buffers.

#### Entry

| Key | Action |
|-----|--------|
| `<leader>e` | Open Oil |
| `-` | Open Oil |

#### Inside Oil

| Key | Action |
|-----|--------|
| `Enter` | Open file/directory |
| `Ctrl+v` | Open in vertical split |
| `Ctrl+s` | Open in horizontal split |
| `Ctrl+t` | Open in new tab |
| `-` | Go to parent directory |
| `_` | Open current working directory |
| `gs` | Change sort order |
| `gx` | Open with external program |
| `g.` | Toggle hidden files |
| `g?` | Show help |
| `q` | Close Oil |

#### Config

- Columns: icon only
- Hidden files: shown by default
- netrw is disabled (`vim.g.loaded_netrw = 1`)

### Gitsigns (git gutter)

**File:** `plugins/gitsigns.lua`

Shows git status in the sign column. Loads on `BufReadPost` and `BufNewFile`.

#### Sign Characters

| Type | Character |
|------|-----------|
| Add | `│` |
| Change | `│` |
| Delete | `󰍵` |
| Top delete | `‾` |
| Change-delete | `~` |

#### Keybindings

| Key | Mode | Action |
|-----|------|--------|
| `]h` | n | Next hunk |
| `[h` | n | Previous hunk |
| `<leader>gp` | n | Preview hunk |
| `<leader>gb` | n | Blame line (full commit) |
| `<leader>gB` | n | Toggle inline blame |
| `<leader>gr` | n | Reset hunk |
| `<leader>gR` | n | Reset entire buffer |
| `<leader>ga` | n | Stage hunk |
| `<leader>gu` | n | Undo stage hunk |

Hunk navigation (`]h`/`[h`) falls back to `]c`/`[c` in diff mode.

### Fugitive (git wrapper)

**File:** `plugins/fugitive.lua`

| Key | Action |
|-----|--------|
| `<leader>gs` | Open git status (`:Git`) |

#### Available Commands

| Command | Action |
|---------|--------|
| `:Git` | Interactive git status |
| `:Gwrite` | Stage current file |
| `:Gread` | Checkout current file |
| `:Gdiffsplit` | Side-by-side diff |

Lazy-loaded on command or `<leader>gs`.

### Diffview (diff viewer)

**File:** `plugins/diffview.lua`

| Key | Action |
|-----|--------|
| `<leader>gd` | Open diff view (working tree vs index) |
| `<leader>gh` | Current file history |
| `<leader>gH` | Full branch history |

- Layout: `diff2_horizontal`
- Enhanced diff highlighting enabled
- Lazy-loaded on command or keybinding

### Treesitter (syntax parsing)

**File:** `plugins/treesitter.lua`

Provides syntax-tree-based highlighting, indentation, and incremental selection.

#### Installed Parsers

`bash`, `c`, `cpp`, `json`, `lua`, `luadoc`, `markdown`, `markdown_inline`, `python`, `regex`, `toml`, `vim`, `vimdoc`, `yaml`

Auto-install is disabled. To add a parser: `:TSInstall <language>`.

#### Incremental Selection

| Key | Mode | Action |
|-----|------|--------|
| `Ctrl+Space` | n/v | Init selection / expand to next node |
| `Backspace` | v | Shrink selection to previous node |

#### Features Enabled

- `highlight`: on
- `indent`: on
- `incremental_selection`: on (keymaps above)

Loads on `BufReadPost` and `BufNewFile`.

### Editing Helpers

**File:** `plugins/editing.lua`

#### nvim-autopairs

Auto-closes brackets, quotes, and parentheses. Activates on `InsertEnter`.

#### Commenting (built-in)

Neovim 0.10+ ships native commenting; no plugin needed.

| Key | Mode | Action |
|-----|------|--------|
| `gcc` | n | Toggle line comment |
| `gc{motion}` | n | Toggle comment over motion |
| `gc` | v | Toggle comment on selection |

Uses treesitter-aware `commentstring`.

#### nvim-surround

| Key | Mode | Action | Example |
|-----|------|--------|---------|
| `cs{old}{new}` | n | Change surrounding | `cs"'` changes `"hello"` → `'hello'` |
| `ds{char}` | n | Delete surrounding | `ds(` deletes `(hello)` → `hello` |
| `ys{motion}{char}` | n | Add surrounding | `ysiw"` wraps word in `"quotes"` |

Loads on `VeryLazy`.

### Which-Key (keybinding hints)

**File:** `plugins/which-key.lua`

Press `<leader>` and wait to see all available mappings in a popup.

#### Group Prefixes

| Prefix | Group |
|--------|-------|
| `<leader>f` | find (Telescope) |
| `<leader>g` | git (gitsigns, fugitive, diffview) |
| `<leader>b` | buffer |

Loads on `VeryLazy`.

### Indent-blankline (indent guides)

**File:** `plugins/indent-blankline.lua`

- Indent character: `│`
- Scope highlighting: enabled (shows current scope)
- Excluded filetypes: `help`, `lazy`, `mason`, `oil`
- Loads on `BufReadPost` and `BufNewFile`

### Markdown

**File:** `plugins/markdown.lua`

#### render-markdown.nvim (in-buffer)

Renders markdown directly in the buffer using Lua. Activates on `markdown` filetype.

- Headings: plain `#` prefix style (not icons)
- Code blocks: block-width rendering, no sign column
- Dependencies: treesitter, nvim-web-devicons

#### markdown-preview.nvim (browser)

Opens a live preview in your browser. Requires Node.js.

| Key | Filetype | Action |
|-----|----------|--------|
| `<leader>m` | markdown | Toggle browser preview |

This overrides the core `<leader>m` (glow) binding when editing `.md` files.

Build step runs `mkdp#util#install()` only if `node` is available.

### LSP (pyright + ruff + clangd + lua_ls)

**File:** `plugins/lsp.lua` (+ `config/compile_commands.lua`)

Tuned for a VS Code IntelliSense feel: low diagnostic noise, project-aware navigation, inlay hints, and `Ctrl+]` / `F12` to jump to definition.

#### Servers

| Server | Role | Notes |
|---|---|---|
| pyright | Python types, hover, go-to-def, auto-import | `typeCheckingMode=basic`, `diagnosticMode=openFilesOnly` (no workspace-wide spam) |
| ruff    | Python lint diagnostics | Hover disabled so pyright wins the popup |
| clangd  | C/C++ semantic | `--background-index --clang-tidy --header-insertion=iwyu --completion-style=detailed --function-arg-placeholders` |
| lua_ls  | Lua | Inlay hints enabled |

Installed via mason on first launch (`:Mason` to inspect). Add more with `ensure_installed` in `plugins/lsp.lua`.

#### Keybindings (active when an LSP attaches)

| Key | Mode | Action |
|-----|------|--------|
| `gd` / `<C-]>` / `<F12>` | n (F12 also i) | Go to definition |
| `<C-t>` | n | Pop back from definition (built-in tag stack) |
| `gr` / `<S-F12>` | n | References |
| `gI` | n | Implementation |
| `<leader>D` | n | Type definition |
| `K` / `gh` | n | Hover documentation |
| `<C-s>` | i | Signature help |
| `<leader>rn` / `<F2>` | n | Rename symbol |
| `<leader>ca` | n | Code action |
| `<leader>cd` | n | Show line diagnostics |
| `[d` / `]d` | n | Previous / next diagnostic |
| `<leader>uh` | n | Toggle inlay hints (buffers that support them) |
| `<leader>cs` | n | Switch source/header (clangd only) |

#### Project structure (C/C++)

clangd auto-discovers `compile_commands.json` by walking up from the source file. The config bootstraps it for you:

- **CMake projects** — on first clangd attach, runs `cmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=ON` in the background and symlinks `build/compile_commands.json` to the project root. clangd reloads automatically.
- **Make projects** — detection only. Run `:GenCompileCommands` to invoke `bear -- make` (because that command actually builds). To opt into auto-run, `touch .server-configs-bear-ok` at the project root.
- **Manual** — `:GenCompileCommands` always re-runs the appropriate generator, ignoring the per-session cache.

`compile_commands.json` discovery checks the project root and common build dirs (`build/`, `Build/`, `out/`, `cmake-build-{debug,release}/`).

#### Project structure (Python)

pyright finds imports via `pyrightconfig.json` or `pyproject.toml` at the project root. For src-layouts or anything non-trivial, drop a `pyrightconfig.json`:

```json
{
  "venvPath": ".",
  "venv": ".venv",
  "extraPaths": ["src"]
}
```

Otherwise pyright uses `autoSearchPaths` to guess.

#### Diagnostics display

- Virtual text inline: `● error message` (severity-sorted, no updates during insert).
- Float popup on `<leader>cd` with rounded border and source name when ambiguous.
- Signs: `✘` error / `▲` warn / `●` info / `○` hint.

#### Troubleshooting

- `:LspInfo` — which servers are attached to the current buffer, what they consider the root, log path.
- `:checkhealth lsp` — capability and binary checks.
- `:Mason` — install / update / inspect language servers.
- Heavy diagnostic noise? Make sure pyright sees a project root (presence of `pyproject.toml` / `setup.py` / `.git`) so `openFilesOnly` can do its job.

---

## Autocmds (`config/autocmds.lua`)

| Augroup | Event | Pattern | Action |
|---------|-------|---------|--------|
| `RestoreCursor` | `BufReadPost` | — | Return to last edit position |
| `WebIndent` | `FileType` | `html,css,javascript,typescript,json,yaml,lua` | Set 2-space indent |
| `StripWhitespace` | `BufWritePre` | `*` | Strip trailing whitespace (preserves cursor) |
| `HighlightYank` | `TextYankPost` | — | Flash yanked text for 200ms |
| `LargeFileTuning` | `BufReadPost` | — (>1MB) | Disable folds, cursorline, relativenumber, list, syntax, treesitter |

Note: Neovim adds `lua` to the WebIndent filetypes (vim does not).

---

## lazy.nvim Config (`config/lazy.lua`)

| Setting | Value | Purpose |
|---------|-------|---------|
| `defaults.lazy` | `true` | All plugins lazy-loaded by default |
| `install.colorscheme` | `tokyonight` | Colorscheme during initial install |
| `checker.enabled` | `false` | No automatic update checks |
| `change_detection.notify` | `false` | Silent config reload |

#### Disabled Built-in Plugins

- `netrwPlugin` (replaced by oil.nvim)
- `tohtml`
- `tutor`

#### Bootstrap

lazy.nvim is auto-installed from GitHub on first launch if not present. Plugin versions are locked in `lazy-lock.json`. To update plugins:

```bash
nvim --headless '+Lazy! sync' +qa
```

---

## Plugin Summary

| Plugin | Purpose | Load Event | Keybindings |
|--------|---------|------------|-------------|
| tokyonight.nvim | Colorscheme | Startup | — |
| lualine.nvim | Status line | Startup | — |
| telescope.nvim | Fuzzy finder | `<leader>f*`, `<leader>/` | 9 |
| telescope-fzf-native.nvim | Telescope speed | With Telescope | — |
| gitsigns.nvim | Git gutter | BufReadPost | 9 |
| vim-fugitive | Git commands | `<leader>gs`, `:Git` | 1 |
| diffview.nvim | Diff viewer | `<leader>gd/gh/gH` | 3 |
| oil.nvim | File explorer | `<leader>e`, `-` | 2 + 10 internal |
| nvim-treesitter | Syntax parsing | BufReadPost | 2 |
| render-markdown.nvim | In-buffer markdown | ft=markdown | — |
| markdown-preview.nvim | Browser preview | `<leader>m` (markdown) | 1 |
| nvim-autopairs | Auto-close brackets | InsertEnter | — |
| nvim-surround | Surround text | VeryLazy | cs, ds, ys |
| which-key.nvim | Keybinding popup | VeryLazy | `<leader>` + wait |
| indent-blankline.nvim | Indent guides | BufReadPost | — |
| blink.cmp | Completion engine | InsertEnter | default preset |
| friendly-snippets | Snippet library | With blink.cmp | — |
| conform.nvim | Formatter (format-on-save) | BufWritePre | `<leader>cf` |
| trouble.nvim | Diagnostics / loclist / qflist UI | `:Trouble` | `<leader>xx/xb/xl/xq` |
| mason.nvim | LSP/tool installer | `:Mason` | — |
| mason-lspconfig.nvim | Bridge mason ↔ lspconfig | With mason | — |
| nvim-lspconfig | LSP client config (pyright, ruff, clangd, lua_ls) | BufReadPre, BufNewFile | see [LSP](#lsp-pyright--ruff--clangd--lua_ls) |
| plenary.nvim | Utility library | Dependency | — |
| nvim-web-devicons | File type icons | Dependency | — |
