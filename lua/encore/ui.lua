--- Floating window + chunk rendering utilities shared by the views.
--- A "chunk" is { text = string, hl = string|nil }. A view renders an
--- array of lines, each an array of chunks, into a scratch buffer via
--- extmarks so highlights are exact.
local api = vim.api
local M = {}

M.ns = api.nvim_create_namespace("encore_ui")

---@param ft string
---@return integer buf
function M.new_buf(ft)
    local buf = api.nvim_create_buf(false, true)
    api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
    api.nvim_set_option_value("buftype", "nofile", { buf = buf })
    api.nvim_set_option_value("swapfile", false, { buf = buf })
    api.nvim_set_option_value("modifiable", false, { buf = buf })
    api.nvim_set_option_value("filetype", ft, { buf = buf })
    return buf
end

---@param buf integer
---@param config table win_config for nvim_open_win
---@param opts? { enter?: boolean, cursorline?: boolean, winhighlight?: string, winblend?: integer }
---@return integer win
function M.new_win(buf, config, opts)
    opts = opts or {}
    local win = api.nvim_open_win(buf, opts.enter ~= false, config)
    api.nvim_set_option_value("number", false, { win = win })
    api.nvim_set_option_value("relativenumber", false, { win = win })
    api.nvim_set_option_value("signcolumn", "no", { win = win })
    api.nvim_set_option_value("list", false, { win = win })
    api.nvim_set_option_value("wrap", false, { win = win })
    api.nvim_set_option_value("winfixbuf", true, { win = win })
    api.nvim_set_option_value("cursorline", opts.cursorline or false, { win = win })
    if opts.winhighlight then
        api.nvim_set_option_value("winhighlight", opts.winhighlight, { win = win })
    end
    if opts.winblend then
        api.nvim_set_option_value("winblend", opts.winblend, { win = win })
    end
    return win
end

--- Replace the buffer content with chunk-rendered lines.
---@param buf integer
---@param lines table[][] { text: string, hl?: string }
function M.set_chunks(buf, lines)
    api.nvim_set_option_value("modifiable", true, { buf = buf })

    local texts = {}
    for i, line in ipairs(lines) do
        local parts = {}
        for _, chunk in ipairs(line) do
            parts[#parts + 1] = chunk.text
        end
        texts[i] = table.concat(parts)
    end
    api.nvim_buf_set_lines(buf, 0, -1, true, texts)

    -- clear previous extmarks in this namespace
    api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)

    for i, line in ipairs(lines) do
        local byte = 0
        for _, chunk in ipairs(line) do
            local len = #chunk.text
            if chunk.hl and len > 0 then
                api.nvim_buf_set_extmark(buf, M.ns, i - 1, byte, {
                    end_col = byte + len,
                    hl_group = chunk.hl,
                    strict = false,
                })
            end
            byte = byte + len
        end
    end

    api.nvim_set_option_value("modifiable", false, { buf = buf })
end

--- Safe close: returns false if the window is already gone.
---@param win integer|nil
---@return boolean
function M.close_win(win)
    if win and api.nvim_win_is_valid(win) then
        api.nvim_win_close(win, true)
        return true
    end
    return false
end

-- Color helpers and namespace-scoped highlights.

--- A highlight group value as set by the current colorscheme.
---@param name string
---@return table
function M.get_hl(name)
    return vim.api.nvim_get_hl(0, { name = name, link = false })
end

--- Window-local theme: set groups in `ns`, apply to `win`.
---@param win integer
---@param ns integer
---@param groups table<string, table>
function M.theme_win(win, ns, groups)
    for name, opts in pairs(groups) do
        vim.api.nvim_set_hl(ns, name, opts)
    end
    vim.api.nvim_win_set_hl_ns(win, ns)
end

return M
