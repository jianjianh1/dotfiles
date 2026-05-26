return {
    {
        "williamboman/mason.nvim",
        cmd = "Mason",
        opts = {},
    },
    {
        "williamboman/mason-lspconfig.nvim",
        dependencies = { "williamboman/mason.nvim" },
        opts = {
            ensure_installed = { "pyright", "ruff", "clangd", "lua_ls" },
        },
    },
    {
        "neovim/nvim-lspconfig",
        event = { "BufReadPre", "BufNewFile" },
        dependencies = {
            "williamboman/mason.nvim",
            "williamboman/mason-lspconfig.nvim",
            "saghen/blink.cmp",
        },
        config = function()
            local capabilities = require("blink.cmp").get_lsp_capabilities()

            vim.lsp.config("*", { capabilities = capabilities })

            vim.lsp.config("lua_ls", {
                settings = {
                    Lua = {
                        workspace = { checkThirdParty = false },
                        telemetry = { enable = false },
                        hint = { enable = true },
                    },
                },
            })

            -- Pyright: types/hover/defs. Ruff owns lint, so keep pyright quiet
            -- and scoped to open files to avoid the workspace-wide noise that
            -- shows up with defaults.
            vim.lsp.config("pyright", {
                settings = {
                    python = {
                        analysis = {
                            typeCheckingMode = "basic",
                            diagnosticMode = "openFilesOnly",
                            useLibraryCodeForTypes = true,
                            autoImportCompletions = true,
                            autoSearchPaths = true,
                        },
                    },
                },
            })

            -- Ruff: lint only. Disable hover so pyright wins the popup race.
            vim.lsp.config("ruff", {
                on_attach = function(client)
                    client.server_capabilities.hoverProvider = false
                end,
            })

            vim.lsp.config("clangd", {
                cmd = {
                    "clangd",
                    "--background-index",
                    "--clang-tidy",
                    "--header-insertion=iwyu",
                    "--completion-style=detailed",
                    "--function-arg-placeholders",
                    "--fallback-style=Google",
                    "--pch-storage=memory",
                },
                init_options = {
                    usePlaceholders = true,
                    clangdFileStatus = true,
                },
            })

            vim.lsp.enable({ "pyright", "ruff", "clangd", "lua_ls" })

            local compile_commands = require("config.compile_commands")
            compile_commands.setup()

            vim.diagnostic.config({
                virtual_text = { spacing = 2, prefix = "●" },
                severity_sort = true,
                update_in_insert = false,
                float = { border = "rounded", source = "if_many" },
                signs = {
                    text = {
                        [vim.diagnostic.severity.ERROR] = "✘",
                        [vim.diagnostic.severity.WARN]  = "▲",
                        [vim.diagnostic.severity.INFO]  = "●",
                        [vim.diagnostic.severity.HINT]  = "○",
                    },
                },
            })

            vim.api.nvim_create_autocmd("LspAttach", {
                group = vim.api.nvim_create_augroup("lsp-attach", { clear = true }),
                callback = function(event)
                    local client = vim.lsp.get_client_by_id(event.data.client_id)
                    local map = function(mode, keys, func, desc)
                        vim.keymap.set(mode, keys, func, { buffer = event.buf, desc = "LSP: " .. desc })
                    end

                    -- Navigation (VS Code parity: F12, Shift+F12, Ctrl+])
                    map("n", "gd",      vim.lsp.buf.definition,      "Go to definition")
                    map("n", "<C-]>",   vim.lsp.buf.definition,      "Go to definition")
                    map({ "n", "i" }, "<F12>", vim.lsp.buf.definition, "Go to definition")
                    map("n", "gr",      vim.lsp.buf.references,      "References")
                    map("n", "<S-F12>", vim.lsp.buf.references,      "References")
                    map("n", "gI",      vim.lsp.buf.implementation,  "Go to implementation")
                    map("n", "<leader>D", vim.lsp.buf.type_definition, "Type definition")

                    -- Info / actions
                    map("n", "K",  vim.lsp.buf.hover,       "Hover")
                    map("n", "gh", vim.lsp.buf.hover,       "Hover")
                    map("n", "<leader>rn", vim.lsp.buf.rename,      "Rename")
                    map("n", "<F2>",       vim.lsp.buf.rename,      "Rename")
                    map("n", "<leader>ca", vim.lsp.buf.code_action, "Code action")
                    map("i", "<C-s>", vim.lsp.buf.signature_help, "Signature help")

                    -- Diagnostics
                    map("n", "[d", function() vim.diagnostic.jump({ count = -1 }) end, "Previous diagnostic")
                    map("n", "]d", function() vim.diagnostic.jump({ count =  1 }) end, "Next diagnostic")
                    map("n", "<leader>cd", vim.diagnostic.open_float, "Line diagnostics")

                    -- Inlay hints (clangd/pyright/lua_ls all support these)
                    if client and client.server_capabilities.inlayHintProvider then
                        vim.lsp.inlay_hint.enable(true, { bufnr = event.buf })
                        map("n", "<leader>uh", function()
                            vim.lsp.inlay_hint.enable(
                                not vim.lsp.inlay_hint.is_enabled({ bufnr = event.buf }),
                                { bufnr = event.buf }
                            )
                        end, "Toggle inlay hints")
                    end

                    if client and client.name == "clangd" then
                        map("n", "<leader>cs", "<cmd>ClangdSwitchSourceHeader<CR>", "Switch source/header")
                        compile_commands.ensure(vim.api.nvim_buf_get_name(event.buf))
                    end
                end,
            })
        end,
    },
}
