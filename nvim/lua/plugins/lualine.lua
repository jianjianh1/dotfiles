return {
    "nvim-lualine/lualine.nvim",
    lazy = false,
    dependencies = { "nvim-tree/nvim-web-devicons" },
    opts = {
        options = {
            theme = "tokyonight",
            component_separators = { left = "│", right = "│" },
            section_separators = { left = "", right = "" },
            globalstatus = true,
        },
        sections = {
            lualine_a = { "mode" },
            lualine_b = { "branch", "diff", "diagnostics" },
            lualine_c = { { "filename", path = 1 } }, -- Relative path
            lualine_x = { "filetype" },
            lualine_y = { "progress" },
            lualine_z = { "location" },
        },
    },
}
