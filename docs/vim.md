# Vim Configuration Reference

Source: [`vimrc`](../vimrc) — plugin-free, built-in features only.

The vimrc sources `~/.server-configs-generated/vimrc.compat` for version-sensitive settings (clipboard, listchars, Neovim detection). For the Neovim config, see [neovim.md](neovim.md).

---

## Options

### General

| Option | Value | Purpose |
|--------|-------|---------|
| `nocompatible` | — | Disable vi compatibility |
| `encoding` | `utf-8` | Internal encoding |
| `fileencoding` | `utf-8` | File write encoding |
| `backspace` | `indent,eol,start` | Backspace through everything |
| `hidden` | on | Allow switching buffers without saving |
| `autoread` | on | Reload files changed outside vim |
| `history` | `1000` | Command history length |
| `undolevels` | `1000` | Maximum undo steps |
| `mouse` | `a` | Enable mouse in all modes |
| `timeoutlen` | `300` | Mapping timeout (ms) |
| `ttimeoutlen` | `10` | Key code timeout (ms) — fast Escape |

### UI

| Option | Value | Purpose |
|--------|-------|---------|
| `number` | on | Line numbers |
| `relativenumber` | on | Relative line numbers |
| `cursorline` | on | Highlight current line |
| `showmatch` | on | Flash matching bracket |
| `matchtime` | `1` | Tenths of a second to flash |
| `laststatus` | `2` | Always show status line |
| `showcmd` | on | Show partial commands in status |
| `wildmenu` | on | Enhanced command-line completion |
| `wildmode` | `longest:full,full` | Complete longest, then cycle |
| `wildignore` | `.git, .hg, .svn, node_modules, build, dist, .cache` | Ignore in file completion |
| `scrolloff` | `8` | Keep 8 lines above/below cursor |
| `sidescrolloff` | `8` | Keep 8 columns left/right |
| `signcolumn` | `yes` | Always show sign column |
| `splitbelow` | on | Horizontal splits open below |
| `splitright` | on | Vertical splits open right |
| `colorcolumn` | `100` | Visual guide at column 100 |
| `wrap` | on | Wrap long lines visually |
| `linebreak` | on | Wrap at word boundaries |
| `breakindent` | on | Indented wrapped lines |
| `list` | on | Show whitespace characters |

### Search

| Option | Value | Purpose |
|--------|-------|---------|
| `incsearch` | on | Search as you type |
| `hlsearch` | on | Highlight all matches |
| `ignorecase` | on | Case-insensitive search |
| `smartcase` | on | Case-sensitive if uppercase used |

### Indentation

| Option | Value | Purpose |
|--------|-------|---------|
| `autoindent` | on | Copy indent from current line |
| `smartindent` | on | Auto-indent after `{`, etc. |
| `expandtab` | on | Spaces, not tabs |
| `tabstop` | `4` | Tab display width |
| `shiftwidth` | `4` | Indent width |
| `softtabstop` | `4` | Tab insert width |

Web filetypes (html, css, js, ts, json, yaml) use 2-space via autocmd.

### Performance

| Option | Value | Purpose |
|--------|-------|---------|
| `lazyredraw` | on | Don't redraw during macros |
| `ttyfast` | on | Fast terminal connection |
| `synmaxcol` | `240` | Don't highlight past column 240 |

### Files

| Option | Value | Purpose |
|--------|-------|---------|
| `nobackup` | — | No backup files |
| `nowritebackup` | — | No write backup |
| `noswapfile` | — | No swap files |
| `undofile` | on | Persistent undo across sessions |
| `undodir` | `~/.vim/undodir` | Undo file location (auto-created) |

### Folding

| Option | Value | Purpose |
|--------|-------|---------|
| `foldmethod` | `manual` | Manual fold creation |
| `foldlevel` | `99` | Start completely unfolded |
| `foldnestmax` | `5` | Maximum fold depth |
| `foldminlines` | `2` | Minimum lines to fold |

### Tags

```vim
set tags=./tags;,tags;   " Search upward for tags file
```

---

## Keybindings

**Leader:** `Space`

### General

| Key | Mode | Action |
|-----|------|--------|
| `<leader><space>` | n | Clear search highlight |
| `<leader>w` | n | Save file |
| `<leader>q` | n | Quit |
| `Y` | n | Yank to end of line (consistent with `D`, `C`) |

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
| `#` | n | Reverse search word under cursor (stay put) |

### Folding

| Key | Mode | Action |
|-----|------|--------|
| `za` | n | Toggle fold under cursor |
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

### File Explorer & Tools

| Key | Mode | Action |
|-----|------|--------|
| `<leader>e` | n | Open netrw file explorer |
| `<leader>m` | n | Preview markdown with glow |
| `<leader>t` | n | Open terminal |

### FZF (if installed)

| Key | Mode | Action |
|-----|------|--------|
| `<leader>f` | n | FZF file finder |
| `<leader>b` | n | Buffer picker |

Requires `~/.fzf` directory to exist.

---

## Autocmds

| Event | Pattern | Action |
|-------|---------|--------|
| `BufReadPost` | `*` | Restore cursor to last edit position |
| `FileType` | `html,css,javascript,typescript,json,yaml` | Set 2-space indent |
| `BufWritePre` | `*` | Strip trailing whitespace |
| `BufReadPost` | `*` (>1MB) | Disable folds, cursorline, relativenumber, list |

---

## netrw Settings

| Setting | Value | Purpose |
|---------|-------|---------|
| `g:netrw_banner` | `0` | Hide banner |
| `g:netrw_liststyle` | `3` | Tree view |
| `g:netrw_winsize` | `25` | 25% window width |

---

## Color Theme

Base colorscheme is `slate`, with extensive overrides inspired by the **Oceanic Next** palette.

### Palette

| Color | Hex | Used for |
|-------|-----|----------|
| Dark bg | `#1b2b34` | Normal background |
| Cursor bg | `#243040` | CursorLine, ColorColumn, Folded |
| Selection | `#3d566e` | Visual selection |
| Comment | `#65737e` | Comments (italic) |
| Foreground | `#c0c5ce` | Normal text, identifiers |
| Yellow | `#fac863` | Types, search highlight, todo, cursor line nr |
| Orange | `#f99157` | Constants, numbers, IncSearch |
| Green | `#99c794` | Strings, characters, DiffAdd |
| Blue | `#6699cc` | Functions (bold), PmenuSel, StatusLine |
| Purple | `#c594c5` | Statements, keywords, conditionals, PreProc |
| Cyan | `#5fb3b3` | Operators, delimiters, special chars |
| Red | `#ec5f67` | SpecialChar, ErrorMsg, DiffDelete, SpellBad |

### Status Line

Format: `filename modified=readonly filetype line:col [pct%]`

Active status line: blue background (`#6699cc`), dark text.
Inactive status line: gray on dark.

---

## Compat Layer (`vimrc.compat`)

Generated by `setup.sh` based on the detected Vim version. May include:

- Clipboard setting (`unnamedplus` vs `unnamed`)
- Listchars (Unicode vs ASCII fallback)
- Neovim-specific overrides (if sourced by nvim as fallback)
