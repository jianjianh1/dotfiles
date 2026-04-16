return {
    "nvim-treesitter/nvim-treesitter",
    build = ":TSUpdate",
    lazy = false,
    config = function()
        local ok, ts_config = pcall(require, "nvim-treesitter.config")
        if not ok then
            vim.notify("nvim-treesitter failed to load", vim.log.levels.WARN)
            return
        end

        -- Parser management (install_dir, :TSInstall, etc.)
        ts_config.setup()

        -- Install parsers if missing
        local wanted = {
            "bash", "c", "cpp", "json", "lua", "luadoc",
            "markdown", "markdown_inline", "python", "regex",
            "toml", "vim", "vimdoc", "yaml",
        }
        local installed = ts_config.get_installed()
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
