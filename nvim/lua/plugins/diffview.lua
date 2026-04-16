return {
    "sindrets/diffview.nvim",
    dependencies = { "nvim-lua/plenary.nvim" },
    cmd = { "DiffviewOpen", "DiffviewFileHistory" },
    keys = {
        { "<leader>gd", "<cmd>DiffviewOpen<CR>", desc = "Git diff" },
        { "<leader>gh", "<cmd>DiffviewFileHistory %<CR>", desc = "File history" },
        { "<leader>gH", "<cmd>DiffviewFileHistory<CR>", desc = "Branch history" },
    },
    opts = {
        enhanced_diff_hl = true,
        view = {
            default = { layout = "diff2_horizontal" },
        },
    },
}
