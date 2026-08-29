local M = {}

---@type EncoreConfig
M.opts = {
    engine = {
        ---@type integer
        --- number of actions kept in memory
        capacity = 20000,
        persist = {
            ---@type boolean
            --- save the action log to disk, restored on startup
            enabled = true,
            ---@type string
            --- JSON log file
            path = vim.fn.stdpath("data") .. "/encore/history.json",
            ---@type integer
            --- max entries kept on disk
            max = 20000,
            ---@type integer
            --- seconds between dirty saves (also saved on exit)
            interval = 60,
            --- safety net: keep only the newest entries that fit this
            --- many encoded bytes (guards against runaway bloat)
            max_bytes = 64 * 1024 * 1024,
        },
    },
    hud = {
        ---@type boolean
        enabled = true,
        ---@type integer
        --- how long each popup stays visible, ms
        timeout = 4000,
        ---@type integer
        --- number of stacked popups
        max = 3,
        ---@type boolean
        --- consecutive repeats of the same action merge into one popup with a count
        merge = true,
        ---@type "bottom-right"|"top-right"|"bottom-left"|"top-left"
        position = "bottom-right",
        ---@type number
        --- width relative to editor columns (float < 1), absolute cols otherwise
        width = 0.4,
        ---@type integer
        zindex = 100,
    },
    history = {
        ---@type number
        --- width/height relative to the editor (float < 1), absolute cells otherwise
        width = 0.45,
        height = 0.5,
        ---@type integer
        zindex = 55,
        show_description = true,
        show_time = true,
        ---@type boolean
        --- fold consecutive repeats of the same action with native vim folds
        fold_repeats = true,
        ---@type integer
        --- minimum run length to fold (runs shorter than this stay flat)
        fold_min = 3,
        ---@type integer
        --- max rows rendered in the view (keeps full re-renders bounded);
        --- set to 0 for no limit
        render_limit = 5000,
    },
    report = {
        ---@type integer
        zindex = 56,
    },
    ui = {
        --- refer to `:h 'winborder'`
        border = "rounded",
    },
    filters = {
        -- Drop matching actions from a view. `pattern` is a Lua pattern
        -- matched against the action's name as it appears in the HUD and
        -- history (the part after the icon, e.g. "j", "scroll", "diw",
        -- ":cnext", "ihello"). Plain letters match as a substring, so
        -- use "^name$" for an exact name. `views` limits the filter to
        -- "hud" and/or "history" (default: both).
        -- Examples:
        -- { pattern = "^scroll$", views = { "hud" } }, -- hide scrolling from the HUD, keep it in history
        -- { pattern = "^:w$" },                          -- drop :w everywhere
    },
    keymaps = {
        history = {
            quit = { "<C-c>", "q" },
            replay = "<CR>",
            replay_range = "<CR>",
            delete = "dd",
            macro = "M",
            report = "r",
            help = "?",
        },
        report = {
            quit = { "<C-c>", "q" },
            toggle_scope = "<Tab>",
            export = "y",
            focus_next = ">",
            focus_prev = "<",
            help = "?",
        },
        help = {
            quit = { "<C-c>", "q" },
        },
    },
}

---@param user_opts? EncoreConfig
function M.merge_config(user_opts)
    user_opts = user_opts or {}
    M.opts = vim.tbl_deep_extend("force", M.opts, user_opts)
end

--- Resolve a width/height value against an editor dimension.
--- float < 1: fraction of the editor. integer >= 1: absolute cells.
---@param v number
---@param total integer
---@return integer
function M.dim(v, total)
    if v < 1 then
        return math.max(1, math.floor(total * v))
    end
    return v
end

return M
