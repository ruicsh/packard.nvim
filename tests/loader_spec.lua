local packard = require("packard")
local helpers = require("tests.helpers")
local expect = helpers.expect
local describe = helpers.describe
local it = helpers.it

-- Mock Git and bootstrap
local Git = require("packard.git")
--[[@diagnostic disable-next-line: duplicate-set-field]]
Git.get_default_branch = function()
  return nil
end
--[[@diagnostic disable-next-line: duplicate-set-field]]
Git.check_network = function()
  return true
end

local original_bootstrap = packard._bootstrap
packard._bootstrap = function() end

describe("Spec Loader", function()
  it("should load single-spec files and arrays", function()
    local files = {
      ["lsp.lua"] = [[return { "neovim/nvim-lspconfig" }]],
      ["ui.lua"] = [[return { { "folke/tokyonight.nvim" }, { "rebelot/kanagawa.nvim" } }]],
    }
    local dir, cleanup = helpers.with_temp_dir(files)

    packard.setup({
      self_management = false,
      specs_dir = dir,
    })

    expect(#packard.plugins).to_be(3)
    local names = {}
    for _, p in ipairs(packard.plugins) do
      table.insert(names, p.name)
    end
    expect(names).to_contain("nvim-lspconfig")
    expect(names).to_contain("tokyonight.nvim")
    expect(names).to_contain("kanagawa.nvim")

    cleanup()
  end)

  it("should load array of strings as multiple specs", function()
    local files = {
      ["libs.lua"] = [[return { "nvim-lua/plenary.nvim", "nvim-tree/nvim-web-devicons" }]],
    }
    local dir, cleanup = helpers.with_temp_dir(files)

    packard.setup({
      self_management = false,
      specs_dir = dir,
    })

    expect(#packard.plugins).to_be(2)
    local names = { packard.plugins[1].owner_repo, packard.plugins[2].owner_repo }
    expect(names).to_contain("nvim-lua/plenary.nvim")
    expect(names).to_contain("nvim-tree/nvim-web-devicons")

    cleanup()
  end)

  it("should skip files prefixed with underscore", function()
    local files = {
      ["active.lua"] = [[return { "a/b" }]],
      ["_disabled.lua"] = [[return { "c/d" }]],
    }
    local dir, cleanup = helpers.with_temp_dir(files)

    packard.setup({
      self_management = false,
      specs_dir = dir,
    })

    expect(#packard.plugins).to_be(1)
    expect(packard.plugins[1].owner_repo).to_be("a/b")

    cleanup()
  end)

  it("should handle cond = false from file-loaded spec", function()
    local files = {
      ["p1.lua"] = [[return { "cond/a", cond = false }]],
      ["p2.lua"] = [[return { "cond/b" }]],
    }
    local dir, cleanup = helpers.with_temp_dir(files)

    packard.setup({
      self_management = false,
      specs_dir = dir,
    })

    -- Both plugins should be in M.plugins
    expect(#packard.plugins).to_be(2)

    local cond_a = nil
    for _, p in ipairs(packard.plugins) do
      if p.owner_repo == "cond/a" then
        cond_a = p
        break
      end
    end
    expect(cond_a).to_be_truthy()
    expect(cond_a._cond).to_be(true)

    cleanup()
  end)

  it("should handle cond as function returning false from file-loaded spec", function()
    local files = {
      ["p1.lua"] = [[return { "cond/c", cond = function() return false end }]],
      ["p2.lua"] = [[return { "cond/d" }]],
    }
    local dir, cleanup = helpers.with_temp_dir(files)

    packard.setup({
      self_management = false,
      specs_dir = dir,
    })

    expect(#packard.plugins).to_be(2)

    local cond_c = nil
    for _, p in ipairs(packard.plugins) do
      if p.owner_repo == "cond/c" then
        cond_c = p
        break
      end
    end
    expect(cond_c).to_be_truthy()
    expect(cond_c._cond).to_be(true)

    cleanup()
  end)

  it("should merge with inline plugins and allow overrides", function()
    local files = {
      ["plugin.lua"] = [[return { "owner/repo", minimum_release_age = 50 }]],
    }
    local dir, cleanup = helpers.with_temp_dir(files)

    packard.setup({
      self_management = false,
      specs_dir = dir,
      plugins = {
        { "owner/repo", minimum_release_age = 10 },
        "new/plugin",
      },
    })

    -- Deduplication logic: last wins. Inline comes after file specs.
    expect(#packard.plugins).to_be(2)
    local p1 = packard.plugins[1] -- owner/repo
    local p2 = packard.plugins[2] -- new/plugin
    if p1.owner_repo == "new/plugin" then
      p1, p2 = p2, p1
    end

    expect(p1.owner_repo).to_be("owner/repo")
    expect(p1.minimum_release_age).to_be(10)
    expect(p2.owner_repo).to_be("new/plugin")

    cleanup()
  end)

  it("should handle enabled = false", function()
    local files = {
      ["p1.lua"] = [[return { "a/b", enabled = false }]],
      ["p2.lua"] = [[return { "c/d" }]],
    }
    local dir, cleanup = helpers.with_temp_dir(files)

    packard.setup({
      self_management = false,
      specs_dir = dir,
    })

    expect(#packard.plugins).to_be(1)
    expect(packard.plugins[1].owner_repo).to_be("c/d")

    cleanup()
  end)

  it("should handle enabled as function returning false", function()
    local files = {
      ["p1.lua"] = [[return { "a/b", enabled = function() return false end }]],
      ["p2.lua"] = [[return { "c/d" }]],
    }
    local dir, cleanup = helpers.with_temp_dir(files)

    packard.setup({
      self_management = false,
      specs_dir = dir,
    })

    expect(#packard.plugins).to_be(1)
    expect(packard.plugins[1].owner_repo).to_be("c/d")

    cleanup()
  end)

  it("should scan recursively", function()
    local files = {
      ["top.lua"] = [[return { "top/plugin" }]],
      ["sub/inner.lua"] = [[return { "sub/plugin" }]],
    }
    local dir, cleanup = helpers.with_temp_dir(files)

    packard.setup({
      self_management = false,
      specs_dir = dir,
    })

    expect(#packard.plugins).to_be(2)
    local names = { packard.plugins[1].owner_repo, packard.plugins[2].owner_repo }
    expect(names).to_contain("top/plugin")
    expect(names).to_contain("sub/plugin")

    cleanup()
  end)

  it("should load dir-only spec from file", function()
    local files = {
      ["local_plugin.lua"] = [[return { dir = "/tmp/test-dir-plugin" }]],
    }
    local dir, cleanup = helpers.with_temp_dir(files)

    packard.setup({
      self_management = false,
      specs_dir = dir,
    })

    expect(#packard.plugins).to_be(1)
    expect(packard.plugins[1].name).to_be("test-dir-plugin")
    expect(packard.plugins[1].dir).to_be("/tmp/test-dir-plugin")
    expect(packard.plugins[1].is_local).to_be(true)
    expect(packard.plugins[1].owner_repo).to_be("/tmp/test-dir-plugin")

    cleanup()
  end)

  it("should report load errors via notify", function()
    local files = {
      ["bad.lua"] = [[this is not valid lua]],
    }
    local dir, cleanup = helpers.with_temp_dir(files)

    local notified = false
    local original_notify = vim.notify
    --[[@diagnostic disable-next-line: duplicate-set-field]]
    vim.notify = function(msg, level)
      if msg:find("failed to load") then
        notified = true
      end
    end

    packard.setup({
      self_management = false,
      specs_dir = dir,
      plugins = { "fallback/plugin" },
    })

    vim.notify = original_notify
    expect(notified).to_be(true)
    expect(#packard.plugins).to_be(1)
    expect(packard.plugins[1].owner_repo).to_be("fallback/plugin")

    cleanup()
  end)
end)

print("\nLoader tests passed!")
