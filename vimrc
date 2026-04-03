" === General ===
set nocompatible
set encoding=utf-8
set fileencoding=utf-8
set backspace=indent,eol,start
set hidden                      " Allow switching buffers without saving
set autoread                    " Reload files changed outside vim
set history=1000
set undolevels=1000
set clipboard=unnamedplus       " Use system clipboard
set mouse=a                     " Enable mouse in all modes
set ttimeoutlen=10              " Fast escape key

" === UI ===
set number                      " Line numbers
set relativenumber              " Relative line numbers
set cursorline                  " Highlight current line
set showmatch                   " Highlight matching brackets
set laststatus=2                " Always show status line
set showcmd                     " Show partial commands
set wildmenu                    " Command-line completion menu
set wildmode=longest:full,full
set scrolloff=8                 " Keep 8 lines above/below cursor
set sidescrolloff=8
set signcolumn=number           " Show signs in the number column
set splitbelow splitright        " Intuitive split directions
set noerrorbells
set novisualbell

" === Search ===
set incsearch                   " Incremental search
set hlsearch                    " Highlight search results
set ignorecase                  " Case-insensitive search...
set smartcase                   " ...unless uppercase is used

" === Indentation ===
set autoindent
set smartindent
set expandtab                   " Spaces, not tabs
set tabstop=4
set shiftwidth=4
set softtabstop=4
filetype plugin indent on

" === Performance ===
set lazyredraw                  " Don't redraw during macros
set ttyfast
set synmaxcol=300               " Don't highlight super-long lines
syntax enable

" === Files ===
set nobackup
set nowritebackup
set noswapfile
set undofile                    " Persistent undo
set undodir=~/.vim/undodir

" === Status line (no plugins needed) ===
set statusline=
set statusline+=\ %f            " File path
set statusline+=\ %m%r          " Modified / readonly flags
set statusline+=%=              " Right-align the rest
set statusline+=\ %y            " File type
set statusline+=\ %l:%c         " Line:column
set statusline+=\ [%p%%]        " Percentage through file

" === Key mappings ===
let mapleader = " "

" Clear search highlighting
nnoremap <leader><space> :nohlsearch<CR>

" Quick save / quit
nnoremap <leader>w :w<CR>
nnoremap <leader>q :q<CR>

" Better window navigation
nnoremap <C-h> <C-w>h
nnoremap <C-j> <C-w>j
nnoremap <C-k> <C-w>k
nnoremap <C-l> <C-w>l

" Resize splits with arrows
nnoremap <C-Up>    :resize +2<CR>
nnoremap <C-Down>  :resize -2<CR>
nnoremap <C-Left>  :vertical resize -2<CR>
nnoremap <C-Right> :vertical resize +2<CR>

" Move lines up/down in visual mode
vnoremap J :m '>+1<CR>gv=gv
vnoremap K :m '<-2<CR>gv=gv

" Keep cursor centered when scrolling
nnoremap <C-d> <C-d>zz
nnoremap <C-u> <C-u>zz
nnoremap n nzzzv
nnoremap k kzzzv

" Buffer navigation
nnoremap <leader>bn :bnext<CR>
nnoremap <leader>bp :bprev<CR>
nnoremap <leader>bd :bdelete<CR>
nnoremap <leader>bl :ls<CR>

" Quick access to netrw file explorer
nnoremap <leader>e :Explore<CR>

" Yank to end of line (consistent with D and C)
nnoremap Y y$

" Don't lose register contents on visual paste
vnoremap p "_dP

" Quick open terminal
nnoremap <leader>t :terminal<CR>

" === Autocmds ===
augroup custom
    autocmd!
    " Return to last edit position when opening files
    autocmd BufReadPost * if line("'\"") > 1 && line("'\"") <= line("$") | exe "normal! g'\"" | endif

    " 2-space indent for web files
    autocmd FileType html,css,javascript,typescript,json,yaml setlocal tabstop=2 shiftwidth=2 softtabstop=2

    " Strip trailing whitespace on save
    autocmd BufWritePre * :%s/\s\+$//e

    " Highlight yanked text briefly
    autocmd TextYankPost * silent! lua vim.highlight.on_yank() 2>/dev/null
augroup END

" === netrw (built-in file explorer) ===
let g:netrw_banner = 0          " Hide banner
let g:netrw_liststyle = 3       " Tree view
let g:netrw_winsize = 25        " 25% width

" === Create undo directory if it doesn't exist ===
if !isdirectory($HOME . "/.vim/undodir")
    call mkdir($HOME . "/.vim/undodir", "p")
endif

" === Colors ===
set background=dark
set t_Co=256
if has('termguicolors')
    set termguicolors
    let &t_8f = "\<Esc>[38;2;%lu;%lu;%lum"
    let &t_8b = "\<Esc>[48;2;%lu;%lu;%lum"
endif

" Base: slate is the best built-in dark scheme, then override
silent! colorscheme slate

" --- Custom color overrides (dark theme, easy on the eyes) ---
hi Normal          guifg=#c0c5ce guibg=#1b2b34 ctermfg=251  ctermbg=234
hi CursorLine      guibg=#243040 ctermbg=236  cterm=NONE gui=NONE
hi CursorLineNr    guifg=#fac863 guibg=#243040 ctermfg=221  ctermbg=236  cterm=bold gui=bold
hi LineNr          guifg=#4f5b66 ctermfg=240
hi Visual          guibg=#3d566e ctermbg=239
hi Search          guifg=#1b2b34 guibg=#fac863 ctermfg=234  ctermbg=221
hi IncSearch       guifg=#1b2b34 guibg=#f99157 ctermfg=234  ctermbg=209

" Syntax
hi Comment         guifg=#65737e ctermfg=243  cterm=italic gui=italic
hi Constant        guifg=#f99157 ctermfg=209
hi String          guifg=#99c794 ctermfg=114
hi Character       guifg=#99c794 ctermfg=114
hi Number          guifg=#f99157 ctermfg=209
hi Boolean         guifg=#f99157 ctermfg=209
hi Float           guifg=#f99157 ctermfg=209
hi Identifier      guifg=#c0c5ce ctermfg=251
hi Function        guifg=#6699cc ctermfg=68   cterm=bold gui=bold
hi Statement       guifg=#c594c5 ctermfg=176
hi Keyword         guifg=#c594c5 ctermfg=176
hi Conditional     guifg=#c594c5 ctermfg=176
hi Repeat          guifg=#c594c5 ctermfg=176
hi Operator        guifg=#5fb3b3 ctermfg=73
hi PreProc         guifg=#c594c5 ctermfg=176
hi Include         guifg=#c594c5 ctermfg=176
hi Define          guifg=#c594c5 ctermfg=176
hi Macro           guifg=#c594c5 ctermfg=176
hi Type            guifg=#fac863 ctermfg=221
hi Structure       guifg=#fac863 ctermfg=221
hi Typedef         guifg=#fac863 ctermfg=221
hi Special         guifg=#5fb3b3 ctermfg=73
hi SpecialChar     guifg=#ec5f67 ctermfg=203
hi Delimiter       guifg=#5fb3b3 ctermfg=73
hi Todo            guifg=#fac863 guibg=NONE   ctermfg=221  ctermbg=NONE cterm=bold gui=bold

" UI elements
hi Pmenu           guifg=#c0c5ce guibg=#2d3b45 ctermfg=251  ctermbg=237
hi PmenuSel        guifg=#1b2b34 guibg=#6699cc ctermfg=234  ctermbg=68   cterm=bold gui=bold
hi PmenuSbar       guibg=#3d566e ctermbg=239
hi PmenuThumb      guibg=#6699cc ctermbg=68
hi MatchParen      guifg=#fac863 guibg=#3d566e ctermfg=221  ctermbg=239  cterm=bold gui=bold
hi ErrorMsg        guifg=#ec5f67 guibg=NONE   ctermfg=203
hi WarningMsg      guifg=#fac863 ctermfg=221
hi VertSplit       guifg=#3d566e guibg=NONE   ctermfg=239  ctermbg=NONE
hi SignColumn      guibg=#1b2b34 ctermbg=234
hi Folded          guifg=#65737e guibg=#243040 ctermfg=243  ctermbg=236
hi DiffAdd         guifg=#99c794 guibg=#2d4a3e ctermfg=114  ctermbg=23
hi DiffDelete      guifg=#ec5f67 guibg=#4a2d34 ctermfg=203  ctermbg=52
hi DiffChange      guifg=#fac863 guibg=#4a4a2d ctermfg=221  ctermbg=58
hi DiffText        guifg=#fac863 guibg=#5a5a1d ctermfg=221  ctermbg=100  cterm=bold gui=bold
hi TabLine         guifg=#65737e guibg=#2d3b45 ctermfg=243  ctermbg=237  cterm=NONE gui=NONE
hi TabLineSel      guifg=#c0c5ce guibg=#1b2b34 ctermfg=251  ctermbg=234  cterm=bold gui=bold
hi TabLineFill     guibg=#2d3b45 ctermbg=237
hi SpellBad        guisp=#ec5f67 ctermfg=203  cterm=undercurl gui=undercurl

" --- Colored status line ---
hi StatusLine      guifg=#1b2b34 guibg=#6699cc ctermfg=234  ctermbg=68   cterm=bold gui=bold
hi StatusLineNC    guifg=#65737e guibg=#2d3b45 ctermfg=243  ctermbg=237  cterm=NONE gui=NONE
