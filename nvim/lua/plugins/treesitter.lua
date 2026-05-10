return {
    "nvim-treesitter/nvim-treesitter",
    branch = "main",
    build = ":TSUpdate",
    lazy = false,
    config = function()
        local ok, ts_config = pcall(require, "nvim-treesitter.config")
        if not ok then
            vim.notify("nvim-treesitter failed to load", vim.log.levels.WARN)
            return
        end

        ts_config.setup()

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
            if vim.fn.executable("tree-sitter") ~= 1 then
                vim.notify(
                    "nvim-treesitter: 'tree-sitter' CLI not on PATH; parsers not installed. "
                        .. "Run setup.sh or install tree-sitter manually.",
                    vim.log.levels.WARN
                )
            else
                require("nvim-treesitter.install").install(missing, { summary = true })
            end
        end

        vim.api.nvim_create_autocmd("FileType", {
            callback = function(args)
                if pcall(vim.treesitter.start, args.buf) then
                    vim.bo[args.buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
                end
            end,
        })
    end,
}
