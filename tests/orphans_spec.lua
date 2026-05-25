local helpers = require("tests.helpers")
local Orphans = require("packard.orphans")
local describe, it, expect = helpers.describe, helpers.it, helpers.expect

describe("Orphans", function()
  it("detects orphaned directories", function()
    -- Mock get_opt_dirs to return some directories
    local unmock = helpers.mock(Orphans, "get_opt_dirs", function()
      return { "packard.nvim", "plenary.nvim", "telescope.nvim", "orphan.nvim" }
    end)

    local spec = {
      { name = "packard.nvim", owner_repo = "RuiCostaPT/packard.nvim" },
      { name = "plenary.nvim", owner_repo = "nvim-lua/plenary.nvim" },
      { name = "telescope.nvim", owner_repo = "nvim-telescope/telescope.nvim" },
    }

    local state = { queue = {}, blacklist = {} }
    local results = Orphans.find_orphans(spec, state)

    expect(#results.dirs).to_be(1)
    expect(results.dirs[1]).to_be("orphan.nvim")

    unmock()
  end)

  it("protects packard and packard.nvim even if not in spec", function()
    local unmock = helpers.mock(Orphans, "get_opt_dirs", function()
      return { "packard.nvim", "packard" }
    end)

    local spec = {} -- Empty spec
    local state = { queue = {}, blacklist = {} }
    local results = Orphans.find_orphans(spec, state)

    expect(#results.dirs).to_be(0)

    unmock()
  end)

  it("detects stale state metadata", function()
    helpers.mock(Orphans, "get_opt_dirs", function()
      return {}
    end)

    local spec = {
      { name = "plenary.nvim", owner_repo = "nvim-lua/plenary.nvim" },
    }

    local state = {
      queue = {
        ["nvim-lua/plenary.nvim"] = { commit = "123" },
        ["old/orphan.nvim"] = { commit = "456" },
      },
      blacklist = {
        ["another/stale.nvim"] = { "sha1", "sha2" },
      },
    }

    local results = Orphans.find_orphans(spec, state)

    expect(#results.state).to_be(2)
    expect(results.state[1]).to_be("another/stale.nvim")
    expect(results.state[2]).to_be("old/orphan.nvim")
  end)
end)
