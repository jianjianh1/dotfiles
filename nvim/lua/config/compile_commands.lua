-- Auto-generate compile_commands.json so clangd has project structure
-- without manual setup. CMake configure is fast and non-destructive so we
-- run it eagerly; `bear -- make` actually builds the project so we expose
-- it as a one-tap command instead.

local M = {}

local BUILD_DIRS = { "build", "Build", "out", "cmake-build-debug", "cmake-build-release" }
local ROOT_MARKERS = { "compile_commands.json", "CMakeLists.txt", "Makefile", ".git" }

-- Per-session cache so we don't retry on every buffer open.
local attempted = {}

local function notify(msg, level)
    vim.notify("[clangd] " .. msg, level or vim.log.levels.INFO)
end

local function find_root(start)
    local found = vim.fs.find(ROOT_MARKERS, { upward = true, path = start, stop = vim.env.HOME })[1]
    if not found then return nil end
    return vim.fs.dirname(found)
end

local function find_compile_commands(root)
    if vim.uv.fs_stat(root .. "/compile_commands.json") then
        return root .. "/compile_commands.json"
    end
    for _, dir in ipairs(BUILD_DIRS) do
        local path = root .. "/" .. dir .. "/compile_commands.json"
        if vim.uv.fs_stat(path) then return path end
    end
    return nil
end

local function symlink_to_root(target, root)
    pcall(vim.uv.fs_symlink, target, root .. "/compile_commands.json")
end

local function reload_clangd()
    for _, client in ipairs(vim.lsp.get_clients({ name = "clangd" })) do
        vim.lsp.stop_client(client.id, true)
    end
    vim.defer_fn(function() vim.cmd("edit") end, 200)
end

local function run(label, cmd, opts, on_success)
    notify("Generating compile_commands.json via " .. label .. "…")
    vim.system(cmd, opts, vim.schedule_wrap(function(result)
        if result.code ~= 0 then
            notify(label .. " failed (exit " .. result.code .. "):\n" .. (result.stderr or ""),
                vim.log.levels.ERROR)
            return
        end
        if on_success() then
            notify("compile_commands.json ready — reloading clangd")
            reload_clangd()
        end
    end))
end

local function run_cmake(root)
    run("cmake",
        { "cmake", "-S", root, "-B", root .. "/build", "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON" },
        { text = true },
        function()
            local generated = root .. "/build/compile_commands.json"
            if not vim.uv.fs_stat(generated) then
                notify("cmake succeeded but compile_commands.json not found", vim.log.levels.WARN)
                return false
            end
            symlink_to_root(generated, root)
            return true
        end)
end

local function run_bear(root)
    notify("Note: `bear -- make` will build the project.")
    run("bear", { "bear", "--", "make" }, { cwd = root, text = true }, function() return true end)
end

-- Try to ensure compile_commands.json exists for the project containing `path`.
-- `manual` = invoked via :GenCompileCommands; bypasses the per-session cache
-- and auto-runs bear when available.
function M.ensure(path, manual)
    local root = find_root(path)
    if not root then return end
    if not manual and attempted[root] then return end
    attempted[root] = true

    local existing = find_compile_commands(root)
    if existing then
        -- Already present elsewhere; make sure clangd finds it at the root.
        if existing ~= root .. "/compile_commands.json" then
            symlink_to_root(existing, root)
        end
        return
    end

    local has_cmake = vim.uv.fs_stat(root .. "/CMakeLists.txt") ~= nil
    local has_make = vim.uv.fs_stat(root .. "/Makefile") ~= nil

    if has_cmake and vim.fn.executable("cmake") == 1 then
        run_cmake(root)
        return
    end

    if has_make and vim.fn.executable("bear") == 1 then
        if manual or vim.uv.fs_stat(root .. "/.server-configs-bear-ok") then
            run_bear(root)
        else
            notify("Makefile detected. Run :GenCompileCommands to build with bear, "
                .. "or `touch .server-configs-bear-ok` to auto-run.", vim.log.levels.INFO)
        end
        return
    end

    if manual then
        notify("No CMakeLists.txt/Makefile found, or missing cmake/bear binary.", vim.log.levels.WARN)
    end
end

function M.setup()
    vim.api.nvim_create_user_command("GenCompileCommands", function()
        local path = vim.api.nvim_buf_get_name(0)
        if path == "" then path = vim.uv.cwd() end
        M.ensure(path, true)
    end, { desc = "Generate compile_commands.json for the current project" })
end

return M
