-- Shared terminal-app detection. Cached so the tmux subprocess only runs once
-- per nvim launch even when both options.lua and colorscheme.lua call us.
local cached

local function program()
    if cached ~= nil then return cached end
    local tp = vim.env.TERM_PROGRAM
    if tp == "tmux" and vim.env.TMUX then
        local out = vim.fn.system({ "tmux", "show-environment", "-g", "TERM_PROGRAM" })
        local orig = out:match("TERM_PROGRAM=(%S+)")
        if orig and orig ~= "tmux" then tp = orig end
    end
    cached = tp or ""
    return cached
end

return {
    is_apple_terminal = function() return program() == "Apple_Terminal" end,
}
