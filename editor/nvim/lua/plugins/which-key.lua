return {
    "folke/which-key.nvim",
    event = "VeryLazy",
    opts = {
        spec = {
            { "<leader>f", group = "find" },
            { "<leader>g", group = "git" },
            { "<leader>b", group = "buffer" },
        },
    },
}
