--- Collection engine: CmdAtom event -> normalized log entries.
--- The only module touching the CmdAtom event shape.
local M = {}

--- Number of entries kept in memory (ring buffer).
local capacity = 20000
local log = {}
local head = 0 -- index of the oldest entry
local augroup = nil
local listeners = {}
local epoch_base = 0 -- os.time() at start, for converting hrtime -> epoch
local session_start = 0 -- os.time() at start: scope marker for the report
local suppress_queue = {} -- replay reproductions to skip, in expected order
local suppress_timer = nil
local warned = false

local persist = {
    enabled = true,
    path = vim.fn.stdpath("data") .. "/encore/history.json",
    max = 20000,
    interval = 60,
    --- safety net: if the encoded log exceeds this many bytes, keep only
    --- the newest entries that fit (guards against runaway bloat)
    max_bytes = 64 * 1024 * 1024,
}
local dirty = false
local save_timer = nil

--- Feature gate: CmdAtom exists only on master builds after 2026-08-14.
function M.available()
    return vim.fn.exists("##CmdAtom") == 1
end

--- Normalize one event into a plain entry. Defensive: tolerate missing fields.
---@param ev table CmdAtom autocmd event
---@return EncoreEntry
local function normalize(ev)
    local d = ev.data or ev
    local ts = vim.uv.hrtime()
    local entry = {
        ts = ts,
        epoch = epoch_base + ts / 1e9,
        type = d.type,
        keys = d.keys,
        lhs = d.lhs,
        cmd = d.cmd,
        cmdarg = d.cmdarg,
        operator = d.operator,
        count = d.count,
        reg = d.reg,
        pos = d.pos,
        text = d.text,
        changed = d.changed or false,
        moved = d.moved or false,
        undoseq = d.undoseq,
        atoms = d.atoms,
    }
    -- keys may be nil (lossy capture): replay lhs instead.
    entry.replay = (entry.keys ~= nil) and entry.keys or entry.lhs
    return entry
end

--- Ring-buffer insert. Does not notify listeners.
---@param entry EncoreEntry
local function insert(entry)
    if head == 0 then
        head = 1
    end
    if #log < capacity then
        log[#log + 1] = entry
    else
        log[head] = entry
        head = head % capacity + 1
    end
end

---@param entry EncoreEntry
local function push(entry)
    insert(entry)
    dirty = true
    for _, cb in ipairs(listeners) do
        cb(entry)
    end
end

--- Subscribe to new entries. Returns the callback for off_entry().
---@param cb fun(entry: EncoreEntry)
---@return fun(entry: EncoreEntry) cb
function M.on_entry(cb)
    listeners[#listeners + 1] = cb
    return cb
end

---@param cb fun(entry: EncoreEntry)
function M.off_entry(cb)
    for i, registered in ipairs(listeners) do
        if registered == cb then
            table.remove(listeners, i)
            return
        end
    end
end

-- Persistence

local PERSIST_KEYS = {
    "epoch",
    "type",
    "keys",
    "lhs",
    "cmd",
    "cmdarg",
    "operator",
    "count",
    "reg",
    "pos",
    "text",
    "changed",
    "moved",
    "undoseq",
    "atoms",
}

--- Fields that can carry raw internal bytes (invalid UTF-8, control
--- chars): stored base64-encoded so the log file stays valid JSON.
local BYTE_FIELDS = { "keys", "lhs", "text", "cmdarg" }

---@param entry EncoreEntry
---@return table
local function encode_entry(entry)
    local out = {}
    for _, k in ipairs(PERSIST_KEYS) do
        if entry[k] ~= nil then
            out[k] = entry[k]
        end
    end
    for _, k in ipairs(BYTE_FIELDS) do
        if out[k] then
            out[k] = "b64:" .. vim.base64.encode(out[k])
        end
    end
    if out.atoms then
        -- build a fresh array (out.atoms shares the entry's; writing into it would mutate the live log)
        local atoms = {}
        for i, a in ipairs(out.atoms) do
            atoms[i] = encode_entry(a)
        end
        out.atoms = atoms
    end
    return out
end

---@param data table
---@return table
local function decode_entry(data)
    for _, k in ipairs(BYTE_FIELDS) do
        local v = data[k]
        if type(v) == "string" and v:sub(1, 4) == "b64:" then
            data[k] = vim.base64.decode(v:sub(5))
        end
    end
    if data.atoms then
        for i, a in ipairs(data.atoms) do
            decode_entry(a)
        end
    end
    return data
end

--- JSON null decodes to the vim.NIL sentinel (userdata); normalize it
--- back to nil so renderers never concatenate a userdata value.
---@param v any
---@return any
local function denil(v)
    return v == vim.NIL and nil or v
end

---@param data table
---@param i integer monotonic index used as the restored ts
---@return EncoreEntry entry
local function from_persist(data, i)
    local entry = {
        ts = i, -- ordering stand-in; hrtime is meaningless across sessions
        epoch = data.epoch,
        type = denil(data.type),
        keys = denil(data.keys),
        lhs = denil(data.lhs),
        cmd = denil(data.cmd),
        cmdarg = denil(data.cmdarg),
        operator = denil(data.operator),
        count = denil(data.count),
        reg = denil(data.reg),
        pos = denil(data.pos),
        text = denil(data.text),
        changed = data.changed or false,
        moved = data.moved or false,
        undoseq = denil(data.undoseq),
        atoms = data.atoms,
    }
    entry.replay = (entry.keys ~= nil) and entry.keys or entry.lhs
    return entry
end

--- Write the newest persist.max entries to disk (atomic: tmp + rename).
--- When the encoded log exceeds persist.max_bytes, only the newest
--- entries that fit are kept.
function M.save()
    if not persist.enabled then
        return
    end
    local all = M.get()
    local out = {}
    for i = math.max(1, #all - persist.max + 1), #all do
        out[#out + 1] = encode_entry(all[i])
    end
    local ok, encoded = pcall(vim.json.encode, out)
    if not ok then
        vim.notify("encore: failed to encode history: " .. tostring(encoded), vim.log.levels.ERROR)
        return
    end
    if #encoded > persist.max_bytes then
        -- binary search for the largest newest-n slice that fits
        local function encode_newest(n)
            local part = {}
            for i = #out - n + 1, #out do
                part[#part + 1] = out[i]
            end
            local ok2, enc2 = pcall(vim.json.encode, part)
            return (ok2 and enc2) or ""
        end
        local lo, hi, best = 0, #out, 0
        while lo < hi do
            local mid = math.floor((lo + hi) / 2)
            if #encode_newest(mid) <= persist.max_bytes then
                best = mid
                lo = mid + 1
            else
                hi = mid
            end
        end
        encoded = encode_newest(best)
        vim.notify(
            string.format(
                "encore: history exceeded %d MB; kept the newest %d of %d actions",
                math.floor(persist.max_bytes / 1024 / 1024),
                best,
                #out
            ),
            vim.log.levels.WARN
        )
    end
    local dir = vim.fn.fnamemodify(persist.path, ":h")
    if vim.fn.mkdir(dir, "p") == 0 then
        vim.notify("encore: cannot create " .. dir, vim.log.levels.ERROR)
        return
    end
    local tmp = persist.path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then
        vim.notify("encore: cannot write " .. tmp, vim.log.levels.ERROR)
        return
    end
    f:write(encoded)
    f:close()
    os.rename(tmp, persist.path)
    dirty = false
end

--- Restore the log from disk. Silent: no listeners fire.
function M.load()
    if not persist.enabled then
        return
    end
    local f = io.open(persist.path, "r")
    if not f then
        return -- no history yet
    end
    local content = f:read("*a")
    f:close()
    local ok, decoded = pcall(vim.json.decode, content)
    if not ok or type(decoded) ~= "table" then
        -- move the unreadable file aside and start fresh
        local bak = persist.path .. ".bak"
        os.rename(persist.path, bak)
        vim.notify("encore: unreadable history file moved to " .. bak, vim.log.levels.WARN)
        return
    end
    -- keep only the newest `capacity` entries
    for i = math.max(1, #decoded - capacity + 1), #decoded do
        insert(from_persist(decode_entry(decoded[i]), i))
    end
end

-- Lifecycle

--- Epoch of the first action of this session. Entries restored from
--- disk have older epochs, so `e.epoch >= session_start()` means
--- "this session".
function M.session_start()
    return session_start
end

--- Suppress the next `count` collected atoms that match `entry` (replay
--- reproductions are not new user intent). Matching is by replay keys +
--- type, never blind counting, so unrelated user actions are never
--- eaten. The queue expires after a short window in case no atom fires
--- (embedded nvim: feedkeys emits no CmdAtom there).
---@param entry EncoreEntry
---@param count? integer
function M.suppress(entry, count)
    count = count or 1
    for _ = 1, count do
        suppress_queue[#suppress_queue + 1] = entry
    end
    if suppress_timer then
        suppress_timer:close()
    end
    suppress_timer = vim.defer_fn(function()
        suppress_queue = {}
        suppress_timer = nil
    end, 1000)
end

--- Start collecting. Idempotent.
---@param opts? EncoreEngineConfig
---@return boolean started
function M.start(opts)
    opts = opts or {}
    capacity = opts.capacity or capacity
    persist = vim.tbl_deep_extend("force", persist, opts.persist or {})
    if not M.available() then
        if not warned then
            warned = true
            vim.notify(
                "encore.nvim requires the CmdAtom event (Neovim master after 2026-08-14). "
                    .. "Update to a recent nightly. Collection disabled.",
                vim.log.levels.WARN
            )
        end
        return false
    end
    epoch_base = os.time() - vim.uv.hrtime() / 1e9
    if augroup then
        return true -- already running
    end
    session_start = os.time()
    augroup = vim.api.nvim_create_augroup("encore_engine", { clear = true })
    vim.api.nvim_create_autocmd("CmdAtom", {
        group = augroup,
        callback = function(ev)
            -- skip UI navigation inside encore's own views (filetype "encore")
            local buf = ev.buf
            if buf and vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "encore" then
                return
            end
            local entry = normalize(ev)
            if #suppress_queue > 0 then
                local expected = suppress_queue[1]
                if entry.replay == expected.replay and entry.type == expected.type then
                    table.remove(suppress_queue, 1)
                    if #suppress_queue == 0 then
                        if suppress_timer then
                            suppress_timer:close()
                        end
                        suppress_timer = nil
                    end
                    return
                end
            end
            push(entry)
        end,
        desc = "encore: collect user actions",
    })

    M.load()

    if persist.enabled then
        vim.api.nvim_create_autocmd("VimLeavePre", {
            group = augroup,
            callback = function()
                M.save()
            end,
        })
        save_timer = vim.uv.new_timer()
        local timer = assert(save_timer)
        timer:start(persist.interval * 1000, persist.interval * 1000, function()
            -- uv timers run in a fast context (vim.fn.* forbidden, E5560): schedule the write
            vim.schedule(function()
                if dirty then
                    M.save()
                end
            end)
        end)
    end
    return true
end

function M.stop()
    if save_timer then
        save_timer:stop()
        save_timer = nil
    end
    if augroup then
        vim.api.nvim_del_augroup_by_id(augroup)
        augroup = nil
    end
end

--- All collected entries, oldest first.
---@return EncoreEntry[]
function M.get()
    local out = {}
    if head == 0 then
        for _, e in ipairs(log) do
            out[#out + 1] = e
        end
    else
        for i = 0, #log - 1 do
            out[#out + 1] = log[(head + i - 1) % #log + 1]
        end
    end
    return out
end

--- Last n entries, most recent first. nil n returns all (recent first).
--- Reads the ring directly: no full-log copy, so views can call this per
--- entry without O(capacity) allocations.
---@param n? integer
---@return EncoreEntry[]
function M.recent(n)
    local total = #log
    local out = {}
    if total == 0 then
        return out
    end
    n = n or total
    local p = (head == 0) and total or (head - 1)
    if p == 0 then
        p = total
    end
    for _ = 1, math.min(n, total) do
        out[#out + 1] = log[p]
        p = p - 1
        if p == 0 then
            p = total
        end
    end
    return out
end

--- Remove entries by table identity. Deletions persist on the next save.
--- Returns the removed entries.
---@param entries EncoreEntry[]
---@return EncoreEntry[]
function M.remove(entries)
    local all = M.get()
    local wanted = {}
    for _, e in ipairs(entries) do
        wanted[e] = true
    end
    local removed = {}
    local keep = {}
    for _, e in ipairs(all) do
        if wanted[e] then
            removed[#removed + 1] = e
        else
            keep[#keep + 1] = e
        end
    end
    log = keep
    head = 0
    dirty = true
    return removed
end

function M.clear()
    log = {}
    head = 0
end

return M
