--- Highlight groups for encore views. Adaptive like the rest of the
--- plugin: linked to standard groups so any colorscheme works, with a few
--- bold-only groups for structure.
local api = vim.api
local M = {}

local highlights = {
    TypeIcon = { link = "Keyword" },
    Name = { bold = true },
    Desc = { link = "Comment" },
    Time = { link = "Comment" },
    Dim = { link = "Comment" },
    Count = { link = "Number" },
    Title = { bold = true },
    Section = { link = "Keyword" },
    BarTrack = { link = "Comment" },
}

local function set_highlights()
    for suffix, hi_value in pairs(highlights) do
        local hi_name = "Encore" .. suffix
        if vim.tbl_isempty(api.nvim_get_hl(0, { name = hi_name })) then
            api.nvim_set_hl(0, hi_name, hi_value)
        end
    end
end

function M.setup()
    -- lazy loading skips ColorScheme, so set immediately
    set_highlights()
    vim.api.nvim_create_autocmd("ColorScheme", {
        group = "encore_ui",
        callback = set_highlights,
    })
    vim.api.nvim_create_autocmd("OptionSet", {
        group = "encore_ui",
        pattern = "background",
        callback = set_highlights,
    })
end

return M
