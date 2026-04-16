return {
    "saghen/blink.cmp",
    version = "1.*",
    dependencies = { "rafamadriz/friendly-snippets" },
    event = "InsertEnter",
    opts = {
        keymap = { preset = "default" },
        sources = {
            default = { "lsp", "path", "snippets", "buffer" },
        },
        completion = {
            menu = {
                draw = {
                    columns = { { "kind_icon" }, { "label", "label_description", gap = 1 } },
                },
            },
            documentation = {
                auto_show = true,
                auto_show_delay_ms = 200,
            },
        },
        signature = { enabled = true },
    },
}
