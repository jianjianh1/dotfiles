-- Keymaps: preserves vimrc bindings, adds plugin-specific ones

local map = vim.keymap.set

-- Clear search highlighting
map("n", "<leader><space>", "<cmd>nohlsearch<CR>", { desc = "Clear search highlight" })

-- Quick save / quit
map("n", "<leader>w", "<cmd>w<CR>", { desc = "Save" })
map("n", "<leader>q", "<cmd>q<CR>", { desc = "Quit" })

-- Window navigation
map("n", "<C-h>", "<C-w>h", { desc = "Move to left window" })
map("n", "<C-j>", "<C-w>j", { desc = "Move to below window" })
map("n", "<C-k>", "<C-w>k", { desc = "Move to above window" })
map("n", "<C-l>", "<C-w>l", { desc = "Move to right window" })

-- Resize splits with arrows
map("n", "<C-Up>", "<cmd>resize +2<CR>", { desc = "Increase height" })
map("n", "<C-Down>", "<cmd>resize -2<CR>", { desc = "Decrease height" })
map("n", "<C-Left>", "<cmd>vertical resize -2<CR>", { desc = "Decrease width" })
map("n", "<C-Right>", "<cmd>vertical resize +2<CR>", { desc = "Increase width" })

-- Move lines in visual mode
map("v", "J", ":m '>+1<CR>gv=gv", { desc = "Move selection down" })
map("v", "K", ":m '<-2<CR>gv=gv", { desc = "Move selection up" })

-- Centered scrolling
map("n", "<C-d>", "<C-d>zz")
map("n", "<C-u>", "<C-u>zz")
map("n", "n", "nzzzv")
map("n", "N", "Nzzzv")

-- Search for word under cursor without jumping
map("n", "*", "*N")
map("n", "#", "#N")

-- Yank to end of line (consistent with D and C)
map("n", "Y", "y$")

-- Don't lose register on visual paste
map("v", "p", '"_dP')

-- Buffer navigation
map("n", "<leader>bn", "<cmd>bnext<CR>", { desc = "Next buffer" })
map("n", "<leader>bp", "<cmd>bprev<CR>", { desc = "Previous buffer" })
map("n", "<leader>bd", "<cmd>bdelete<CR>", { desc = "Delete buffer" })
map("n", "<leader>bl", "<cmd>ls<CR>", { desc = "List buffers" })

-- Quick terminal
map("n", "<leader>t", "<cmd>terminal<CR>", { desc = "Open terminal" })

-- Fold toggles
map("n", "zO", "zR", { desc = "Open all folds" })
map("n", "zC", "zM", { desc = "Close all folds" })
map("n", "<leader>fi", "<cmd>setlocal foldmethod=indent<CR>zx", { desc = "Fold by indent" })
map("n", "<leader>fm", "<cmd>setlocal foldmethod=manual<CR>", { desc = "Manual folding" })

-- Better escape from terminal mode
map("t", "<Esc><Esc>", "<C-\\><C-n>", { desc = "Exit terminal mode" })
