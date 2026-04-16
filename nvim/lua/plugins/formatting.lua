return {
    {
        "stevearc/conform.nvim",
        event = "BufWritePre",
        cmd = "ConformInfo",
        keys = {
            { "<leader>cf", function() require("conform").format({ async = true }) end, desc = "Format buffer" },
        },
        opts = {
            formatters_by_ft = {
                python = { "ruff_format", "black", stop_after_first = true },
                lua = { "stylua" },
                c = { "clang-format" },
                cpp = { "clang-format" },
                json = { "jq" },
                yaml = { "prettier" },
                markdown = { "prettier" },
                sh = { "shfmt" },
                bash = { "shfmt" },
            },
            format_on_save = function(bufnr)
                -- Disable for large files
                if vim.api.nvim_buf_line_count(bufnr) > 5000 then return end
                return { timeout_ms = 2000, lsp_format = "fallback" }
            end,
        },
    },
    {
        "folke/trouble.nvim",
        cmd = "Trouble",
        keys = {
            { "<leader>xx", "<cmd>Trouble diagnostics toggle<CR>", desc = "Diagnostics (Trouble)" },
            { "<leader>xb", "<cmd>Trouble diagnostics toggle filter.buf=0<CR>", desc = "Buffer diagnostics" },
            { "<leader>xl", "<cmd>Trouble loclist toggle<CR>", desc = "Location list" },
            { "<leader>xq", "<cmd>Trouble qflist toggle<CR>", desc = "Quickfix list" },
        },
        opts = {},
    },
}
