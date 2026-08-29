--- Pure render checks: plain busted specs, run headless.
local eq = assert.are.same
local render = require("encore.render")

describe("render", function()
    describe("atom", function()
        it("names operators, commands, inserts and motions", function()
            eq(render.atom({ type = "operator", operator = "d", count = 2, cmd = "w" }), "d2w")
            eq(render.atom({ type = "operator", operator = "d", count = 1, cmd = "d" }), "dd")
            eq(render.atom({ type = "excmd", text = "cnext" }), ":cnext")
            eq(render.atom({ type = "insert", text = "ab" }), "iab")
            eq(render.atom({ type = "motion", count = 3, cmd = "j" }), "3j")
            eq(render.atom({ type = "visual", operator = "d", cmd = "iw" }), "vdiw")
        end)

        it("clips long insert text", function()
            assert(render.atom({ type = "insert", text = string.rep("x", 20) }):match("…$") ~= nil)
            assert(render.atom({ type = "insert", text = string.rep("中", 20) }):match("…$") ~= nil)
        end)

        it("prefers the mapping lhs over sub-atoms", function()
            eq(render.atom({ type = "mapping", lhs = "abc" }), "abc")
            eq(
                render.atom({
                    type = "mapping",
                    lhs = "dw",
                    atoms = { { type = "operator", operator = "d", count = 1, cmd = "w" } },
                }),
                "dw"
            )
            eq(render.atom({ type = "mapping", lhs = "\r" }), "<CR>")
        end)
    end)

    describe("describe", function()
        it("reads operators as verb + object", function()
            eq(render.describe({ type = "operator", operator = "d", count = 2, cmd = "w" }), "delete 2 words")
            eq(render.describe({ type = "operator", operator = "d", count = 1, cmd = "d" }), "delete line")
            eq(render.describe({ type = "operator", operator = "c", count = 3, cmd = "c" }), "change 3 lines")
            eq(render.describe({ type = "operator", operator = "c", count = 1, cmd = 'i"' }), "change inside quotes")
            eq(render.describe({ type = "operator", operator = "d", count = 1, cmd = "ap" }), "delete a paragraph")
        end)

        it("describes put commands (operator-typed, no operator name)", function()
            eq(render.describe({ type = "operator", cmd = "p" }), "paste after")
            eq(render.describe({ type = "operator", cmd = "P" }), "paste before")
            eq(render.describe({ type = "operator", cmd = "gp" }), "paste after, keep cursor")
            eq(render.describe({ type = "operator", cmd = "gP" }), "paste before, keep cursor")
            eq(render.describe({ type = "operator", cmd = "p", count = 2 }), "paste after ×2")
        end)

        it("describes motions, jumps and visual selections", function()
            eq(render.describe({ type = "motion", count = 3, cmd = "j" }), "down ×3")
            eq(render.describe({ type = "motion", count = 1, cmd = "f", cmdarg = "x" }), "to char x")
            eq(render.describe({ type = "jump", count = 1, cmd = "gg" }), "to top")
            eq(render.describe({ type = "visual", cmd = "iw" }), "select inner word")
            eq(render.describe({ type = "visual", operator = "gU", cmd = "iw" }), "uppercase inner word")
        end)

        it("describes normal commands, insert sessions and mappings", function()
            eq(render.describe({ type = "normal", cmd = "<C-W>w" }), "switch window")
            eq(render.describe({ type = "normal", cmd = "<C-R>" }), "redo")
            eq(render.describe({ type = "insert", text = "abcd" }), "type 4 chars")
            eq(render.describe({ type = "insert", text = "中文测试文字" }), "type 6 chars")
            eq(render.describe({ type = "mapping", lhs = "dw" }), "via dw")
        end)

        it("falls back to keys and never leaves a trailing space", function()
            eq(render.describe({ type = "normal", keys = "\18" }), "redo")
            eq(render.describe({ type = "normal" }), "normal")
        end)
    end)

    describe("stat_key", function()
        it("aggregates operators, mappings and put commands", function()
            eq(render.stat_key({ type = "operator", operator = "d", count = 2, cmd = "w" }), "dw")
            eq(render.stat_key({ type = "operator", operator = "d", count = 1, cmd = "d" }), "dd")
            eq(render.stat_key({ type = "operator", cmd = "p" }), "p")
            eq(render.stat_key({ type = "mapping", lhs = "dw" }), "dw")
        end)

        it("counts normal commands individually", function()
            eq(render.stat_key({ type = "normal", cmd = "u" }), "u")
            eq(render.stat_key({ type = "normal", cmd = "<C-R>" }), "<C-R>")
            eq(render.stat_key({ type = "normal", keys = "\18" }), "<C-R>")
        end)

        it("keys ex commands by their first word", function()
            eq(render.stat_key({ type = "excmd", text = "cnext file" }), ":cnext")
        end)
    end)

    describe("icon", function()
        it("maps every type and falls back for unknowns", function()
            eq(render.icon({ type = "operator" }), "✂")
            eq(render.icon({ type = "mapping" }), "@")
            eq(render.icon({ type = "unknown" }), "◆")
        end)
    end)

    describe("clip and pad", function()
        it("pads short strings to the exact cell width", function()
            eq(render.pad("abc", 6), "abc   ")
        end)

        it("clips mixed CJK by display cells, never splitting characters", function()
            eq(render.pad("中x中中中中", 6), "中x中…")
            eq(vim.fn.strdisplaywidth(render.pad("中中中中中中中中", 6)), 6)
            local out = render.clip(string.rep("中", 20), 10)
            assert(out:match("…$") ~= nil, "clipped without ellipsis")
            assert(vim.fn.strdisplaywidth(out) <= 10, "exceeds max width")
        end)
    end)

    describe("filtered", function()
        it("matches patterns against the atom name per view", function()
            local j = { type = "motion", cmd = "j" }
            local scroll = { type = "scroll", keys = "\128\253" }
            eq(render.filtered(scroll, { { pattern = "^scroll$" } }, "hud"), true)
            eq(render.filtered(scroll, { { pattern = "^scroll$", views = { "hud" } } }, "history"), false)
            eq(render.filtered(j, { { pattern = "^scroll$" } }, "hud"), false)
            eq(render.filtered(j, { { pattern = "j" } }, "hud"), true)
            eq(render.filtered(j, {}, "hud"), false)
            eq(render.filtered(j, nil, "hud"), false)
        end)
    end)

    describe("time formatting", function()
        it("formats durations", function()
            eq(render.duration(45), "45s")
            eq(render.duration(75), "1m 15s")
            eq(render.duration(3700), "1h 01m")
        end)

        it("formats relative times", function()
            eq(render.time_ago(os.time() - 30), "just now")
            eq(render.time_ago(os.time() - 300), "5m ago")
        end)
    end)
end)
