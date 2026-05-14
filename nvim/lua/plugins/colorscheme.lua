return {
    "folke/tokyonight.nvim",
    lazy = false,
    priority = 1000,
    opts = {
        transparent = false,
        styles = {
            comments = { italic = true },
            keywords = { italic = false },
            functions = { bold = true },
        },
    },
    config = function(_, opts)
        local function apply()
            local style = (vim.o.background == "light") and "day" or "storm"
            opts.style = style
            require("tokyonight").setup(opts)
            vim.cmd.colorscheme("tokyonight-" .. style)
        end

        apply()
        vim.api.nvim_create_autocmd("OptionSet", {
            pattern = "background",
            callback = apply,
            desc = "Re-apply tokyonight when &background changes (e.g. nvim's OSC 11 result lands)",
        })
    end,
}
