--- Plain-text action stack: N invisible floating lines (noice-style
--- stacking), each one line of plain text — icon dim, action name bold
--- (newest) or dim (older), description dim. No pill backgrounds, no
--- border. The newest sits at the bottom; each fades after `timeout`.
local api = vim.api
local config = require("encore.config")
local render = require("encore.render")
local ui = require("encore.ui")
local engine = require("encore.engine")

local M = {
    ns = api.nvim_create_namespace("encore_hud"),
    toasts = {}, -- newest first: { entry, win, buf, deadline, timer }
    enabled = false,
    suspended = false,
    last = nil,
    augroup = nil,
    started = false,
}

local TOAST_ROWS = 3 -- 1 content row + 2 border rows

--- Full width of one plain-text line.
---@param entry table
---@param count? integer merged repeat count
---@return integer
local function content_width(entry, count)
    local w = vim.fn.strdisplaywidth(render.icon(entry) .. " ")
        + vim.fn.strdisplaywidth(render.atom(entry))
        + vim.fn.strdisplaywidth("  " .. render.describe(entry))
    if count and count > 1 then
        w = w + vim.fn.strdisplaywidth(" ×" .. count)
    end
    return w
end

--- One line of plain text: icon dim, name bold (newest) or dim, desc dim.
---@param entry table
---@param is_newest boolean
---@param width integer window width
---@param count? integer merged repeat count
---@return table[][] one line of chunks
local function plain_line(entry, is_newest, width, count)
    local desc = render.describe(entry)
    local cap = config.dim(config.opts.hud.width, vim.o.columns)
    if width >= cap then
        local inner = width - 4
        local used = vim.fn.strdisplaywidth(render.icon(entry) .. " ") + vim.fn.strdisplaywidth(render.atom(entry)) + 2
        if count and count > 1 then
            used = used + vim.fn.strdisplaywidth(" ×" .. count)
        end
        desc = render.clip(desc, inner - used)
    end
    local line = {
        { text = render.icon(entry) .. " ", hl = "EncoreDim" },
        { text = render.atom(entry), hl = is_newest and "EncoreName" or "EncoreDim" },
    }
    if count and count > 1 then
        line[#line + 1] = { text = " ×" .. count, hl = "EncoreCount" }
    end
    line[#line + 1] = { text = "  " .. desc, hl = "EncoreDim" }
    return line
end

---@param entry table
---@param count? integer merged repeat count
---@param offset integer stack offset (0 = newest)
---@return table win_config
local function toast_config(entry, count, offset)
    local cap = config.dim(config.opts.hud.width, vim.o.columns)
    local width = math.max(3, math.min(content_width(entry, count), cap))
    local pos = config.opts.hud.position
    local is_bottom = pos:find("bottom") ~= nil
    local is_right = pos:find("right") ~= nil
    local row = is_bottom and (vim.o.lines - 5 - offset * TOAST_ROWS) or (1 + offset * TOAST_ROWS)
    local col = is_right and (vim.o.columns - width - 2) or 2
    return {
        relative = "editor",
        anchor = "NW",
        width = width,
        height = 1,
        row = row,
        col = col,
        style = "minimal",
        border = config.opts.ui.border,
        focusable = false,
        zindex = config.opts.hud.zindex,
        noautocmd = true,
    }
end

--- Open one toast: an invisible window with a single plain-text line.
---@param toast table
---@param offset integer
local function open_toast(toast, offset)
    if not (toast.buf and api.nvim_buf_is_valid(toast.buf)) then
        toast.buf = ui.new_buf("encore")
    end
    toast.win = ui.new_win(toast.buf, toast_config(toast.entry, toast.count, offset), { enter = false })
    ui.theme_win(toast.win, M.ns, {
        NormalFloat = { link = "Normal" },
        FloatBorder = { link = "Comment" },
        EncoreName = { bold = true },
        EncoreDim = { link = "Comment" },
    })
    local width = api.nvim_win_get_width(toast.win)
    ui.set_chunks(toast.buf, { plain_line(toast.entry, offset == 0, width, toast.count) })
end

--- Close every open toast window (buffers kept for reuse).
local function close_wins()
    for _, t in ipairs(M.toasts) do
        if t.win and api.nvim_win_is_valid(t.win) then
            api.nvim_win_close(t.win, true)
        end
        if t.timer then
            pcall(t.timer.close, t.timer)
            t.timer = nil
        end
        t.win = nil
    end
end

--- Re-render the stack: drop expired, cap to hud.max, reopen the rest.
local function render_stack()
    close_wins()
    local now = vim.uv.hrtime()
    local keep = {}
    for _, t in ipairs(M.toasts) do
        if t.deadline > now and #keep < config.opts.hud.max then
            keep[#keep + 1] = t
        end
    end
    M.toasts = keep
    for i, t in ipairs(keep) do -- i=1 newest → offset 0
        open_toast(t, i - 1)
        t.timer = vim.defer_fn(function()
            t.timer = nil -- the firing timer must not close itself
            render_stack()
        end, math.floor((t.deadline - vim.uv.hrtime()) / 1e6))
    end
end

--- Render requests are coalesced: bursty input (scrolling, mouse) would
--- otherwise close+rebuild every toast window per event.
local render_pending = false
local function request_render()
    if render_pending then
        return
    end
    render_pending = true
    vim.defer_fn(function()
        render_pending = false
        render_stack()
    end, 100)
end

--- Does `new` continue the action shown by the newest toast? Same atom
--- rendering = same action (j twice merges, j then k does not).
---@param new EncoreEntry
---@param old EncoreEntry
---@return boolean
local function same_action(new, old)
    return render.atom(new) == render.atom(old)
end

function M.show(entry)
    if not M.enabled or M.suspended then
        M.last = entry
        return
    end
    -- filtered actions never reach the HUD
    if render.filtered(entry, config.opts.filters, "hud") then
        return
    end
    M.last = entry
    -- consecutive repeats merge into one toast with a count
    local newest = M.toasts[1]
    if config.opts.hud.merge and newest and same_action(entry, newest.entry) then
        newest.count = (newest.count or 1) + 1
        newest.deadline = vim.uv.hrtime() + config.opts.hud.timeout * 1e6
        request_render()
        return
    end
    table.insert(M.toasts, 1, {
        entry = entry,
        count = 1,
        win = nil,
        buf = nil,
        deadline = vim.uv.hrtime() + config.opts.hud.timeout * 1e6,
    })
    request_render()
end

--- Hide while another encore view takes the corner.
function M.suspend()
    for _, t in ipairs(M.toasts) do
        if t.win and api.nvim_win_is_valid(t.win) then
            api.nvim_win_close(t.win, true)
        end
        if t.buf and api.nvim_buf_is_valid(t.buf) then
            api.nvim_buf_delete(t.buf, { force = true })
        end
        if t.timer then
            pcall(t.timer.close, t.timer)
        end
    end
    M.toasts = {}
    M.suspended = true
end

--- Resume after a suspend: re-show the last action.
function M.resume()
    if not M.suspended then
        return -- resume() is a no-op when nothing was suspended
    end
    M.suspended = false
    if M.last then
        M.show(M.last)
    end
end

--- Start the HUD: subscribe to engine entries, react to resizes.
--- Idempotent.
function M.start()
    if M.started then
        return -- idempotent: setup() may run more than once
    end
    M.started = true
    M.enabled = true
    engine.on_entry(function(entry)
        M.show(entry)
    end)

    M.augroup = api.nvim_create_augroup("encore_hud", { clear = true })
    api.nvim_create_autocmd({ "VimResized", "ColorScheme" }, {
        group = M.augroup,
        callback = function()
            close_wins()
        end,
    })
    api.nvim_create_autocmd("TabEnter", {
        group = M.augroup,
        callback = function()
            close_wins()
        end,
    })
    api.nvim_create_autocmd("WinClosed", {
        group = M.augroup,
        callback = function(ev)
            local closed = tonumber(ev.match)
            for _, t in ipairs(M.toasts) do
                if t.win and closed == t.win then
                    t.win = nil
                end
            end
        end,
    })
end

--- Toggle the HUD on/off.
function M.toggle()
    M.enabled = not M.enabled
    if not M.enabled then
        M.suspend()
        M.suspended = false
    else
        M.resume()
    end
end

return M
