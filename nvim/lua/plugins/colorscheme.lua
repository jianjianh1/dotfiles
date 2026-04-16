return {
    "folke/tokyonight.nvim",
    lazy = false,
    priority = 1000,
    opts = {
        style = "storm",
        transparent = false,
        styles = {
            comments = { italic = true },
            keywords = { italic = false },
            functions = { bold = true },
        },
        on_colors = function(colors)
            -- Nudge toward the vimrc's Oceanic Next palette
            colors.bg = "#1b2b34"
            colors.bg_dark = "#162028"
        end,
    },
    config = function(_, opts)
        require("tokyonight").setup(opts)
        vim.cmd.colorscheme("tokyonight-storm")
    end,
}
