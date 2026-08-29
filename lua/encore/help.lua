--- Helper page: centered float listing a view's keybindings (`lhs<TAB>desc`,
--- atone-style vartabstop alignment).
local api = vim.api
local config = require("encore.config")
local ui = require("encore.ui")

local M = {
    win = nil,
    buf = nil,
    opening = false, -- true between nvim_open_win and M.win being set
    ns = api.nvim_create_namespace("encore_help"),
}

---@param mappings table<string, { lhs: string|string[], desc: string }>
function M.open(mappings)
    if M.win and api.nvim_win_is_valid(M.win) then
        api.nvim_set_current_win(M.win)
        return
    end
    if not M.buf then
        M.buf = ui.new_buf("encore")
    end

    local lines = {}
    local lhs_list = {}
    local max_lhs = 0
    local max_desc = 0
    for _, m in pairs(mappings) do
        local lhs = m.lhs
        if type(lhs) == "table" then
            lhs = table.concat(lhs, "/")
        end
        lhs_list[#lhs_list + 1] = lhs
        max_lhs = math.max(max_lhs, vim.fn.strwidth(lhs))
        max_desc = math.max(max_desc, vim.fn.strwidth(m.desc))
        lines[#lines + 1] = lhs .. "\t" .. m.desc
    end

    api.nvim_set_option_value("vartabstop", tostring(max_lhs + 4), { buf = M.buf })
    api.nvim_set_option_value("modifiable", true, { buf = M.buf })
    api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
    api.nvim_buf_clear_namespace(M.buf, M.ns, 0, -1)
    for i, lhs in ipairs(lhs_list) do
        api.nvim_buf_set_extmark(M.buf, M.ns, i - 1, 0, {
            end_col = #lhs, -- bytes; extmark columns are byte-based
            hl_group = "EncoreName",
        })
    end
    api.nvim_set_option_value("modifiable", false, { buf = M.buf })

    local content_w = max_lhs + 4 + max_desc
    local win_w = math.min(vim.o.columns, content_w + 2)
    local win_h = math.min(vim.o.lines, #lines + 2)
    M.opening = true
    M.win = ui.new_win(M.buf, {
        relative = "editor",
        anchor = "NW",
        row = math.max(0, math.floor((vim.o.lines - win_h) / 2)),
        col = math.max(0, math.floor((vim.o.columns - win_w) / 2)),
        width = win_w,
        height = win_h,
        zindex = 150,
        style = "minimal",
        border = config.opts.ui.border,
    }, { enter = true })
    M.opening = false

    local opts = { buffer = M.buf, nowait = true, silent = true }
    local quit = config.opts.keymaps.help.quit
    if type(quit) == "string" then
        quit = { quit }
    end
    for _, lhs in ipairs(quit) do
        vim.keymap.set("n", lhs, function()
            M.close()
        end, opts)
    end

    vim.api.nvim_create_autocmd("WinLeave", {
        once = true,
        callback = function()
            if api.nvim_get_current_win() == M.win then
                M.close()
            end
        end,
    })
end

function M.close()
    if M.win and api.nvim_win_is_valid(M.win) then
        api.nvim_win_close(M.win, true)
    end
    M.win = nil
end

--- Is `win` the helper window? Views keep their close-on-focus-leave
--- logic from firing when the helper takes focus. `opening` covers the
--- WinEnter fired inside nvim_open_win, before M.win is assigned.
---@param win integer
---@return boolean
function M.is_help(win)
    return M.opening or (M.win ~= nil and M.win == win)
end

return M
