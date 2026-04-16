return {
    -- In-buffer markdown rendering (pure Lua, no external deps)
    {
        "MeanderingProgrammer/render-markdown.nvim",
        dependencies = { "nvim-treesitter/nvim-treesitter", "nvim-tree/nvim-web-devicons" },
        ft = "markdown",
        opts = {
            heading = {
                icons = { "# ", "## ", "### ", "#### ", "##### ", "###### " },
            },
            code = {
                sign = false,
                width = "block",
            },
        },
    },
    -- Browser-based live preview (requires Node.js)
    {
        "iamcco/markdown-preview.nvim",
        ft = "markdown",
        build = function()
            -- Only build if node is available and modern enough
            if vim.fn.executable("node") == 1 then
                vim.fn["mkdp#util#install"]()
            end
        end,
        keys = {
            { "<leader>m", "<cmd>MarkdownPreviewToggle<CR>", ft = "markdown", desc = "Markdown preview" },
        },
        init = function()
            vim.g.mkdp_filetypes = { "markdown" }
        end,
    },
}
