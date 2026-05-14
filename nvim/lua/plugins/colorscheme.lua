local style = (vim.env.SERVER_CONFIGS_THEME == "light") and "day" or "storm"

return {
    "folke/tokyonight.nvim",
    lazy = false,
    priority = 1000,
    opts = {
        style = style,
        transparent = false,
        styles = {
            comments = { italic = true },
            keywords = { italic = false },
            functions = { bold = true },
        },
    },
    config = function(_, opts)
        require("tokyonight").setup(opts)
        vim.cmd.colorscheme("tokyonight-" .. style)
    end,
}
