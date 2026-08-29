--- History view: floating list of all actions, oldest at the top and
--- newest at the bottom (the cursor starts on the newest). Navigate
--- with j/k, replay with <CR>, jump to the report with r.
local api = vim.api
local config = require("encore.config")
local render = require("encore.render")
local ui = require("encore.ui")
local engine = require("encore.engine")

local M = {
    win = nil,
    buf = nil,
    rows = {}, -- { entry } indexed by window row (1-based)
    cursor_entry = nil,
    winenter_au = nil,
}

--- Feed `keys` as user input, `count` times in a row. "n": do not
--- remap (resolved keys). "m": remap (lhs, when keys was nil / lossy).
---@param entry EncoreEntry
---@param count? integer
function M.replay(entry, count)
    if api.nvim_get_mode().mode ~= "n" then
        vim.notify("encore: replay only works from normal mode", vim.log.levels.WARN)
        return
    end
    if not entry.replay or entry.replay == "" then
        vim.notify("encore: this action is not replayable", vim.log.levels.WARN)
        return
    end
    M.close()
    local flag = (entry.keys ~= nil) and "n" or "m"
    count = math.max(1, count or 1)
    -- interactive feedkeys DOES emit CmdAtom: suppress matching reproductions
    engine.suppress(entry, count)
    vim.schedule(function()
        for _ = 1, count do
            vim.api.nvim_feedkeys(entry.replay, flag .. "tx", false)
        end
    end)
end

---@param entry EncoreEntry
---@return table[] chunks
local function row(entry)
    local chunks = {
        { text = render.icon(entry) .. " ", hl = "EncoreTypeIcon" },
        { text = render.pad(render.atom(entry), 14), hl = "EncoreName" },
    }
    if config.opts.history.show_description then
        chunks[#chunks + 1] = { text = "  " .. render.pad(render.describe(entry), 28), hl = "EncoreDesc" }
    end
    if config.opts.history.show_time then
        chunks[#chunks + 1] = { text = "  " .. render.time_ago(entry.epoch), hl = "EncoreTime" }
    end
    return chunks
end

local function render_view()
    -- oldest first, newest at the bottom; coalesced, capped at render_limit
    local all = engine.get()
    local limit = config.opts.history.render_limit
    local first = (limit and limit > 0) and math.max(1, #all - limit + 1) or 1
    local entries = {}
    for i = first, #all do
        entries[#entries + 1] = all[i]
    end
    local filters = config.opts.filters
    local fold = config.opts.history.fold_repeats
    local fold_min = config.opts.history.fold_min
    local lines = {}
    local folds = {} -- { start, count } runs of identical atoms
    M.rows = {}
    local function visible(e)
        return not render.filtered(e, filters, "history")
    end
    local i = 1
    local line = 0
    while i <= #entries do
        if not visible(entries[i]) then
            i = i + 1
        else
            local atom = render.atom(entries[i])
            local count = 1
            local j = i + 1
            while j <= #entries and visible(entries[j]) and render.atom(entries[j]) == atom do
                count = count + 1
                j = j + 1
            end
            for k = i, j - 1 do
                lines[#lines + 1] = row(entries[k])
                M.rows[#M.rows + 1] = entries[k]
            end
            -- flat, single-level folds: only runs at least fold_min long
            if fold and count >= fold_min then
                folds[#folds + 1] = { start = line + 1, count = count }
            end
            line = line + count
            i = j
        end
    end
    if #M.rows == 0 then
        -- empty state: one hint line, no selectable rows
        lines[1] = { { text = "  no actions yet — go edit something", hl = "EncoreDim" } }
    end
    ui.set_chunks(M.buf, lines)
    -- (Re)create folds from scratch each render: a stale fold is off by
    -- one after a set_chunks rewrite, so zE first (like nvim's undotree)
    if #folds > 0 and api.nvim_get_option_value("foldmethod", { win = M.win }) == "manual" then
        api.nvim_buf_call(M.buf, function()
            vim.cmd("normal! zE")
            for _, f in ipairs(folds) do
                vim.cmd(string.format("%d,%dfold", f.start, f.start + f.count - 1))
            end
        end)
    end
    return M.rows
end

--- Re-render, keeping the cursor on the same entry when possible.
local function refresh()
    if not M.win or not api.nvim_win_is_valid(M.win) then
        return
    end
    local rows = render_view()
    local row = math.max(1, #rows) -- newest entry, at the bottom (row 1 = the empty-state hint)
    for i, entry in ipairs(rows) do
        if M.cursor_entry and entry == M.cursor_entry then
            row = i
            break
        end
    end
    api.nvim_win_set_cursor(M.win, { row, 0 })
end

--- Refresh requests are coalesced: bursty input (scrolling, mouse) with
--- the history view open would otherwise re-render the whole view per
--- event.
local refresh_pending = false
local function request_refresh()
    if refresh_pending then
        return
    end
    refresh_pending = true
    vim.defer_fn(function()
        refresh_pending = false
        refresh()
    end, 100)
end

--- Re-render immediately (used by :Encore clear); entry-driven updates
--- go through the coalesced path instead.
function M.refresh()
    refresh()
end

local function set_keymaps()
    local km = config.opts.keymaps.history
    local opts = { buffer = M.buf, nowait = true, silent = true }
    local function bind(lhs, rhs)
        if type(lhs) == "string" then
            lhs = { lhs }
        end
        for _, l in ipairs(lhs) do
            vim.keymap.set("n", l, rhs, opts)
        end
    end

    local function cursor_entry()
        local row, _ = unpack(api.nvim_win_get_cursor(M.win))
        M.cursor_entry = M.rows[row]
        return M.rows[row]
    end

    -- replay a list of entries in order, oldest first
    local function replay_entries(entries)
        for _, entry in ipairs(entries) do
            engine.suppress(entry, 1)
        end
        M.close()
        vim.schedule(function()
            for _, entry in ipairs(entries) do
                local flag = (entry.keys ~= nil) and "n" or "m"
                vim.api.nvim_feedkeys(entry.replay, flag .. "tx", false)
            end
        end)
    end

    bind(km.quit, function()
        M.close()
    end)
    -- j/k move natively; CursorMoved keeps the cursor entry in sync
    api.nvim_create_autocmd("CursorMoved", {
        buffer = M.buf,
        callback = function()
            local row = unpack(api.nvim_win_get_cursor(M.win))
            M.cursor_entry = M.rows[row]
        end,
    })
    bind(km.replay, function()
        local entry = cursor_entry()
        if entry then
            M.replay(entry, vim.v.count > 0 and vim.v.count or 1)
        end
    end)
    bind(km.report, function()
        M.close()
        require("encore.report").open()
    end)
    bind(km.help, function()
        require("encore.help").open({
            quit = { lhs = km.quit, desc = "Close the history" },
            replay = { lhs = km.replay, desc = "Replay the action under the cursor (v:count repeats)" },
            replay_range = { lhs = "v_" .. km.replay_range, desc = "Replay the selection in order" },
            delete = { lhs = km.delete, desc = "Delete the entry under the cursor" },
            delete_range = { lhs = "v_" .. km.delete, desc = "Delete the selection" },
            macro = { lhs = "v_" .. km.macro, desc = 'Merge the selection into a macro register ("aM = register a)' },
            report = { lhs = km.report, desc = "Open the session report" },
            help = { lhs = km.help, desc = "Show this page" },
        })
    end)

    -- selection rows in the view buffer (visual-mode range)
    local function selected_rows()
        -- '< and '> lag in visual mode: use the v mark + cursor
        local start_row = vim.fn.getpos("v")[2]
        local end_row = vim.fn.getpos(".")[2]
        local lo, hi = math.min(start_row, end_row), math.max(start_row, end_row)
        return lo, hi
    end

    -- visual-mode <CR>: replay the selection in order
    vim.keymap.set("x", km.replay_range, function()
        local lo, hi = selected_rows()
        local replayable = {}
        for r = lo, hi do
            local entry = M.rows[r]
            if entry and entry.replay and entry.replay ~= "" then
                replayable[#replayable + 1] = entry
            end
        end
        if #replayable == 0 then
            vim.notify("encore: nothing replayable in the selection", vim.log.levels.WARN)
            return
        end
        replay_entries(replayable)
    end, { buffer = M.buf, nowait = true, silent = true })

    -- dd: delete under cursor (normal) or selection (visual); keep cursor stable
    local function delete_rows(lo, hi)
        local cursor_row = unpack(api.nvim_win_get_cursor(M.win))
        local entries = {}
        for r = lo, hi do
            entries[#entries + 1] = M.rows[r]
        end
        engine.remove(entries)
        refresh()
        local row = math.max(1, math.min(cursor_row, #M.rows))
        api.nvim_win_set_cursor(M.win, { row, 0 })
        M.cursor_entry = M.rows[row]
    end
    vim.keymap.set("n", km.delete, function()
        local row = unpack(api.nvim_win_get_cursor(M.win))
        if M.rows[row] then
            delete_rows(row, row)
        end
    end, { buffer = M.buf, nowait = true, silent = true })
    vim.keymap.set("x", km.delete, function()
        local lo, hi = selected_rows()
        api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
        delete_rows(lo, hi)
    end, { buffer = M.buf, nowait = true, silent = true })

    -- M (visual): merge the selection into a macro register ("aM = register a, default q)
    vim.keymap.set("x", km.macro, function()
        local lo, hi = selected_rows()
        local parts = {}
        for r = lo, hi do
            local entry = M.rows[r]
            if entry and entry.replay and entry.replay ~= "" then
                parts[#parts + 1] = entry.replay
            end
        end
        if #parts == 0 then
            vim.notify("encore: nothing replayable in the selection", vim.log.levels.WARN)
            return
        end
        local reg = vim.v.register
        if not reg:match("^[a-zA-Z]$") then -- no explicit letter register: default to q
            reg = "q"
        end
        vim.fn.setreg(reg, table.concat(parts))
        api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
        vim.notify(string.format("encore: %d actions saved to register %s", #parts, reg), vim.log.levels.INFO)
    end, { buffer = M.buf, nowait = true, silent = true })
end

--- Open the view: suspend the HUD, (re)create the float, render.
function M.open()
    local hud = require("encore.hud")
    hud.suspend()

    if not M.buf then
        M.buf = ui.new_buf("encore")
        set_keymaps()
    end

    if not M.win or not api.nvim_win_is_valid(M.win) then
        local w = config.dim(config.opts.history.width, vim.o.columns)
        local h = config.dim(config.opts.history.height, vim.o.lines)
        M.win = ui.new_win(M.buf, {
            relative = "editor",
            anchor = "SE",
            width = w,
            height = h,
            row = vim.o.lines - 2,
            col = vim.o.columns - w - 1,
            border = config.opts.ui.border,
            title = " Encore ",
            title_pos = "left",
            footer = " ? help  q quit ",
            footer_pos = "center",
            zindex = config.opts.history.zindex,
        }, { enter = true, cursorline = true })
    else
        api.nvim_set_current_win(M.win)
    end
    -- folds need foldmethod=manual; window-local only — the user's global fold settings stay untouched
    api.nvim_set_option_value("foldmethod", "manual", { win = M.win })
    refresh()

    -- close on focus-leave (helper page exempt); persistent so it survives the helper stealing focus
    M.winenter_au = vim.api.nvim_create_autocmd("WinEnter", {
        callback = function()
            local cur = api.nvim_get_current_win()
            if cur ~= M.win and not require("encore.help").is_help(cur) then
                M.close()
            end
        end,
    })
end

--- Close the view and resume the HUD.
function M.close()
    if M.winenter_au then
        api.nvim_del_autocmd(M.winenter_au)
        M.winenter_au = nil
    end
    if ui.close_win(M.win) then
        M.win = nil
    end
    require("encore.hud").resume()
end

--- Toggle the view.
function M.toggle()
    if M.win and api.nvim_win_is_valid(M.win) then
        M.close()
    else
        M.open()
    end
end

--- Subscribe to engine entries: refresh the view if it is open.
function M.setup()
    engine.on_entry(function()
        request_refresh()
    end)
end

return M
