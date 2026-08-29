<p align="center">
        <h2 align="center">encore.nvim</h2>
</p>

<p align="center">
        Semantic HUD, history and reports for nvim
</p>

<p align="center">
        <a href="https://github.com/XXiaoA/encore.nvim/stargazers">
                <img alt="Stars" src="https://img.shields.io/github/stars/XXiaoA/encore.nvim?style=for-the-badge&logo=starship&color=C9CBFF&logoColor=D9E0EE&labelColor=302D41"></a>
        <a href="https://github.com/XXiaoA/encore.nvim/issues">
                <img alt="Issues" src="https://img.shields.io/github/issues/XXiaoA/encore.nvim?style=for-the-badge&logo=bilibili&color=F5E0DC&logoColor=D9E0EE&labelColor=302D41"></a>
        <a href="https://github.com/XXiaoA/encore.nvim">
                <img alt="License" src="https://img.shields.io/github/license/XXiaoA/encore.nvim?color=%23DDB6F2&label=LICENSE&logo=codesandbox&style=for-the-badge&logoColor=D9E0EE&labelColor=302D41"/></a>
</p>

<img width="900" height="1020" alt="image" src="https://github.com/user-attachments/assets/52beadda-b7f8-4414-9137-c27fdd3e8798" />


Key-press plugins show which keys you pressed; encore.nvim records *what you did*. Every action is captured through the [CmdAtom](https://neovim.io/doc/user/autocmd/#CmdAtom) event and parsed into its semantic structure — operator, count, motion, target — so `ci"` reads as *change inside quotes* and `3j` as *down ×3*. The HUD, history and report all work on that structure: repeats fold, ranges replay, habits get charted — none of which a raw keystroke stream can express.

## Features

* **Live HUD:** A fading stack in your corner that shows what you're doing right now — `d2w` appears as *delete 2 words*, `ci"` as *change inside quotes* — interpreted, not echoed.
* **Action History:** Everything you did, browsable and replayable. Consecutive repeats fold with native vim folds (`zo`/`zc`/`zR`), replay any action at the cursor (`5<CR>` repeats), select a range in visual mode and press `<CR>` to replay them all in order, `dd` deletes entries, `M` merges the selection into a macro register.
* **Filters:** Drop noisy actions from the HUD and/or the history by matching the action name shown in the HUD (e.g. keep scrolling out of the HUD while the history still records it). See the *Filters* section below.
* **Session Report:** A multi-panel dashboard: totals and rate, actions by type, top actions as a bar chart, insert stats, a pace sparkline, a weekday × hour activity heatmap, and your "editing personality".
* **Persistence:** The action log survives restarts as a JSON file with atomic writes.
* **Highly Customizable:** Every view, keymap and behavior can be configured.

## Requirements

Neovim **master (0.13-dev)** built after **2026-08-14**, when `CmdAtom` was merged. 0.12 does not have the event and will not work.

## Installation

You can install `encore.nvim` with your favorite plugin manager. Here is an example for *lazy.nvim*:

```lua
{
    "XXiaoA/encore.nvim",
    event = "VeryLazy",
    ---@module "encore"
    ---@type EncoreConfig
    opts = {},
}
```

### Lazy-loaded `keys` of other plugins

When a lazy.nvim `keys` trigger fires before its plugin is loaded,
lazy.nvim loads the plugin and re-feeds the key via `nvim_feedkeys()`.
Input driven by `feedkeys` does not emit CmdAtom, so that action runs
but encore never sees it — only the first time: the plugin is loaded
afterwards and later presses go through normal input.

Classic example: a text-object plugin keyed on `a`/`i` in
operator-pending mode (e.g. `mini.ai` with
`keys = { { "a", mode = "o" } }`) swallows the first `daw`. Give such
plugins an `event = "VeryLazy"` so their mappings exist before first
use.


## Commands

The main command is `:Encore`. It has the following subcommands:

| Command                       | Description                              |
| ----------------------------- | ---------------------------------------- |
| `:Encore` or `:Encore toggle` | Toggles the action history.              |
| `:Encore open`                | Opens the action history.                |
| `:Encore report`              | Opens the session report.                |
| `:Encore hud`                 | Toggles the live HUD.                    |
| `:Encore clear`               | Clears the action log (with confirmation). |

## Configuration

You can configure `encore.nvim` by passing a table to the `setup` function. Here are the default options:

```lua
require("encore").setup({
    engine = {
        ---@type integer
        --- number of actions kept in memory
        capacity = 20000,
        persist = {
            ---@type boolean
            --- save the action log to disk, restored on startup
            enabled = true,
            ---@type string
            --- JSON log file
            path = vim.fn.stdpath("data") .. "/encore/history.json",
            ---@type integer
            --- max entries kept on disk
            max = 20000,
            ---@type integer
            --- seconds between dirty saves (also saved on exit)
            interval = 60,
            --- safety net: keep only the newest entries that fit this
            --- many encoded bytes (guards against runaway bloat)
            max_bytes = 64 * 1024 * 1024,
        },
    },
    hud = {
        ---@type boolean
        enabled = true,
        ---@type integer
        --- how long each popup stays visible, ms
        timeout = 4000,
        ---@type integer
        --- number of stacked popups
        max = 3,
        ---@type boolean
        --- consecutive repeats of the same action merge into one popup with a count
        merge = true,
        ---@type "bottom-right"|"top-right"|"bottom-left"|"top-left"
        position = "bottom-right",
        ---@type number
        --- width relative to editor columns (float < 1), absolute cols otherwise
        width = 0.4,
        ---@type integer
        zindex = 100,
    },
    history = {
        ---@type number
        --- width/height relative to the editor (float < 1), absolute cells otherwise
        width = 0.45,
        height = 0.5,
        ---@type integer
        zindex = 55,
        show_description = true,
        show_time = true,
        ---@type boolean
        --- fold consecutive repeats of the same action with native vim folds
        fold_repeats = true,
        ---@type integer
        --- minimum run length to fold (runs shorter than this stay flat)
        fold_min = 3,
        ---@type integer
        --- max rows rendered in the view (keeps full re-renders bounded);
        --- set to 0 for no limit
        render_limit = 5000,
    },
    report = {
        ---@type integer
        zindex = 56,
    },
    ui = {
        --- refer to `:h 'winborder'`
        border = "rounded",
    },
    filters = {
        -- Drop matching actions from a view. `pattern` is a Lua pattern
        -- matched against the action's name as it appears in the HUD and
        -- history (the part after the icon, e.g. "j", "scroll", "diw",
        -- ":cnext", "ihello"). Plain letters match as a substring, so
        -- use "^name$" for an exact name. `views` limits the filter to
        -- "hud" and/or "history" (default: both).
        -- Examples:
        -- { pattern = "^scroll$", views = { "hud" } }, -- hide scrolling from the HUD, keep it in history
        -- { pattern = "^:w$" },                          -- drop :w everywhere
    },
    keymaps = {
        history = {
            quit = { "<C-c>", "q" },
            replay = "<CR>",
            replay_range = "<CR>",
            delete = "dd",
            macro = "M",
            report = "r",
            help = "?",
        },
        report = {
            quit = { "<C-c>", "q" },
            toggle_scope = "<Tab>",
            export = "y",
            focus_next = ">",
            focus_prev = "<",
            help = "?",
        },
        help = {
            quit = { "<C-c>", "q" },
        },
    },
})
```

### Persistence

The action log is written to `stdpath("data")/encore/history.json` (configurable via `engine.persist.path`). Writes are atomic (tmp file + rename): on exit, and every `interval` seconds when new actions arrived. Raw key bytes are base64-encoded, so the file stays valid JSON readable by any tool.

Restored entries are replayable and visible in the history and report. `<Tab>` in the report switches between *all time* and *this session*.

### Filters

The `filters` option drops specific actions from the HUD and/or the history, so noisy actions (scrolling, frequent saves) don't clutter what you see. What you see in the HUD *is* the filter's input: the action name is the text after the icon (e.g. `→ j` shows the name `j`, `✂ diw` shows `diw`, `:w` shows `:w`, scrolling shows `scroll`, an insert session shows `i` + its text).

```lua
filters = {
    -- hide scrolling from the HUD, but keep it recorded in the history
    { pattern = "^scroll$", views = { "hud" } },
    -- drop :w everywhere (neither HUD nor history)
    { pattern = "^:w$" },
    -- substring match: anything whose name contains "j" (j, 3j, dj, ...)
    -- { pattern = "j" },
},
```

- `pattern` is a [Lua pattern](https://www.lua.org/manual/5.1/manual.html#6.4.1). Plain letters match as a substring, so **use `^name$` for an exact name** — `{ pattern = "j" }` would also hide `3j` and `dj`.
- `views` limits the filter to `"hud"` and/or `"history"` (default: both). Filtered actions are never deleted — they stay in the persisted log and in the report.

### Keymap Actions

The `keymaps` table maps keys to actions inside the views. Keys can be a single string or a table of strings.

History view:

| Action         | Default Key(s)  | Description                                                           |
| ---            | ---             | ---                                                                   |
| `replay`       | `<CR>`          | Replay the action under the cursor. Supports `v:count` (`5<CR>`).     |
| `replay_range` | `<CR>` (visual) | Replay every selected action in order (oldest first).                |
| `delete`       | `dd`            | Delete the entry under the cursor (visual: the selection).            |
| `macro`        | `M` (visual)    | Merge the selection into a macro register (`"aM` = register a).       |
| `help`         | `?`             | Show the keybinding helper page.                                      |
| `report`       | `r`             | Open the report.                                                      |
| `quit`         | `<C-c>`, `q`    | Close the history.                                                    |

Report view:

| Action         | Default Key(s) | Description                                    |
| ---            | ---            | ---                                            |
| `toggle_scope` | `<Tab>`        | Toggle between session and all-time stats.     |
| `export`       | `y`            | Copy a plain-text report to the clipboard.     |
| `focus_next`   | `>`            | Move focus to the next panel.                  |
| `focus_prev`   | `<`            | Move focus to the previous panel.              |
| `help`         | `?`            | Show the keybinding helper page.               |
| `quit`         | `<C-c>`, `q`   | Close the report.                              |

## Highlighting

`encore.nvim` uses the following highlight groups. Customize them like any other group.

| Highlight Group    | Default          | Description                                       |
| ---                | ---              | ---                                               |
| `EncoreTypeIcon`   | link to `Keyword` | Action type icons in the history and report.      |
| `EncoreName`       | bold             | Action names.                                     |
| `EncoreDesc`       | link to `Comment` | Action descriptions.                              |
| `EncoreTime`       | link to `Comment` | Timestamps in the history.                        |
| `EncoreDim`        | link to `Comment` | Dimmed labels.                                    |
| `EncoreCount`      | link to `Number`  | Counts and totals.                                |
| `EncoreTitle`      | bold             | Report title.                                     |
| `EncoreSection`    | link to `Keyword` | Report section headers.                           |
| `EncoreBarTrack`   | link to `Comment` | Bar chart track and empty heatmap cells.          |

## Tests

```bash
make test
```

Runs the headless plenary.busted suite (render, config), then the embedded-nvim engine suite (needs `pynvim`: `pip install pynvim`). The engine suite runs in an embedded nvim with a UI attached (CmdAtom does not fire headless). RPC `nvim_input` — the only input path that emits CmdAtom — is processed only while no Lua chunk is on the stack, so tests/run_engine.py drives short exec_lua steps and waits driver-side. CI runs the same command on nightly.
