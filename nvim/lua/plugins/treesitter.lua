return {
    "nvim-treesitter/nvim-treesitter",
    build = ":TSUpdate",
    event = { "BufReadPost", "BufNewFile" },
    main = "nvim-treesitter.config",
    opts = {},
    config = function()
        -- Parser management (install_dir, :TSInstall, etc.)
        require("nvim-treesitter.config").setup()

        -- Install parsers if missing
        local wanted = {
            "bash", "c", "cpp", "json", "lua", "luadoc",
            "markdown", "markdown_inline", "python", "regex",
            "toml", "vim", "vimdoc", "yaml",
        }
        local installed = require("nvim-treesitter.config").get_installed()
        local installed_set = {}
        for _, lang in ipairs(installed) do
            installed_set[lang] = true
        end
        local missing = {}
        for _, lang in ipairs(wanted) do
            if not installed_set[lang] then
                missing[#missing + 1] = lang
            end
        end
        if #missing > 0 then
            require("nvim-treesitter.install").install(missing, { summary = true })
        end

        -- Built-in treesitter highlight and indent (Neovim 0.10+)
        vim.api.nvim_create_autocmd("FileType", {
            callback = function(args)
                if pcall(vim.treesitter.start, args.buf) then
                    vim.bo[args.buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
                end
            end,
        })

    end,
}
