--- Pure rendering helpers: entries/values in, strings or colors out.
--- No side effects, unit-testable without a running UI.
local M = {}

local MAX_TEXT = 16

--- Single-width glyph per atom type. No nerd fonts required.
local ICONS = {
    operator = "✂",
    motion = "→",
    jump = "↷",
    insert = "✎",
    excmd = ":",
    visual = "▣",
    mapping = "@",
    mouse = "✥",
    scroll = "⇅",
    normal = "◆",
}

---@param d EncoreEntry|{ type: string } atom entry (icon only reads the type)
---@return string icon
function M.icon(d)
    return ICONS[d.type] or "◆"
end

--- Clip `s` to `max` display cells by character — multibyte chars
--- (e.g. CJK in insert sessions) are never split.
---@param s string|nil
---@param max? integer defaults to MAX_TEXT
---@return string
function M.clip(s, max)
    max = max or MAX_TEXT
    if type(s) ~= "string" then
        return ""
    end
    if vim.fn.strdisplaywidth(s) <= max then
        return s
    end
    local out = ""
    local w = 0
    for i = 0, vim.fn.strchars(s) - 1 do
        local ch = vim.fn.strcharpart(s, i, 1)
        local cw = vim.fn.strdisplaywidth(ch)
        if w + cw > max - 1 then
            break
        end
        out = out .. ch
        w = w + cw
    end
    return out .. "…"
end

--- Pad or clip a string to exactly `len` display cells. Clipping is
--- multibyte-safe and reserves one cell for the ellipsis.
---@param s string
---@param len integer
---@return string
function M.pad(s, len)
    local out = M.clip(s, len)
    local w = vim.fn.strdisplaywidth(out)
    if w < len then
        out = out .. string.rep(" ", len - w)
    end
    return out
end

--- Raw internal bytes => key-notation (e.g. "\27" => "<Esc>").
---@param s string|nil
---@return string
local function keytrans(s)
    if type(s) ~= "string" then
        return ""
    end
    local ok, out = pcall(vim.fn.keytrans, s)
    return ok and out or s
end

--- Effective count, without the trivial 1.
---@param d EncoreEntry
---@return string
local function cnt(d)
    local n = d.count
    if type(n) ~= "number" or n <= 1 then
        return ""
    end
    return tostring(n)
end

--- Readable name of a single atom, e.g. "d2w", "ci\"", ":cnext".
---@param d EncoreEntry
---@return string
function M.atom(d)
    local t = d.type
    if t == "operator" then
        return (d.operator or "") .. cnt(d) .. (d.cmd or "")
    elseif t == "excmd" then
        return ":" .. (d.text or "")
    elseif t == "insert" then
        return "i" .. M.clip(d.text)
    elseif t == "motion" or t == "jump" then
        return cnt(d) .. (d.cmd or keytrans(d.keys))
    elseif t == "visual" then
        return "v" .. (d.operator or "") .. (d.cmd or "")
    elseif t == "mouse" or t == "scroll" then
        return t
    elseif t == "mapping" then
        -- lhs = the user's typed sequence (mapped motions, macros, <CR>)
        if d.lhs and d.lhs ~= "" then
            return M.clip(keytrans(d.lhs))
        end
        if d.atoms then
            for i = #d.atoms, 1, -1 do
                if d.atoms[i].type == "operator" then
                    return M.atom(d.atoms[i])
                end
            end
            if #d.atoms > 0 then
                return M.atom(d.atoms[#d.atoms])
            end
        end
        return "@"
    elseif t == "normal" then
        return d.cmd or keytrans(d.keys)
    end
    return M.clip(keytrans(d.keys or d.lhs))
end

--- Human words for motions and text objects. Keys are the atom `cmd`
--- (key-notation, no counts), so "d2w" describes as "delete word ×2"
--- instead of "delete 2 w".
local MOTION_WORDS = {
    w = "word",
    b = "word back",
    e = "word end",
    ge = "word end back",
    j = "down",
    k = "up",
    h = "left",
    l = "right",
    gj = "screen down",
    gk = "screen up",
    gg = "to top",
    G = "to bottom",
    ["$"] = "to line end",
    ["0"] = "to line start",
    ["^"] = "to line text",
    ["}"] = "next paragraph",
    ["{"] = "previous paragraph",
    ["%"] = "to matching bracket",
    [")"] = "next sentence",
    ["("] = "previous sentence",
    iw = "inner word",
    aw = "a word",
    ['i"'] = "inside quotes",
    ['a"'] = "around quotes",
    ["i'"] = "inside single quotes",
    ["a'"] = "around single quotes",
    ["i("] = "inside parens",
    ["a("] = "around parens",
    ["i{"] = "inside braces",
    ["a{"] = "around braces",
    ["i["] = "inside brackets",
    ["a["] = "around brackets",
    ["i<"] = "inside angle",
    ["a<"] = "around angle",
    ip = "inside paragraph",
    ap = "a paragraph",
    it = "inside tag",
    at = "a tag",
    x = "char",
    X = "char back",
    D = "to line end",
    C = "rest of line",
    S = "line",
    ["<<"] = "indent left",
    [">>"] = "indent right",
    guw = "lowercase word",
    gUw = "uppercase word",
    ["g~w"] = "toggle case word",
    s = "char and type",
    r = "replace char",
    ["~"] = "toggle case char",
}

--- Human words for common normal-mode commands.
local NORMAL_WORDS = {
    ["<C-W>w"] = "switch window",
    ["<C-W>h"] = "window left",
    ["<C-W>l"] = "window right",
    ["<C-W>s"] = "split window",
    ["<C-W>v"] = "vsplit window",
    ["<C-W>q"] = "close window",
    ["u"] = "undo",
    ["<C-R>"] = "redo",
    p = "paste after",
    P = "paste before",
    gp = "paste after, keep cursor",
    gP = "paste before, keep cursor",
    ["."] = "repeat",
    ["za"] = "toggle fold",
    ["zc"] = "close fold",
    ["zo"] = "open fold",
}

--- Human word for a motion/text-object cmd.
---@param cmd string|nil
---@param cmdarg string|nil
---@return string|nil
function M.motion_word(cmd, cmdarg)
    if not cmd then
        return nil
    end
    if cmd == "f" then
        return cmdarg and ("to char " .. cmdarg) or "to char"
    elseif cmd == "t" then
        return cmdarg and ("until char " .. cmdarg) or "until char"
    end
    return MOTION_WORDS[cmd]
end

--- Count suffix: " ×3" when count > 1, else "". Used for motions.
---@param d EncoreEntry
---@return string
local function cntx(d)
    return (type(d.count) == "number" and d.count > 1) and (" ×" .. tostring(d.count)) or ""
end

--- Plural forms for words used in operator descriptions
--- ("delete 2 words", not "delete 2 word"). Unknown words stay as-is.
local PLURALS = {
    word = "words",
    char = "chars",
    line = "lines",
    ["a word"] = "words",
    ["inner word"] = "inner words",
    ["word end"] = "word ends",
    ["word back"] = "words back",
    ["word end back"] = "word ends back",
    ["char back"] = "chars back",
    ["a paragraph"] = "paragraphs",
    ["a tag"] = "tags",
    ["next sentence"] = "next sentences",
    ["previous sentence"] = "previous sentences",
    ["replace char"] = "replace chars",
    ["char and type"] = "chars and type",
}

---@param word string
---@return string
local function pluralize(word)
    return PLURALS[word] or word
end

--- Short human description. Operators read as "delete word ×2",
--- "change inside quotes"; motions as "down", "to top"; visual as
--- "select a paragraph".
---@param d EncoreEntry
---@return string
function M.describe(d)
    if d.type == "operator" and d.operator then
        local verbs = {
            d = "delete",
            y = "yank",
            c = "change",
            ["g@"] = "opfunc",
        }
        local verb = verbs[d.operator] or d.operator
        local what
        if d.cmd == d.operator and (d.operator == "d" or d.operator == "y" or d.operator == "c") then
            what = "line" -- dd / yy / cc
        else
            what = M.motion_word(d.cmd, d.cmdarg) or d.cmd or ""
        end
        local n = (type(d.count) == "number" and d.count > 1) and tostring(d.count) or nil
        if n then
            return verb .. " " .. n .. " " .. pluralize(what)
        end
        return verb .. " " .. what
    elseif d.type == "operator" then
        -- put commands are operator-typed with no operator name
        local word = NORMAL_WORDS[d.cmd] or M.motion_word(d.cmd, d.cmdarg)
        return (word or d.cmd or "") .. cntx(d)
    elseif d.type == "insert" then
        local n = vim.fn.strchars(d.text or "")
        return "type " .. n .. " char" .. (n == 1 and "" or "s")
    elseif d.type == "excmd" then
        return "run " .. M.clip(d.text or "")
    elseif d.type == "motion" or d.type == "jump" then
        return (M.motion_word(d.cmd, d.cmdarg) or ("move " .. (d.cmd or ""))) .. cntx(d)
    elseif d.type == "visual" then
        local what = M.motion_word(d.cmd, d.cmdarg) or d.cmd or ""
        if d.operator then
            local verbs = {
                d = "delete",
                y = "yank",
                c = "change",
                gu = "lowercase",
                gU = "uppercase",
            }
            local verb = verbs[d.operator] or d.operator
            return verb .. " " .. what
        end
        return "select " .. what
    elseif d.type == "normal" then
        local name = d.cmd or keytrans(d.keys)
        return NORMAL_WORDS[name] or ((name ~= "" and ("normal " .. name)) or "normal")
    elseif d.type == "mapping" then
        if d.lhs and d.lhs ~= "" then
            return "via " .. M.clip(keytrans(d.lhs))
        end
        if d.atoms then
            for i = #d.atoms, 1, -1 do
                if d.atoms[i].type == "operator" then
                    return M.describe(d.atoms[i])
                end
            end
            if #d.atoms > 0 then
                return M.describe(d.atoms[#d.atoms])
            end
        end
        return "via mapping"
    end
    return M.atom(d)
end

--- Aggregation key for report stats: the *verb* of an action, ignoring
--- counts and operands so `d2w` and `dw` count together.
---@param d EncoreEntry
---@return string
function M.stat_key(d)
    local t = d.type
    if t == "operator" then
        -- put atoms carry no operator name: key on cmd alone
        return (d.operator or "") .. (d.cmd or "?")
    elseif t == "motion" or t == "jump" then
        return d.cmd or keytrans(d.keys)
    elseif t == "excmd" then
        local word = (d.text or ""):match("^%S+")
        return word and (":" .. word) or ":"
    elseif t == "insert" then
        return "insert"
    elseif t == "visual" then
        return "v" .. (d.operator or "") .. (d.cmd or "")
    elseif t == "normal" then
        -- undo/redo/window commands are worth counting individually
        return d.cmd or keytrans(d.keys) or "normal"
    elseif t == "mapping" then
        if d.lhs and d.lhs ~= "" then
            return keytrans(d.lhs)
        end
        if d.atoms then
            for i = #d.atoms, 1, -1 do
                if d.atoms[i].type == "operator" then
                    return M.stat_key(d.atoms[i])
                end
            end
        end
        return "mapping"
    end
    return t or "?"
end

--- Does `entry` match any configured filter for `view`? Filters match a
--- Lua pattern against the atom name (render.atom).
---@param entry EncoreEntry
---@param filters EncoreFilter[]
---@param view string "hud" | "history"
---@return boolean
function M.filtered(entry, filters, view)
    local atom = M.atom(entry)
    for _, f in ipairs(filters or {}) do
        if f.pattern and atom:find(f.pattern) then
            local views = f.views
            if views == nil or vim.tbl_contains(type(views) == "table" and views or { views }, view) then
                return true
            end
        end
    end
    return false
end

--- "3 min ago" style label from an epoch (os.time seconds).
---@param epoch number|nil
---@return string
function M.time_ago(epoch)
    if type(epoch) ~= "number" then
        return ""
    end
    local diff = math.max(0, os.time() - math.floor(epoch))
    if diff < 60 then
        return "just now"
    elseif diff < 3600 then
        local m = math.floor(diff / 60)
        return string.format("%dm ago", m)
    elseif diff < 86400 then
        local h = math.floor(diff / 3600)
        return string.format("%dh ago", h)
    else
        local d = math.floor(diff / 86400)
        return string.format("%dd ago", d)
    end
end

--- "3 min 12 sec" style duration.
---@param seconds number
---@return string
function M.duration(seconds)
    seconds = math.max(0, math.floor(seconds))
    if seconds < 60 then
        return string.format("%ds", seconds)
    elseif seconds < 3600 then
        return string.format("%dm %02ds", math.floor(seconds / 60), seconds % 60)
    else
        return string.format("%dh %02dm", math.floor(seconds / 3600), math.floor((seconds % 3600) / 60))
    end
end

--- Blend `color` toward white (positive amount) or black (negative).
---@param color integer 0xRRGGBB
---@param amount number -1..1
---@return integer 0xRRGGBB
function M.shade(color, amount)
    local r = math.floor(color / 0x10000) % 0x100
    local g = math.floor(color / 0x100) % 0x100
    local b = color % 0x100
    local function f(c)
        return amount >= 0 and math.floor(c + (0xFF - c) * amount) or math.floor(c * (1 + amount))
    end
    return f(r) * 0x10000 + f(g) * 0x100 + f(b)
end

--- Mix `pct` percent of `bg` into `fg`.
---@param fg integer 0xRRGGBB
---@param bg integer 0xRRGGBB
---@param pct number 0-100
---@return integer 0xRRGGBB
function M.mix(fg, bg, pct)
    local function ch(shift)
        local a = math.floor(fg / shift) % 0x100
        local b = math.floor(bg / shift) % 0x100
        return math.floor(a + (b - a) * pct / 100)
    end
    return ch(0x10000) * 0x10000 + ch(0x100) * 0x100 + ch(1)
end

return M
