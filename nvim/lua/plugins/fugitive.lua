return {
    "tpope/vim-fugitive",
    cmd = { "Git", "Gwrite", "Gread", "Gdiffsplit" },
    keys = {
        { "<leader>gs", "<cmd>Git<CR>", desc = "Git status" },
    },
}
