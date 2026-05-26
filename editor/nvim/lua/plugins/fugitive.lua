return {
    {
        "tpope/vim-fugitive",
        cmd = { "Git", "Gwrite", "Gread", "Gdiffsplit" },
        keys = {
            { "<leader>gs", "<cmd>Git<CR>", desc = "Git status" },
        },
    },
    {
        "kdheepak/lazygit.nvim",
        cmd = "LazyGit",
        keys = {
            { "<leader>lg", "<cmd>LazyGit<CR>", desc = "LazyGit" },
        },
    },
}
