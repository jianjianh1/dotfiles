return {
    "stevearc/oil.nvim",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    keys = {
        { "<leader>e", "<cmd>Oil<CR>", desc = "File explorer" },
        { "-", "<cmd>Oil<CR>", desc = "File explorer" },
    },
    opts = {
        default_file_explorer = true,
        columns = { "icon" },
        view_options = {
            show_hidden = true,
        },
        keymaps = {
            ["g?"] = "actions.show_help",
            ["<CR>"] = "actions.select",
            ["<C-v>"] = "actions.select_vsplit",
            ["<C-s>"] = "actions.select_split",
            ["<C-t>"] = "actions.select_tab",
            ["-"] = "actions.parent",
            ["_"] = "actions.open_cwd",
            ["gs"] = "actions.change_sort",
            ["gx"] = "actions.open_external",
            ["g."] = "actions.toggle_hidden",
            ["q"] = "actions.close",
        },
    },
}
