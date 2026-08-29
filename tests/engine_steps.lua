--- Engine test steps, driven by tests/run_engine.py — an embedded nvim
--- with a UI attached, because CmdAtom does not fire headless.
---
--- The step protocol exists because RPC nvim_input is only processed
--- when no Lua chunk (exec_lua / vim.schedule / vim.wait / coroutine) is
--- on the stack: all waiting happens driver-side, and every exec_lua
--- call here is a short request that returns immediately.
---
--- Each step: optional pre(), inputs fed via RPC nvim_input (real typed
--- input — the only path that emits CmdAtom), a wait() polled until
--- true, and a check() returning failure messages.
---
--- Not a *_spec.lua file: the headless `make test` busted run cannot
--- exercise CmdAtom and must not pick this up.
local engine = require("encore.engine")
local render = require("encore.render")

_G.encore_steps = {}
_G.encore_skip = nil

if not (engine.available() and vim.api.nvim_list_uis()[1] ~= nil) then
    _G.encore_skip = "CmdAtom not available without a UI (needs an embedded nvim with nvim_ui_attach)"
else
    local steps = {}

    local function key(s)
        return vim.api.nvim_replace_termcodes(s, true, false, true)
    end

    local function step(t)
        steps[#steps + 1] = t
    end

    step({
        name = "collect motion 3j",
        pre = function()
            engine.start({ persist = { enabled = false } })
            engine.clear()
            vim.fn.setline(1, "a")
            vim.fn.setline(2, "b")
            vim.fn.setline(3, "c")
            vim.api.nvim_win_set_cursor(0, { 1, 0 })
        end,
        inputs = { key("3j") },
        wait = function()
            return #engine.get() >= 1
        end,
        check = function()
            local msgs = {}
            local e = engine.get()[1]
            if e.type ~= "motion" then
                msgs[#msgs + 1] = "type: " .. tostring(e.type)
            end
            if e.count ~= 3 then
                msgs[#msgs + 1] = "count: " .. tostring(e.count)
            end
            if e.cmd ~= "j" then
                msgs[#msgs + 1] = "cmd: " .. tostring(e.cmd)
            end
            if not (e.replay and #e.replay > 0) then
                msgs[#msgs + 1] = "replay missing"
            end
            if type(e.epoch) ~= "number" then
                msgs[#msgs + 1] = "epoch missing"
            end
            if render.describe(e) ~= "down ×3" then
                msgs[#msgs + 1] = "describe: " .. render.describe(e)
            end
            return msgs
        end,
    })

    step({
        name = "collect operator dd",
        pre = function()
            engine.clear()
            vim.fn.setline(1, "hello world")
        end,
        inputs = { key("dd") },
        wait = function()
            return #engine.get() >= 1
        end,
        check = function()
            local msgs = {}
            local e = engine.get()[1]
            if e.type ~= "operator" then
                msgs[#msgs + 1] = "type: " .. tostring(e.type)
            end
            if e.operator ~= "d" then
                msgs[#msgs + 1] = "operator: " .. tostring(e.operator)
            end
            if e.changed ~= true then
                msgs[#msgs + 1] = "changed should be true"
            end
            if render.describe(e) ~= "delete line" then
                msgs[#msgs + 1] = "describe: " .. render.describe(e)
            end
            return msgs
        end,
    })

    step({
        name = "collect insert session",
        pre = function()
            engine.clear()
            vim.fn.setline(1, "")
        end,
        inputs = { key("iab<Esc>") },
        wait = function()
            return #engine.get() >= 1
        end,
        check = function()
            local msgs = {}
            local e = engine.get()[1]
            if e.type ~= "insert" then
                msgs[#msgs + 1] = "type: " .. tostring(e.type)
            end
            if e.text ~= "ab" then
                msgs[#msgs + 1] = "text: " .. tostring(e.text)
            end
            if render.describe(e) ~= "type 2 chars" then
                msgs[#msgs + 1] = "describe: " .. render.describe(e)
            end
            return msgs
        end,
    })

    step({
        name = "collect excmd",
        pre = function()
            engine.clear()
        end,
        inputs = { key(":echo 1\r") },
        wait = function()
            return #engine.get() >= 1
        end,
        check = function()
            local msgs = {}
            local e = engine.get()[1]
            if e.type ~= "excmd" then
                msgs[#msgs + 1] = "type: " .. tostring(e.type)
            end
            if e.text ~= "echo 1" then
                msgs[#msgs + 1] = "text: " .. tostring(e.text)
            end
            if render.describe(e) ~= "run echo 1" then
                msgs[#msgs + 1] = "describe: " .. render.describe(e)
            end
            return msgs
        end,
    })

    step({
        name = "on_entry / off_entry",
        pre = function()
            engine.clear()
            _G.encore_captured = {}
            _G.encore_cb = engine.on_entry(function(entry)
                _G.encore_captured[#_G.encore_captured + 1] = entry
            end)
        end,
        inputs = { key("j") },
        wait = function()
            return #engine.get() >= 1
        end,
        check = function()
            local msgs = {}
            if #_G.encore_captured ~= 1 then
                msgs[#msgs + 1] = "listener fired " .. #_G.encore_captured .. " times"
            end
            if #_G.encore_captured >= 1 and _G.encore_captured[1] ~= engine.get()[#engine.get()] then
                msgs[#msgs + 1] = "listener did not receive the entry"
            end
            engine.off_entry(_G.encore_cb)
            return msgs
        end,
    })

    step({
        name = "off_entry stops delivery",
        pre = function()
            engine.clear()
            _G.encore_captured = {}
        end,
        inputs = { key("j") },
        wait = function()
            return #engine.get() >= 1
        end,
        check = function()
            local msgs = {}
            if #_G.encore_captured ~= 0 then
                msgs[#msgs + 1] = "listener fired after off_entry: " .. #_G.encore_captured
            end
            return msgs
        end,
    })

    step({
        name = "recent() newest-first",
        pre = function()
            engine.clear()
        end,
        inputs = { key("j"), key("k") },
        wait = function()
            return #engine.get() >= 2
        end,
        check = function()
            local msgs = {}
            local r = engine.recent(2)
            if #r ~= 2 then
                msgs[#msgs + 1] = "recent(2) size " .. #r
            elseif not (r[1].ts > r[2].ts) then
                msgs[#msgs + 1] = "not newest-first"
            elseif r[1].cmd ~= "k" or r[2].cmd ~= "j" then
                msgs[#msgs + 1] = "wrong order"
            end
            return msgs
        end,
    })

    step({
        name = "ring capacity",
        pre = function()
            engine.start({ capacity = 3 })
            engine.clear()
        end,
        inputs = { key("j"), key("k"), key("l"), key("h") },
        wait = function()
            local got = engine.get()
            return #got == 3 and got[3].cmd == "h"
        end,
        check = function()
            local msgs = {}
            local got = engine.get()
            if #got ~= 3 then
                msgs[#msgs + 1] = "ring size " .. #got
            end
            if got[1].cmd ~= "k" then
                msgs[#msgs + 1] = "oldest dropped, got " .. tostring(got[1].cmd)
            end
            if got[3].cmd ~= "h" then
                msgs[#msgs + 1] = "newest wrong, got " .. tostring(got[3].cmd)
            end
            -- recent() reads the wrapped ring directly
            local r = engine.recent(3)
            if r[1].cmd ~= "h" or r[2].cmd ~= "l" or r[3].cmd ~= "k" then
                msgs[#msgs + 1] = "recent() wrong after wrap"
            end
            return msgs
        end,
    })

    step({
        name = "stop() stops collection",
        pre = function()
            engine.stop()
            engine.clear()
        end,
        inputs = { key("j") },
        sleep = 0.3,
        check = function()
            local msgs = {}
            if #engine.get() ~= 0 then
                msgs[#msgs + 1] = "collected after stop(): " .. #engine.get()
            end
            return msgs
        end,
    })

    step({
        name = "persistence round-trip",
        pre = function()
            engine.start({
                capacity = 100,
                persist = { enabled = true, path = "/tmp/encore-test-persist.json", max = 100, interval = 99999 },
            })
            engine.clear()
            vim.fn.setline(1, "hello world")
        end,
        inputs = { key("dd") },
        wait = function()
            return #engine.get() >= 1
        end,
        check = function()
            local msgs = {}
            local n = #engine.get()
            engine.save()
            engine.clear()
            engine.load()
            local got = engine.get()
            if #got ~= n then
                msgs[#msgs + 1] = string.format("load %d, want %d", #got, n)
            end
            local last = got[#got]
            if not last or last.operator ~= "d" then
                msgs[#msgs + 1] = "last entry operator wrong"
            end
            if not (last and last.replay and #last.replay > 0) then
                msgs[#msgs + 1] = "replay missing after load"
            end
            os.remove("/tmp/encore-test-persist.json")
            return msgs
        end,
    })

    step({
        name = "collect put p",
        pre = function()
            engine.start({ persist = { enabled = false } })
            engine.clear()
            vim.fn.setline(1, "ab")
            vim.fn.setreg('"', "XY", "c")
            vim.api.nvim_win_set_cursor(0, { 1, 2 })
        end,
        inputs = { key("p") },
        wait = function()
            return #engine.get() >= 1
        end,
        check = function()
            local msgs = {}
            local e = engine.get()[1]
            if e.type ~= "operator" then
                msgs[#msgs + 1] = "type: " .. tostring(e.type)
            end
            if e.operator ~= nil then
                msgs[#msgs + 1] = "operator should be nil: " .. tostring(e.operator)
            end
            if e.cmd ~= "p" then
                msgs[#msgs + 1] = "cmd: " .. tostring(e.cmd)
            end
            if render.describe(e) ~= "paste after" then
                msgs[#msgs + 1] = "describe: " .. render.describe(e)
            end
            if render.stat_key(e) ~= "p" then
                msgs[#msgs + 1] = "stat_key: " .. render.stat_key(e)
            end
            return msgs
        end,
    })

    step({
        name = "collect redo C-r",
        pre = function()
            engine.clear()
            vim.fn.setline(1, "ab")
        end,
        inputs = { key("iab<Esc>"), key("u"), key("<C-r>") },
        wait = function()
            return #engine.get() >= 3
        end,
        check = function()
            local msgs = {}
            local e = engine.get()[3]
            if e.type ~= "normal" then
                msgs[#msgs + 1] = "type: " .. tostring(e.type)
            end
            if e.cmd ~= "<C-R>" then
                msgs[#msgs + 1] = "cmd: " .. tostring(e.cmd)
            end
            if render.describe(e) ~= "redo" then
                msgs[#msgs + 1] = "describe: " .. render.describe(e)
            end
            return msgs
        end,
    })

    step({
        name = "replay does not pollute history",
        pre = function()
            engine.start({ persist = { enabled = false } })
            engine.clear()
            vim.fn.setline(1, "a")
            vim.fn.setline(2, "b")
            vim.api.nvim_win_set_cursor(0, { 1, 0 })
        end,
        inputs = { key("j") },
        wait = function()
            return #engine.get() >= 1
        end,
        check = function()
            local msgs = {}
            local before = #engine.get()
            -- replay feeds keys via nvim_feedkeys, which does not emit
            -- CmdAtom in the embedded context: the log must stay unchanged
            require("encore.history").replay(engine.get()[1], 1)
            vim.wait(500, function()
                return false
            end)
            if #engine.get() ~= before then
                msgs[#msgs + 1] = "replay polluted history: " .. before .. " -> " .. #engine.get()
            end
            -- let history.replay's suppress queue expire so it cannot
            -- swallow the next step's input (matches on the same keys)
            vim.wait(1100, function()
                return false
            end)
            return msgs
        end,
    })

    step({
        name = "suppress arms the matcher",
        pre = function()
            engine.start({ persist = { enabled = false } })
            engine.clear()
            vim.fn.setline(1, "a")
            vim.fn.setline(2, "b")
            vim.fn.setline(3, "c")
            vim.api.nvim_win_set_cursor(0, { 1, 0 })
        end,
        inputs = { key("j") },
        wait = function()
            return #engine.get() >= 1
        end,
        check = function()
            -- suppress the j entry: the next j atom must be skipped
            engine.suppress(engine.get()[1], 1)
            return {}
        end,
    })

    step({
        name = "suppress skips only matching atoms",
        inputs = { key("j"), key("k") },
        wait = function()
            return #engine.get() >= 2
        end,
        check = function()
            local msgs = {}
            local got = engine.get()
            if #got ~= 2 then
                msgs[#msgs + 1] = "size " .. #got .. " (j should be suppressed)"
            end
            if got[#got].cmd ~= "k" then
                msgs[#msgs + 1] = "last entry should be k, got " .. tostring(got[#got].cmd)
            end
            return msgs
        end,
    })

    step({
        name = "remove deletes entries by identity",
        pre = function()
            engine.start({ persist = { enabled = false } })
            engine.clear()
            vim.fn.setline(1, "a")
            vim.fn.setline(2, "b")
            vim.fn.setline(3, "c")
            vim.api.nvim_win_set_cursor(0, { 1, 0 })
        end,
        inputs = { key("j"), key("k"), key("l") },
        wait = function()
            return #engine.get() >= 3
        end,
        check = function()
            local msgs = {}
            engine.remove({ engine.get()[2] })
            local got = engine.get()
            if #got ~= 2 then
                msgs[#msgs + 1] = "size " .. #got
            end
            if got[1].cmd ~= "j" or got[2].cmd ~= "l" then
                msgs[#msgs + 1] = "wrong entries after remove"
            end
            return msgs
        end,
    })

    step({
        name = "save does not mutate atoms",
        pre = function()
            engine.start({
                capacity = 100,
                persist = { enabled = true, path = "/tmp/encore-test-atoms.json", max = 100, interval = 99999 },
            })
            engine.clear()
            vim.keymap.set("n", "qq", "<Esc>:echo 1<CR>")
        end,
        inputs = { key("qq") },
        wait = function()
            local e = engine.get()[1]
            return e ~= nil and e.atoms ~= nil
        end,
        check = function()
            local msgs = {}
            local e = engine.get()[1]
            if not e.atoms then
                return { "composite mapping produced no atoms (shape changed?)" }
            end
            engine.save()
            for _, a in ipairs(e.atoms) do
                if type(a.keys) == "string" and a.keys:sub(1, 4) == "b64:" then
                    msgs[#msgs + 1] = "save mutated in-memory atoms"
                    break
                end
            end
            local function fsize()
                local f = io.open("/tmp/encore-test-atoms.json", "rb")
                local n = f and f:seek("end") or 0
                if f then
                    f:close()
                end
                return n
            end
            local size1 = fsize()
            engine.save()
            local size2 = fsize()
            if size1 ~= size2 then
                msgs[#msgs + 1] = string.format("repeated save changed file size: %d -> %d", size1, size2)
            end
            vim.keymap.del("n", "qq")
            os.remove("/tmp/encore-test-atoms.json")
            engine.stop()
            return msgs
        end,
    })

    step({
        name = "max_bytes trims to newest entries",
        pre = function()
            engine.start({
                capacity = 100,
                persist = {
                    enabled = true,
                    path = "/tmp/encore-test-bytes.json",
                    max = 100,
                    interval = 99999,
                    max_bytes = 10,
                },
            })
            engine.clear()
            vim.fn.setline(1, "hello world")
        end,
        inputs = { key("dd") },
        wait = function()
            return #engine.get() >= 1
        end,
        check = function()
            local msgs = {}
            engine.save()
            local f = io.open("/tmp/encore-test-bytes.json", "r")
            if not f then
                return { "save did not write the file" }
            end
            local content = f:read("*a")
            f:close()
            local ok, decoded = pcall(vim.json.decode, content)
            if not ok then
                msgs[#msgs + 1] = "file unreadable: " .. tostring(decoded)
            elseif #decoded ~= 0 then
                -- one entry far exceeds 10 bytes: only the empty slice fits
                msgs[#msgs + 1] = "expected 0 entries, got " .. #decoded
            end
            os.remove("/tmp/encore-test-bytes.json")
            engine.stop()
            return msgs
        end,
    })

    _G.encore_steps = steps
end
