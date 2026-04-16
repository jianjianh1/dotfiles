return {
    -- Auto-close brackets and quotes
    {
        "windwp/nvim-autopairs",
        event = "InsertEnter",
        opts = {},
    },
    -- Toggle comments: gcc (line), gc (motion)
    {
        "numToStr/Comment.nvim",
        event = "VeryLazy",
        opts = {},
    },
    -- Surround: cs"' (change), ds( (delete), ysiw" (add)
    {
        "kylechui/nvim-surround",
        event = "VeryLazy",
        opts = {},
    },
}
