---@meta

--- Type definitions shared across encore modules. Declaration-only file:
--- never required at runtime (`@meta` marks it as a LuaLS definition
--- file; the classes resolve workspace-wide).

---@class EncoreEntry
---@field ts number monotonic timestamp (uv hrtime; index stand-in when restored)
---@field epoch number wall-clock epoch seconds
---@field type string CmdAtom atom type
---@field keys? string raw key bytes that produced the action
---@field lhs? string mapped sequence (mapping atoms)
---@field cmd? string resolved command (key notation)
---@field cmdarg? string command argument (f/t char, ex text)
---@field operator? string operator name (d/y/c/…; nil for put)
---@field count? integer
---@field reg? string
---@field pos? integer[] cursor position
---@field text? string inserted text
---@field changed? boolean
---@field moved? boolean
---@field undoseq? integer
---@field atoms? EncoreEntry[] nested atoms (composite mappings)
---@field replay? string keys to re-feed (keys or lhs fallback)

---@class EncorePersistConfig
---@field enabled boolean save the action log to disk, restored on startup
---@field path string JSON log file
---@field max integer max entries kept on disk
---@field interval integer seconds between dirty saves (also saved on exit)
---@field max_bytes integer safety net: keep only the newest entries that fit this many encoded bytes (guards against runaway bloat)

---@class EncoreEngineConfig
---@field capacity integer number of actions kept in memory
---@field persist EncorePersistConfig

---@class EncoreHudConfig
---@field enabled boolean live pills of recent actions, stacked (noice-style)
---@field timeout integer how long each pill stays visible, ms
---@field max integer number of stacked pills
---@field merge boolean consecutive repeats of the same action merge into one pill with a count
---@field position string bottom-right | top-right | bottom-left | top-left
---@field width number width relative to editor columns (float < 1), absolute cols otherwise
---@field zindex integer

---@class EncoreHistoryConfig
---@field width number width/height relative to the editor (float < 1), absolute cells otherwise
---@field height number
---@field zindex integer
---@field show_description boolean
---@field show_time boolean
---@field fold_repeats boolean fold consecutive repeats of the same action with native vim folds
---@field fold_min integer minimum run length to fold (runs shorter than this stay flat)
---@field render_limit integer max rows rendered in the view (0 = no limit)

---@class EncoreReportConfig
---@field zindex integer

---@class EncoreUiConfig
---@field border string see :h nvim_open_win border

---@class EncoreFilter
---@field pattern string Lua pattern matched against the atom name (render.atom)
---@field views? string|string[] "hud" / "history" (default: both)

---@class EncoreHistoryKeymaps
---@field quit string[]
---@field replay string replay the action under the cursor (v:count repeats)
---@field replay_range string visual-mode: replay every selected action in order
---@field delete string delete the entry under the cursor (visual: the selection)
---@field macro string visual-mode: merge the selection into a macro register ("aM = register a, default q)
---@field report string jump to the report
---@field help string show the keybinding helper page

---@class EncoreReportKeymaps
---@field quit string[]
---@field toggle_scope string session/all-time
---@field export string copy a plain-text report
---@field focus_next string
---@field focus_prev string
---@field help string show the keybinding helper page

---@class EncoreHelpKeymaps
---@field quit string[]

---@class EncoreKeymapsConfig
---@field history EncoreHistoryKeymaps
---@field report EncoreReportKeymaps
---@field help EncoreHelpKeymaps

---@class EncoreConfig
---@field engine EncoreEngineConfig
---@field hud EncoreHudConfig
---@field history EncoreHistoryConfig
---@field report EncoreReportConfig
---@field ui EncoreUiConfig
---@field filters EncoreFilter[] drop matching actions from views (pattern on the atom name)
---@field keymaps EncoreKeymapsConfig
