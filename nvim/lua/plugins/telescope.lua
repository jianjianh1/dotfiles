return {
    "nvim-telescope/telescope.nvim",
    branch = "0.1.x",
    dependencies = {
        "nvim-lua/plenary.nvim",
        "nvim-tree/nvim-web-devicons",
        {
            "nvim-telescope/telescope-fzf-native.nvim",
            build = "make",
            cond = function()
                return vim.fn.executable("make") == 1
            end,
        },
    },
    keys = {
        { "<leader>ff", "<cmd>Telescope find_files<CR>", desc = "Find files" },
        { "<leader>fg", "<cmd>Telescope live_grep<CR>", desc = "Live grep" },
        { "<leader>fb", "<cmd>Telescope buffers<CR>", desc = "Buffers" },
        { "<leader>fh", "<cmd>Telescope help_tags<CR>", desc = "Help tags" },
        { "<leader>fr", "<cmd>Telescope resume<CR>", desc = "Resume search" },
        { "<leader>fo", "<cmd>Telescope oldfiles<CR>", desc = "Recent files" },
        { "<leader>fw", "<cmd>Telescope grep_string<CR>", desc = "Grep word under cursor" },
        { "<leader>fd", "<cmd>Telescope diagnostics<CR>", desc = "Diagnostics" },
        { "<leader>/", "<cmd>Telescope current_buffer_fuzzy_find<CR>", desc = "Search in buffer" },
    },
    opts = {
        defaults = {
            file_ignore_patterns = { "node_modules", ".git/", "build/", "dist/", ".cache/" },
            layout_strategy = "horizontal",
            layout_config = {
                horizontal = { preview_width = 0.55 },
            },
            mappings = {
                i = {
                    ["<C-j>"] = "move_selection_next",
                    ["<C-k>"] = "move_selection_previous",
                    ["<Esc>"] = "close",
                },
            },
        },
    },
    config = function(_, opts)
        local telescope = require("telescope")
        telescope.setup(opts)
        pcall(telescope.load_extension, "fzf")
    end,
}
