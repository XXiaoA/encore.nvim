--- Config checks: plain busted specs, run headless.
local eq = assert.are.same
local config = require("encore.config")

describe("config", function()
    it("resolves fraction dimensions against the editor", function()
        eq(config.dim(0.5, 100), 50)
        eq(config.dim(0, 100), 1)
        eq(config.dim(42, 100), 42)
    end)

    it("merges user options over the defaults", function()
        config.merge_config({ hud = { timeout = 9999 } })
        eq(config.opts.hud.timeout, 9999)
        eq(config.opts.hud.enabled, true) -- untouched defaults survive
        config.merge_config({ hud = { timeout = 4000 } })
    end)
end)
