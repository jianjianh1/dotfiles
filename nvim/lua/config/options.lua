-- Options: mirrors the vimrc philosophy with Neovim-specific improvements

vim.g.mapleader = " "
vim.g.maplocalleader = " "

-- Disable netrw (oil.nvim replaces it)
vim.g.loaded_netrw = 1
vim.g.loaded_netrwPlugin = 1

local opt = vim.opt

-- General
opt.encoding = "utf-8"
opt.fileencoding = "utf-8"
opt.backspace = "indent,eol,start"
opt.hidden = true
opt.autoread = true
opt.history = 1000
opt.undolevels = 1000
opt.mouse = "a"
opt.timeout = true
opt.timeoutlen = 300
opt.ttimeoutlen = 10
opt.updatetime = 250

-- UI
opt.number = true
opt.relativenumber = true
opt.cursorline = true
opt.showmatch = true
opt.matchtime = 1
opt.laststatus = 3 -- Global status line (nvim feature)
opt.showcmd = true
opt.wildmenu = true
opt.wildmode = "longest:full,full"
opt.wildignore:append("*/.git/*,*/.hg/*,*/.svn/*,*/node_modules/*,*/build/*,*/dist/*,*/.cache/*")
opt.scrolloff = 8
opt.sidescrolloff = 8
opt.signcolumn = "yes"
opt.splitbelow = true
opt.splitright = true
opt.errorbells = false
opt.visualbell = false
opt.colorcolumn = "100"
opt.wrap = true
opt.linebreak = true
opt.breakindent = true
opt.list = true
opt.listchars = "tab:>>·,trail:·,extends:›,precedes:‹,nbsp:␣"
opt.termguicolors = true
opt.showmode = false -- Lualine shows the mode

-- Search
opt.incsearch = true
opt.hlsearch = true
opt.ignorecase = true
opt.smartcase = true

-- Indentation
opt.autoindent = true
opt.smartindent = true
opt.expandtab = true
opt.tabstop = 4
opt.shiftwidth = 4
opt.softtabstop = 4

-- Performance
opt.lazyredraw = true
opt.synmaxcol = 240

-- Files
opt.backup = false
opt.writebackup = false
opt.swapfile = false
opt.undofile = true

-- Folding
opt.foldmethod = "manual"
opt.foldlevel = 99
opt.foldnestmax = 5
opt.foldminlines = 2

-- Completion
opt.completeopt = "menu,menuone,noselect"

-- Background — follow SERVER_CONFIGS_THEME exported by the shell rc.
-- macOS Terminal.app doesn't reply to OSC 11 and may set $COLORFGBG in
-- ways Neovim mis-classifies, so we override explicitly. The OptionSet
-- autocmd in plugins/colorscheme.lua still handles late-arriving OSC 11
-- responses on terminals that do reply (iTerm2, Ghostty, etc.).
opt.background = (vim.env.SERVER_CONFIGS_THEME == "light") and "light" or "dark"
