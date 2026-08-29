--- encore.nvim — action history, replay and reports on top of CmdAtom.
---
--- Public API:
---   require("encore").setup({ ... })
---   require("encore").toggle_history() / .open_report() / .toggle_hud()
---   require("encore").replay_last()
---   require("encore").recent(10) / .get()
local M = {}

local api = vim.api
local config = require("encore.config")
local engine = require("encore.engine")
local render = require("encore.render")
local highlight = require("encore.highlight")

M.engine = engine
M.render = render

--- Replay the most recent action.
function M.replay_last()
    local entries = engine.recent(1)
    if #entries == 0 then
        vim.notify("encore: no actions recorded yet", vim.log.levels.WARN)
        return
    end
    require("encore.history").replay(entries[1], 1)
end

---@type table<string, { impl: fun(), complete?: fun(arg_lead: string): string[] }>
local subcommand_tbl = {
    open = {
        impl = function()
            require("encore.history").open()
        end,
    },
    toggle = {
        impl = function()
            require("encore.history").toggle()
        end,
    },
    report = {
        impl = function()
            require("encore.report").open()
        end,
    },
    hud = {
        impl = function()
            require("encore.hud").toggle()
        end,
    },
    clear = {
        impl = function()
            local engine = require("encore.engine")
            local n = #engine.get()
            local choice = vim.fn.confirm(
                string.format("encore: clear all %d recorded actions? This cannot be undone.", n),
                "&Yes\n&No",
                2
            )
            if choice ~= 1 then
                return
            end
            engine.clear()
            engine.save() -- persist the empty log immediately
            require("encore.history").refresh()
            vim.notify("encore: history cleared", vim.log.levels.INFO)
        end,
    },
}

---@param opts table :h lua-guide-commands-create
local function encore_cmd(opts)
    local fargs = opts.fargs
    local subcommand_key = fargs[1] or "toggle"
    local subcommand = subcommand_tbl[subcommand_key]
    if not subcommand then
        vim.notify("encore: unknown command: " .. subcommand_key, vim.log.levels.ERROR)
        return
    end
    subcommand.impl()
end

---@param user_opts? EncoreConfig
function M.setup(user_opts)
    config.merge_config(user_opts)

    -- the augroup is shared by highlight/views; ensure it exists
    vim.api.nvim_create_augroup("encore_ui", { clear = true })

    engine.start(config.opts.engine)
    highlight.setup()
    require("encore.history").setup()

    if config.opts.hud.enabled then
        require("encore.hud").start()
    end

    api.nvim_create_user_command("Encore", encore_cmd, {
        nargs = "*",
        complete = function(arg_lead, cmdline, _)
            if cmdline:match("^['<,'>]*Encore[!]*%s+%w*$") then
                return vim.iter(vim.tbl_keys(subcommand_tbl))
                    :filter(function(key)
                        return key:find(arg_lead) ~= nil
                    end)
                    :totable()
            end
            return {}
        end,
        bang = true,
    })
end

--- All collected entries, oldest first.
---@return EncoreEntry[]
function M.get()
    return engine.get()
end

--- Last n entries, most recent first.
---@param n? integer
---@return EncoreEntry[]
function M.recent(n)
    return engine.recent(n)
end

--- Human-readable name for an entry.
---@param entry EncoreEntry
---@return string
function M.atom_name(entry)
    return render.atom(entry)
end

function M.toggle_history()
    require("encore.history").toggle()
end

function M.open_report()
    require("encore.report").open()
end

function M.toggle_hud()
    require("encore.hud").toggle()
end

return M
