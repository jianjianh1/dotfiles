-- Bootstrap lazy.nvim
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.uv.fs_stat(lazypath) then
    vim.fn.system({
        "git",
        "clone",
        "--filter=blob:none",
        "https://github.com/folke/lazy.nvim.git",
        "--branch=stable",
        lazypath,
    })
end
vim.opt.rtp:prepend(lazypath)

-- Load all plugin specs from lua/plugins/
require("lazy").setup("plugins", {
    defaults = { lazy = true },
    install = { colorscheme = { "tokyonight" } },
    checker = { enabled = false }, -- Don't auto-check for updates
    change_detection = { notify = false },
    performance = {
        rtp = {
            disabled_plugins = {
                "netrwPlugin",
                "tohtml",
                "tutor",
            },
        },
    },
})
