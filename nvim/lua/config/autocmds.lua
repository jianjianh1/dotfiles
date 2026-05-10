-- Autocommands: mirrors vimrc behavior

local augroup = vim.api.nvim_create_augroup
local autocmd = vim.api.nvim_create_autocmd

-- Return to last edit position when opening files
augroup("RestoreCursor", { clear = true })
autocmd("BufReadPost", {
    group = "RestoreCursor",
    callback = function()
        local mark = vim.api.nvim_buf_get_mark(0, '"')
        local line_count = vim.api.nvim_buf_line_count(0)
        if mark[1] > 1 and mark[1] <= line_count then
            vim.api.nvim_win_set_cursor(0, mark)
        end
    end,
})

-- 2-space indent for web filetypes
augroup("WebIndent", { clear = true })
autocmd("FileType", {
    group = "WebIndent",
    pattern = { "html", "css", "javascript", "typescript", "json", "yaml", "lua" },
    callback = function()
        vim.opt_local.tabstop = 2
        vim.opt_local.shiftwidth = 2
        vim.opt_local.softtabstop = 2
    end,
})

-- Strip trailing whitespace on save, except where it's meaningful:
-- markdown ('  ' = <br>), gitcommit (template scissors line), and diff
-- (patch context lines).
local strip_whitespace_skip = { markdown = true, gitcommit = true, diff = true }
augroup("StripWhitespace", { clear = true })
autocmd("BufWritePre", {
    group = "StripWhitespace",
    pattern = "*",
    callback = function()
        if strip_whitespace_skip[vim.bo.filetype] then return end
        local pos = vim.api.nvim_win_get_cursor(0)
        vim.cmd([[%s/\s\+$//e]])
        vim.api.nvim_win_set_cursor(0, pos)
    end,
})

-- Highlight on yank
augroup("HighlightYank", { clear = true })
autocmd("TextYankPost", {
    group = "HighlightYank",
    callback = function()
        vim.highlight.on_yank({ timeout = 200 })
    end,
})

-- Disable expensive features for large files (>1MB)
augroup("LargeFileTuning", { clear = true })
autocmd("BufReadPost", {
    group = "LargeFileTuning",
    callback = function()
        local size = vim.fn.getfsize(vim.fn.expand("%:p"))
        if size > 1024 * 1024 then
            vim.opt_local.foldmethod = "manual"
            vim.opt_local.cursorline = false
            vim.opt_local.relativenumber = false
            vim.opt_local.list = false
            vim.cmd("syntax off")
            -- Disable treesitter for this buffer
            pcall(function()
                vim.treesitter.stop()
            end)
        end
    end,
})
