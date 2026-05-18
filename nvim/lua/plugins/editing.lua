return {
    -- Auto-close brackets and quotes
    {
        "windwp/nvim-autopairs",
        event = "InsertEnter",
        opts = {},
    },
    -- Surround: cs"' (change), ds( (delete), ysiw" (add)
    {
        "kylechui/nvim-surround",
        event = "VeryLazy",
        opts = {},
    },
}
