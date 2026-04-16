return {
    "nvim-treesitter/nvim-treesitter",
    build = ":TSUpdate",
    event = { "BufReadPost", "BufNewFile" },
    opts = {
        ensure_installed = {
            "bash",
            "c",
            "cpp",
            "json",
            "lua",
            "luadoc",
            "markdown",
            "markdown_inline",
            "python",
            "regex",
            "toml",
            "vim",
            "vimdoc",
            "yaml",
        },
        auto_install = false,
        highlight = { enable = true },
        indent = { enable = true },
        incremental_selection = {
            enable = true,
            keymaps = {
                init_selection = "<C-space>",
                node_incremental = "<C-space>",
                scope_incremental = false,
                node_decremental = "<BS>",
            },
        },
    },
    config = function(_, opts)
        require("nvim-treesitter.configs").setup(opts)
    end,
}
