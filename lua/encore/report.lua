--- Session report: a multi-window panel composition.
---
---   ┌──────────────────────────────┐   backdrop: full-editor dim float
---   │  encore                      │   header: gradient logo + totals
---   │  your history, in actions    │
---   ├───────────────┬──────────────┤
---   │  ACTIONS      │ TOP ACTIONS  │   panels with border titles
---   │  ✂ operator 12│  dw ████░░ 23│
---   │  ...          │  ...         │
---   ├───────────────┼──────────────┤
---   │  INSERT       │ ACTIVITY BY H│   hour strip heatmap
---   │  ...          │  ··█···      │
---   └───────────────┴──────────────┘
---   │  ▎ you are a surgeon of text │   personality strip
---
--- Every panel is a rounded float with a border title, window-local
--- (namespace) theming, and no separator characters anywhere.
local api = vim.api
local config = require("encore.config")
local render = require("encore.render")
local ui = require("encore.ui")
local engine = require("encore.engine")

local M = {
    ns = api.nvim_create_namespace("encore_report"),
    wins = {}, -- { panel_key: win }
    bufs = {}, -- { panel_key: buf }
    visible = false,
    scope = "all", -- "all" | "session"
    panels = {}, -- active panel list, computed per open (adaptive)
    winenter_au = nil,
}

local BAR_WIDTH = 18

-- Adaptive layout: panel w/h is CONTENT (border adds 1 cell/side), so panels are spaced h+2 apart.

---@return { key: string, x: integer, y: integer, w: integer, h: integer, title?: string, footer?: string }[] panels
---@return integer grid_w content width
---@return integer grid_h total footprint height
local function layout()
    local cols, lines = vim.o.columns, vim.o.lines
    local grid_w = math.max(44, math.min(68, cols - 4))
    local action_w = math.floor(grid_w * 0.41)
    local top_w = grid_w - action_w - 2

    -- drop panels on small terminals so the grid always fits
    local show_activity = grid_w >= 59 and lines >= 38
    local show_personality = lines >= 28
    local show_mid = lines >= 21

    local panels = {}
    local y = 0
    panels[#panels + 1] = { key = "header", x = 0, y = y, w = grid_w, h = 3 }
    y = y + 3 + 2
    panels[#panels + 1] = { key = "actions", x = 0, y = y, w = action_w, h = 8, title = " ACTIONS " }
    panels[#panels + 1] = { key = "top", x = action_w + 2, y = y, w = top_w, h = 8, title = " TOP ACTIONS " }
    y = y + 8 + 2
    if show_mid then
        panels[#panels + 1] = { key = "insert", x = 0, y = y, w = action_w, h = 4, title = " INSERT " }
        panels[#panels + 1] = { key = "pace", x = action_w + 2, y = y, w = top_w, h = 4, title = " PACE " }
        y = y + 4 + 2
    end
    if show_activity then
        panels[#panels + 1] = { key = "activity", x = 0, y = y, w = grid_w, h = 8, title = " ACTIVITY " }
        y = y + 8 + 2
    end
    if show_personality then
        panels[#panels + 1] = {
            key = "personality",
            x = 0,
            y = y,
            w = grid_w,
            h = 1,
            footer = " ? help  q quit ",
        }
        y = y + 1 + 2
    end
    return panels, grid_w, y
end

-- Theme: window-local, adapts to the current colorscheme

local function apply_theme()
    local normal = ui.get_hl("NormalFloat")
    local base = normal.bg or ui.get_hl("Normal").bg
    local accent = ui.get_hl("Keyword").fg or 0xffffff
    local accent2 = ui.get_hl("Function").fg or accent

    local card_bg = base and render.shade(base, 0.02) or nil
    local groups = {
        FloatTitle = { fg = accent, bold = true },
    }
    if card_bg then
        groups.NormalFloat = { bg = card_bg }
        groups.FloatBorder = { fg = render.shade(base, 0.18) }
    end
    -- intensity scales for both accents, mixed toward the card bg
    local target = card_bg or (base or 0)
    for i, pct in ipairs({ 10, 40, 60, 80 }) do
        groups["EncoreHeat" .. (i - 1)] = { fg = render.mix(accent, target, pct) }
        groups["EncoreHeat2" .. (i - 1)] = { fg = render.mix(accent2, target, pct) }
    end
    for name, opts in pairs(groups) do
        api.nvim_set_hl(M.ns, name, opts)
    end
    return { accent = accent, accent2 = accent2 }
end

-- Stats

---@return table stats
local function collect()
    local all = engine.get()
    local entries = all
    if M.scope == "session" then
        entries = {}
        local since = engine.session_start()
        for _, e in ipairs(all) do
            if (e.epoch or 0) >= since then
                entries[#entries + 1] = e
            end
        end
    end
    local stats = {
        total = #entries,
        by_type = {},
        by_key = {},
        key_type = {},
        by_hour = {},
        by_dh = { {}, {}, {}, {}, {}, {}, {} }, -- [wday][hour] counts
        pace = {}, -- [1..34]: actions per 2-minute bucket, oldest first
        insert = { n = 0, chars = 0, longest = 0 },
        first_epoch = nil,
        last_epoch = nil,
    }
    -- hour/wday are constant within an hour: cache os.date per bucket
    local date_cache = {}
    local function hour_wday(epoch)
        local bucket = math.floor(epoch / 3600)
        local f = date_cache[bucket]
        if not f then
            local t = os.date("*t", math.floor(epoch))
            f = { hour = t.hour, wday = t.wday }
            date_cache[bucket] = f
        end
        return f
    end
    for _, e in ipairs(entries) do
        stats.by_type[e.type] = (stats.by_type[e.type] or 0) + 1
        local key = render.stat_key(e)
        stats.by_key[key] = (stats.by_key[key] or 0) + 1
        stats.key_type[key] = stats.key_type[key] or e.type
        if e.type == "insert" and e.text then
            local len = vim.fn.strchars(e.text)
            stats.insert.n = stats.insert.n + 1
            stats.insert.chars = stats.insert.chars + len
            stats.insert.longest = math.max(stats.insert.longest, len)
        end
        if e.epoch then
            local f = hour_wday(e.epoch)
            stats.by_hour[f.hour] = (stats.by_hour[f.hour] or 0) + 1
            stats.by_dh[f.wday][f.hour] = (stats.by_dh[f.wday][f.hour] or 0) + 1
            local bucket = math.floor((os.time() - e.epoch) / 120)
            if bucket >= 0 and bucket < 34 then
                stats.pace[34 - bucket] = (stats.pace[34 - bucket] or 0) + 1
            end
        end
        stats.first_epoch = stats.first_epoch or e.epoch
        stats.last_epoch = e.epoch
    end
    return stats
end

---@param stats table
---@param n integer
---@return { key: string, count: integer, type: string }[]
local function top(stats, n)
    local items = {}
    for key, count in pairs(stats.by_key) do
        items[#items + 1] = { key = key, count = count, type = stats.key_type[key] or "?" }
    end
    table.sort(items, function(a, b)
        if a.count ~= b.count then
            return a.count > b.count
        end
        return a.key < b.key -- deterministic tie-break
    end)
    local out = {}
    for i = 1, math.min(n, #items) do
        out[i] = items[i]
    end
    return out
end

-- Panel renderers (chunk lines for the panel's inner area)

--- Plain centered header: name, subtitle, totals + rate.
local function header_panel(stats, inner_w)
    local function center(text, hl)
        local w = vim.fn.strwidth(text)
        local pad = math.max(0, math.floor((inner_w - w) / 2))
        return { { text = string.rep(" ", pad), hl = nil }, { text = text, hl = hl } }
    end
    local duration =
        render.duration(stats.first_epoch and stats.last_epoch and math.max(0, stats.last_epoch - stats.first_epoch) or 0)
    local minutes = math.max(1, ((stats.last_epoch or 0) - (stats.first_epoch or 0)) / 60)
    local rate = string.format("%.1f/min", stats.total / minutes)
    local stats_text = tostring(stats.total) .. " actions in " .. duration .. " (" .. rate .. ")"
    local pad = math.max(0, math.floor((inner_w - vim.fn.strwidth(stats_text)) / 2))
    local subtitle = M.scope == "session" and "this session, in actions" or "your history, in actions"
    return {
        center("encore", "EncoreTitle"),
        center(subtitle, "EncoreDim"),
        {
            { text = string.rep(" ", pad), hl = nil },
            { text = tostring(stats.total), hl = "EncoreCount" },
            { text = " actions in ", hl = "EncoreDim" },
            { text = duration, hl = "EncoreHeat20" },
            { text = " (", hl = "EncoreDim" },
            { text = rate, hl = "EncoreCount" },
            { text = ")", hl = "EncoreDim" },
        },
    }
end

local function actions_panel(stats)
    local lines = {}
    for _, t in ipairs({ "operator", "motion", "jump", "insert", "excmd", "visual", "mapping" }) do
        local n = stats.by_type[t] or 0
        if n > 0 then
            lines[#lines + 1] = {
                { text = render.icon({ type = t }) .. " ", hl = "EncoreTypeIcon" },
                { text = render.pad(t, 9), hl = "EncoreDim" },
                { text = string.rep(" ", 4) },
                { text = tostring(n), hl = "EncoreCount" },
            }
        end
    end
    return lines
end

local function top_panel(stats, inner_w)
    local items = top(stats, 8)
    local lines = {}
    if #items == 0 then
        lines[#lines + 1] = { { text = "nothing yet — go edit something", hl = "EncoreDim" } }
        return lines
    end
    local bar_w = math.max(6, math.min(BAR_WIDTH, inner_w - 16))
    local max = items[1].count
    for _, item in ipairs(items) do
        local fill = math.max(1, math.floor(item.count / max * bar_w))
        -- intensity follows the value ratio, not the rank
        local ratio = item.count / max
        local fill_hl = ratio > 0.85 and "EncoreHeat0"
            or (ratio > 0.6 and "EncoreHeat1")
            or (ratio > 0.3 and "EncoreHeat2")
            or "EncoreHeat3"
        lines[#lines + 1] = {
            { text = render.pad(item.key, 10), hl = "EncoreName" },
            { text = " " },
            { text = string.rep("█", fill), hl = fill_hl },
            { text = string.rep("░", bar_w - fill), hl = "EncoreBarTrack" },
            { text = "  " .. tostring(item.count), hl = "EncoreCount" },
        }
    end
    return lines
end

local function insert_panel(stats)
    if stats.insert.n == 0 then
        return { { { text = "no insert sessions", hl = "EncoreDim" } } }
    end
    return {
        {
            { text = "sessions   ", hl = "EncoreDim" },
            { text = tostring(stats.insert.n), hl = "EncoreCount" },
        },
        {
            { text = "total      ", hl = "EncoreDim" },
            { text = string.format("%d chars", stats.insert.chars), hl = "EncoreCount" },
        },
        {
            { text = "avg        ", hl = "EncoreDim" },
            { text = string.format("%.1f chars", stats.insert.chars / stats.insert.n) },
        },
        {
            { text = "longest    ", hl = "EncoreDim" },
            { text = tostring(stats.insert.longest) .. " chars", hl = "EncoreHeat20" },
        },
    }
end

--- 90th percentile of positive values: a robust "full" level so one
--- busy hour/minute doesn't wash out the rest of the scale.
---@param values integer[]
---@return integer
local function p90(values)
    local sorted = {}
    for _, v in ipairs(values) do
        if v > 0 then
            sorted[#sorted + 1] = v
        end
    end
    if #sorted == 0 then
        return 0
    end
    table.sort(sorted)
    return sorted[math.max(1, math.ceil(#sorted * 0.9))]
end

--- Sparkline of the last ~68 minutes + the 24-hour strip. Width-adaptive.
local function pace_panel(stats, inner_w)
    local SPARK = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
    local cells = math.min(34, math.max(8, inner_w - 14))
    -- stats.pace is sparse (only hit buckets exist); make a dense copy
    local pvals = {}
    for i = 1, 34 do
        pvals[#pvals + 1] = stats.pace[i] or 0
    end
    local spark_full = p90(pvals)
    local spark = { { text = " ", hl = nil } }
    -- render the MOST RECENT `cells` buckets (pace[34] is now)
    for i = 34 - cells + 1, 34 do
        local n = stats.pace[i] or 0
        if n == 0 or spark_full == 0 then
            spark[#spark + 1] = { text = " ", hl = nil }
        else
            local lvl = math.max(1, math.min(8, math.ceil(n / spark_full * 8)))
            spark[#spark + 1] = { text = SPARK[lvl], hl = "EncoreHeat20" }
        end
    end
    spark[#spark + 1] = { text = " last hour", hl = "EncoreDim" }

    local strip = { { text = " ", hl = nil } }
    local hvals = {}
    for h = 0, 23 do
        hvals[#hvals + 1] = stats.by_hour[h] or 0
    end
    local hfull = p90(hvals)
    local STRIP_GLYPHS = { "▒", "▓", "█" }
    for h = 0, 23 do
        local n = stats.by_hour[h] or 0
        if n == 0 then
            strip[#strip + 1] = { text = "░", hl = "EncoreBarTrack" }
        else
            local level = math.max(0, math.min(2, math.floor(n / hfull * 3)))
            strip[#strip + 1] = { text = STRIP_GLYPHS[level + 1], hl = "EncoreHeat" .. (2 - level) }
        end
    end
    -- hour labels at 0,6,12,18,23 (23:00 = the last hour of the day)
    local labels = { { text = " ", hl = nil } }
    local prev = 0
    for _, m in ipairs({ { 0, "0h" }, { 6, "6h" }, { 12, "12h" }, { 18, "18h" }, { 23, "23h" } }) do
        labels[#labels + 1] = { text = string.rep(" ", m[1] - prev) .. m[2], hl = "EncoreDim" }
        prev = m[1] + #m[2]
    end
    return { spark, { { text = " ", hl = nil } }, strip, labels }
end

--- 7-day × 24-hour activity heatmap, GitHub-style: a DENSE grid of
--- 2-char cells (glyph + space) with no column gaps, weekday rows on the
--- left, hour labels on top, day totals on the right, Less/More legend.
--- Empty cells are the dimmest shade, never a literal gap.
local function activity_panel(stats, inner_w)
    local ACTIVE = { "▒", "▓", "█" }
    local days = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }
    local order = { 2, 3, 4, 5, 6, 7, 1 } -- Mon..Sun
    local dtotal = {}
    local cellvals = {}
    for w = 1, 7 do
        dtotal[w] = 0
        for h = 0, 23 do
            local n = stats.by_dh[w][h] or 0
            dtotal[w] = dtotal[w] + n
            cellvals[#cellvals + 1] = n
        end
    end
    local full = p90(cellvals)
    local marks = { 0, 6, 12, 18, 23 }

    -- hour header: 2-char labels aligned to the 2-char cells
    local head = { { text = "     ", hl = nil } }
    for h = 0, 23 do
        local is_mark = false
        for _, m in ipairs(marks) do
            if m == h then
                is_mark = true
                break
            end
        end
        head[#head + 1] = { text = is_mark and string.format("%-2d", h) or "  ", hl = "EncoreDim" }
    end
    local lines = { head }

    for _, wday in ipairs(order) do
        local line = { { text = " " .. days[((wday - 2) % 7) + 1] .. " ", hl = "EncoreDim" } }
        for h = 0, 23 do
            local n = stats.by_dh[wday][h] or 0
            if n == 0 then
                line[#line + 1] = { text = "░ ", hl = "EncoreBarTrack" }
            else
                local level = math.max(0, math.min(2, math.floor(n / full * 3)))
                line[#line + 1] = { text = ACTIVE[level + 1] .. " ", hl = "EncoreHeat2" .. (2 - level) }
            end
        end
        line[#line + 1] = { text = string.format(" %4d", dtotal[wday]), hl = "EncoreDim" }
        lines[#lines + 1] = line
    end

    lines[#lines + 1] = { { text = "     Less ░ ▒ ▓ █ More", hl = "EncoreDim" } }

    -- center the whole block within the panel
    local maxw = 0
    for _, line in ipairs(lines) do
        local w = 0
        for _, c in ipairs(line) do
            w = w + vim.fn.strwidth(c.text)
        end
        maxw = math.max(maxw, w)
    end
    local pad = math.max(0, math.floor((inner_w - maxw) / 2))
    for _, line in ipairs(lines) do
        table.insert(line, 1, { text = string.rep(" ", pad), hl = nil })
    end
    return lines
end

local function personality_line(item)
    local key, t = item.key, item.type
    if t == "operator" then
        local lines = {
            d = "a surgeon of text — cuts with intent.",
            y = "a collector — hoards words into registers.",
            c = "a perpetual rewriter — nothing stays as written.",
        }
        return lines[key:sub(1, 1)] or "an operator — actions speak louder than keys."
    end
    if key == "j" or key == "k" or key == "gj" or key == "gk" then
        return "a drifter — moves line by line."
    end
    if key == "w" or key == "b" or key == "e" or key == "ge" then
        return "a word-hopper — never crosses a word it can jump."
    end
    if key == "f" or key == "t" then
        return "a marksman — locks onto characters."
    end
    if key == "insert" then
        return "a writer — spends most time in insert mode."
    end
    return "an all-rounder — no single habit dominates."
end

local function personality_panel(stats, inner_w)
    local item = top(stats, 1)[1]
    if not item then
        return { { { text = "  go edit something", hl = "EncoreDim" } } }
    end
    local rest = " you are " .. personality_line(item)
    local pad = math.max(0, math.floor((inner_w - vim.fn.strwidth(rest) - 1) / 2))
    return {
        {
            { text = string.rep(" ", pad), hl = nil },
            { text = "▎", hl = "EncoreHeat0" },
            { text = rest, hl = "EncoreDim" },
        },
    }
end

-- Window assembly

local function panel_lines(key, stats, inner_w)
    if key == "header" then
        return header_panel(stats, inner_w)
    elseif key == "actions" then
        return actions_panel(stats)
    elseif key == "top" then
        return top_panel(stats, inner_w)
    elseif key == "insert" then
        return insert_panel(stats)
    elseif key == "pace" then
        return pace_panel(stats, inner_w)
    elseif key == "activity" then
        return activity_panel(stats, inner_w)
    elseif key == "personality" then
        return personality_panel(stats, inner_w)
    end
    return {}
end

local function open_panel(panel, origin_col, origin_row)
    if not M.bufs[panel.key] then
        M.bufs[panel.key] = ui.new_buf("encore")
    end
    local buf = M.bufs[panel.key]

    local win_config = {
        relative = "editor",
        anchor = "NW",
        row = origin_row + panel.y,
        col = origin_col + panel.x,
        width = panel.w,
        height = panel.h,
        border = config.opts.ui.border,
        zindex = config.opts.report.zindex,
        focusable = true,
    }
    if panel.title then
        win_config.title = panel.title
        win_config.title_pos = "center"
    end
    if panel.footer then
        win_config.footer = panel.footer
        win_config.footer_pos = "center"
    end

    local win = ui.new_win(buf, win_config, { enter = false })
    api.nvim_set_option_value("scrolloff", 0, { win = win })
    api.nvim_win_set_hl_ns(win, M.ns)

    local inner_w = panel.w - 4
    ui.set_chunks(buf, panel_lines(panel.key, M.stats, inner_w))
    M.wins[panel.key] = win

    if panel.key == "actions" then
        api.nvim_set_current_win(win)
    end
    return win
end

--- Plain-text report with descriptive prose. Built from stats directly
--- so the output reads well outside Neovim.
---@return string
local function export_text()
    local s = M.stats
    local L = {}
    L[#L + 1] = "encore — " .. os.date("%Y-%m-%d %H:%M") .. " · " .. M.scope

    local dur = render.duration(s.first_epoch and s.last_epoch and math.max(0, s.last_epoch - s.first_epoch) or 0)
    local rate = string.format("%.1f", s.total / math.max(1, ((s.last_epoch or 0) - (s.first_epoch or 0)) / 60))
    L[#L + 1] = string.format("%d actions in %s, ~%s per minute", s.total, dur, rate)

    L[#L + 1] = ""
    L[#L + 1] = "Actions by type"
    for _, t in ipairs({ "operator", "motion", "jump", "insert", "excmd", "visual", "mapping" }) do
        local n = s.by_type[t] or 0
        if n > 0 then
            L[#L + 1] = string.format("  %-10s %d", t, n)
        end
    end

    local items = top(s, 8)
    L[#L + 1] = ""
    L[#L + 1] = "Top actions"
    if #items == 0 then
        L[#L + 1] = "  nothing yet"
    else
        local max = items[1].count
        for _, item in ipairs(items) do
            local fill = math.floor(item.count / max * 20)
            L[#L + 1] = string.format(
                "  %-12s %3d  %s",
                item.key,
                item.count,
                string.rep("█", fill) .. string.rep("░", 20 - fill)
            )
        end
    end

    L[#L + 1] = ""
    L[#L + 1] = "Insert"
    if s.insert.n == 0 then
        L[#L + 1] = "  no insert sessions"
    else
        L[#L + 1] = string.format("  %d sessions, %d chars total", s.insert.n, s.insert.chars)
        L[#L + 1] = string.format("  avg %.1f chars, longest %d", s.insert.chars / s.insert.n, s.insert.longest)
    end

    -- hour strip, plain text
    L[#L + 1] = ""
    L[#L + 1] = "Activity by hour"
    local strip = { "  " }
    local hmax = 0
    for h = 0, 23 do
        hmax = math.max(hmax, s.by_hour[h] or 0)
    end
    for h = 0, 23 do
        local n = s.by_hour[h] or 0
        if n == 0 then
            strip[#strip + 1] = "·"
        elseif n >= hmax then
            strip[#strip + 1] = "█"
        elseif n / hmax > 0.5 then
            strip[#strip + 1] = "▓"
        else
            strip[#strip + 1] = "░"
        end
    end
    L[#L + 1] = table.concat(strip)
    L[#L + 1] = "  0h       6h       12h      18h     23h"

    local top_item = items[1]
    if top_item then
        L[#L + 1] = ""
        L[#L + 1] = "you are " .. personality_line(top_item)
    end
    return table.concat(L, "\n")
end

--- Copy a plain-text report to the clipboard (unnamed register fallback).
function M.export()
    local text = export_text()
    vim.fn.setreg('"', text)
    if vim.fn.has("clipboard") == 1 then
        vim.fn.setreg("+", text)
        vim.notify("encore: report copied to clipboard", vim.log.levels.INFO)
    else
        vim.notify("encore: report yanked (no clipboard provider, use the unnamed register)", vim.log.levels.INFO)
    end
end

--- Toggle the scope between all-time and this-session stats.
function M.toggle_scope()
    M.scope = M.scope == "all" and "session" or "all"
    if not M.visible then
        return
    end
    M.stats = collect()
    for _, panel in ipairs(M.panels) do
        local buf = M.bufs[panel.key]
        if buf and api.nvim_buf_is_valid(buf) then
            ui.set_chunks(buf, panel_lines(panel.key, M.stats, panel.w - 4))
        end
    end
end

--- Move focus to the next/prev panel (dir = 1 | -1), wrapping.
---@param dir 1|-1
local function cycle_focus(dir)
    if not M.visible then
        return
    end
    local cur = api.nvim_get_current_win()
    local idx = nil
    for i, panel in ipairs(M.panels) do
        if M.wins[panel.key] == cur then
            idx = i
            break
        end
    end
    if not idx then
        return
    end
    local next_i = ((idx - 1 + dir) % #M.panels) + 1
    api.nvim_set_current_win(M.wins[M.panels[next_i].key])
end

--- Close all panels and resume the HUD.
function M.close()
    if not M.visible then
        return
    end
    if M.winenter_au then
        api.nvim_del_autocmd(M.winenter_au)
        M.winenter_au = nil
    end
    for _, win in pairs(M.wins) do
        ui.close_win(win)
    end
    M.wins = {}
    M.visible = false
    require("encore.hud").resume()
end

--- Open the report: suspend the HUD, compose the adaptive panel grid.
function M.open()
    if M.visible then
        return
    end
    local hud = require("encore.hud")
    hud.suspend()

    M.stats = collect()
    apply_theme()

    local panels, grid_w, grid_h = layout()
    M.panels = panels

    local origin_col = math.max(0, math.floor((vim.o.columns - (grid_w + 2)) / 2))
    local origin_row = math.max(1, math.floor((vim.o.lines - grid_h) / 2))

    for _, panel in ipairs(panels) do
        open_panel(panel, origin_col, origin_row)
    end

    -- quit/toggle/export/focus keys in every panel
    for key, _ in pairs(M.wins) do
        local opts = { buffer = M.bufs[key], nowait = true, silent = true }
        local rkm = config.opts.keymaps.report
        local function bind(lhs, rhs)
            if type(lhs) == "string" then
                lhs = { lhs }
            end
            for _, l in ipairs(lhs) do
                vim.keymap.set("n", l, rhs, opts)
            end
        end
        bind(rkm.quit, function()
            M.close()
        end)
        bind(rkm.toggle_scope, function()
            M.toggle_scope()
        end)
        bind(rkm.export, function()
            M.export()
        end)
        bind(rkm.focus_next, function()
            cycle_focus(1)
        end)
        bind(rkm.focus_prev, function()
            cycle_focus(-1)
        end)
        bind(rkm.help, function()
            require("encore.help").open({
                quit = { lhs = rkm.quit, desc = "Close the report" },
                toggle_scope = { lhs = rkm.toggle_scope, desc = "Toggle session/all-time stats" },
                export = { lhs = rkm.export, desc = "Copy a plain-text report" },
                focus_next = { lhs = rkm.focus_next, desc = "Focus the next panel" },
                focus_prev = { lhs = rkm.focus_prev, desc = "Focus the previous panel" },
                help = { lhs = rkm.help, desc = "Show this page" },
            })
        end)
    end

    -- close on focus-leave (helper page exempt); persistent so it survives the helper stealing focus
    M.winenter_au = vim.api.nvim_create_autocmd("WinEnter", {
        callback = function()
            local cur = api.nvim_get_current_win()
            if not vim.tbl_contains(vim.tbl_values(M.wins), cur) and not require("encore.help").is_help(cur) then
                M.close()
            end
        end,
    })
    vim.api.nvim_create_autocmd("VimResized", {
        once = true,
        callback = function()
            M.close()
        end,
    })

    M.visible = true
end

return M
