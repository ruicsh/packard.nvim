local packard = require("packard")

-- Mock Git and bootstrap to avoid network/fs calls during tests
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

local function assert_error(fn, msg)
  local ok, err = pcall(fn)
  if ok then
    error("Expected error but got success")
  end
  if not err:find(msg, 1, true) then
    error(string.format("Expected error '%s' but got '%s'", msg, err))
  end
end

local function test_normalization()
  print("Testing normalization...")
  packard.setup({
    self_management = false,
    plugins = {
      "neovim/nvim-lspconfig",
      { "tpope/vim-fugitive", name = "fugitive", branch = "dev" },
      "https://github.com/folke/lazy.nvim.git",
    },
  })

  assert(#packard.plugins == 3)

  assert(packard.plugins[1].owner_repo == "neovim/nvim-lspconfig")
  assert(packard.plugins[1].name == "nvim-lspconfig")
  assert(packard.plugins[1].url == "https://github.com/neovim/nvim-lspconfig.git")
  assert(packard.plugins[1].branch == nil)

  assert(packard.plugins[2].owner_repo == "tpope/vim-fugitive")
  assert(packard.plugins[2].name == "fugitive")
  assert(packard.plugins[2].branch == "dev")

  assert(packard.plugins[3].owner_repo == "folke/lazy.nvim")
  assert(packard.plugins[3].url == "https://github.com/folke/lazy.nvim.git")
end

local function test_defaults_and_overrides()
  print("Testing defaults and overrides...")
  packard.setup({
    self_management = false,
    defaults = { minimum_release_age = 10 },
    plugins = {
      { "plugin/a" },
      { "plugin/b", minimum_release_age = 0 },
      { "plugin/c", minimum_release_age = 50 },
    },
  })

  assert(packard.plugins[1].minimum_release_age == 10)
  assert(packard.plugins[2].minimum_release_age == 0)
  assert(packard.plugins[3].minimum_release_age == 50)

  -- Test global default fallback
  packard.setup({ self_management = false, plugins = { "plugin/d" } })
  assert(packard.plugins[1].minimum_release_age == 30)
end

local function test_lazy_load_fields()
  print("Testing lazy load fields...")
  local config_fn = function() end
  packard.setup({
    self_management = false,
    plugins = {
      {
        "plugin/e",
        lazy = false,
        priority = 50,
        event = "BufRead",
        cmd = "MyCmd",
        keys = "<leader>x",
        ft = { "lua", "python" },
        config = config_fn,
        opts = { x = 1 },
      },
    },
  })

  local p = packard.plugins[1]
  assert(p.lazy == false)
  assert(p.priority == 50)
  assert(p.event == "BufRead")
  assert(p.cmd == "MyCmd")
  assert(p.keys == "<leader>x")
  assert(type(p.ft) == "table" and p.ft[1] == "lua")
  assert(p.config == config_fn)
  assert(p.opts.x == 1)
end

local function test_errors()
  print("Testing error cases...")

  -- Duplicate
  assert_error(function()
    packard.setup({ self_management = false, plugins = { "a/b", "a/b" } })
  end, "duplicate plugin 'a/b'")

  -- SSH URL
  assert_error(function()
    packard.setup({ self_management = false, plugins = { "git@github.com:foo/bar.git" } })
  end, "SSH URLs are not supported")

  -- Invalid source
  assert_error(function()
    packard.setup({ self_management = false, plugins = { "invalid-format" } })
  end, "invalid plugin source 'invalid-format'")

  -- Invalid age type
  assert_error(function()
    packard.setup({ self_management = false, plugins = { { "a/b", minimum_release_age = "not a number" } } })
  end, "must be a number")

  -- Negative age
  assert_error(function()
    packard.setup({ self_management = false, plugins = { { "a/b", minimum_release_age = -5 } } })
  end, "must be a number")
end

test_normalization()
test_defaults_and_overrides()
test_lazy_load_fields()
test_errors()

print("Parser tests passed!")
