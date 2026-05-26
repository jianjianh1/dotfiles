-- Apple Terminal forces 256-color via options.lua (its truecolor parser is
-- buggy). Pair that with gruvbox, which was designed for 256-color terminals
-- and looks great in cterm. Everywhere else: catppuccin in full truecolor.
local scheme = require("config.term").is_apple_terminal() and "gruvbox" or "catppuccin"

local function apply(name)
    vim.cmd.colorscheme(name)
    vim.api.nvim_create_autocmd("OptionSet", {
        pattern = "background",
        callback = function() vim.cmd.colorscheme(name) end,
    })
end

return {
    {
        "catppuccin/nvim",
        name = "catppuccin",
        lazy = false,
        priority = 1000,
        enabled = scheme == "catppuccin",
        opts = {
            flavour = "auto",
            background = { light = "latte", dark = "mocha" },
        },
        config = function(_, opts)
            require("catppuccin").setup(opts)
            apply("catppuccin")
        end,
    },
    {
        "ellisonleao/gruvbox.nvim",
        lazy = false,
        priority = 1000,
        enabled = scheme == "gruvbox",
        opts = { contrast = "soft" },
        config = function(_, opts)
            require("gruvbox").setup(opts)
            apply("gruvbox")
        end,
    },
}
