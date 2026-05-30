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

  -- Topological sort sorts alphabetically by owner_repo when no deps/priority
  -- 1. folke/lazy.nvim
  -- 2. neovim/nvim-lspconfig
  -- 3. tpope/vim-fugitive

  assert(packard.plugins[1].owner_repo == "folke/lazy.nvim")
  assert(packard.plugins[1].url == "https://github.com/folke/lazy.nvim.git")

  assert(packard.plugins[2].owner_repo == "neovim/nvim-lspconfig")
  assert(packard.plugins[2].name == "nvim-lspconfig")
  assert(packard.plugins[2].url == "https://github.com/neovim/nvim-lspconfig.git")
  assert(packard.plugins[2].branch == nil)

  assert(packard.plugins[3].owner_repo == "tpope/vim-fugitive")
  assert(packard.plugins[3].name == "fugitive")
  assert(packard.plugins[3].branch == "dev")
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

local function test_dependencies()
  print("Testing dependencies...")

  -- 1. Simple dependency parsing
  packard.setup({
    self_management = false,
    plugins = {
      { "owner/repo", dependencies = { "dep/a", "dep/b" } },
    },
  })

  assert(#packard.plugins == 3)
  -- Topological sort ensures deps come before dependents
  assert(packard.plugins[1].owner_repo == "dep/a")
  assert(packard.plugins[2].owner_repo == "dep/b")
  assert(packard.plugins[3].owner_repo == "owner/repo")

  assert(packard.plugins[1].is_dependency == true)
  assert(packard.plugins[3].is_dependency == false)
  assert(packard.plugins[1].lazy == false) -- Auto-injected deps are eager
  assert(packard.plugins[3].lazy == true) -- Default is lazy

  -- 1a. Dependency should be eager even if declared as top-level lazy plugin
  packard.setup({
    self_management = false,
    plugins = {
      { "owner/repo", dependencies = { "dep/a" } },
      { "dep/a", lazy = true },
    },
  })
  local lib
  for _, p in ipairs(packard.plugins) do
    if p.owner_repo == "dep/a" then
      lib = p
      break
    end
  end
  assert(lib.lazy == false)

  -- 2. No duplicates if dep is already declared
  packard.setup({
    self_management = false,
    plugins = {
      { "owner/repo", dependencies = { "dep/a" } },
      "dep/a",
    },
  })
  assert(#packard.plugins == 2)
  assert(packard.plugins[1].owner_repo == "dep/a")
  assert(packard.plugins[1].is_dependency == false) -- User declared it, so it's not "auto-injected"

  -- 3. Complex nesting and sort order
  -- A -> B, B -> C
  packard.setup({
    self_management = false,
    plugins = {
      { "plugin/a", dependencies = { { "plugin/b", branch = "dev" } } },
      { "plugin/b", dependencies = { "plugin/c" } },
    },
  })
  assert(#packard.plugins == 3)
  assert(packard.plugins[1].owner_repo == "plugin/c")
  assert(packard.plugins[2].owner_repo == "plugin/b")
  assert(packard.plugins[2].branch == "dev") -- Branch preserved from dependency spec
  assert(packard.plugins[3].owner_repo == "plugin/a")

  -- 4. Multiple plugins sharing same dependency
  packard.setup({
    self_management = false,
    plugins = {
      { "plugin/a", dependencies = { "https://github.com/shared/dep.git" } },
      { "plugin/b", dependencies = { "shared/dep" } },
    },
  })
  assert(#packard.plugins == 3)
  assert(packard.plugins[1].owner_repo == "shared/dep")
  assert(packard.plugins[1].url == "https://github.com/shared/dep.git")
  -- a and b order depends on owner_repo string sort if priority is same
  assert(packard.plugins[2].owner_repo == "plugin/a")
  assert(packard.plugins[3].owner_repo == "plugin/b")

  -- 5. Priority tiebreaker
  packard.setup({
    self_management = false,
    plugins = {
      { "plugin/b", priority = 100 },
      { "plugin/a", priority = 50 },
      { "plugin/c", priority = 100 },
    },
  })
  assert(#packard.plugins == 3)
  assert(packard.plugins[1].owner_repo == "plugin/b") -- Alpha tiebreaker among same priority
  assert(packard.plugins[2].owner_repo == "plugin/c")
  assert(packard.plugins[3].owner_repo == "plugin/a")

  -- 6. Circular dependency warning (mocking vim.notify)
  local notified = false
  local original_notify = vim.notify
  --[[@diagnostic disable-next-line: duplicate-set-field]]
  vim.notify = function(msg)
    if msg:match("circular dependency") then
      notified = true
    end
  end

  packard.setup({
    self_management = false,
    plugins = {
      { "plugin/a", dependencies = { "plugin/b" } },
      { "plugin/b", dependencies = { "plugin/a" } },
    },
  })
  assert(notified == true)
  vim.notify = original_notify
end

local function test_complex_dependencies()
  print("Testing complex dependency chains...")

  -- Simulation of a deep tree with shared libraries
  -- main -> d1, d2
  -- d1 -> shared
  -- d2 -> shared, d3
  -- d3 -> shared
  packard.setup({
    self_management = false,
    plugins = {
      { "user/main", dependencies = { "dep/1", "dep/2" } },
      { "dep/1", dependencies = { "shared/lib" } },
      { "dep/2", dependencies = { "shared/lib", "dep/3" } },
      { "dep/3", dependencies = { "shared/lib" } },
    },
  })

  -- Expected order (alphabetic tie-breaks):
  -- 1. shared/lib (depth 0)
  -- 2. dep/1 (depends on shared/lib)
  -- 3. dep/3 (depends on shared/lib)
  -- 4. dep/2 (depends on shared/lib, dep/3)
  -- 5. user/main (depends on dep/1, dep/2)
  assert(#packard.plugins == 5)
  assert(packard.plugins[1].owner_repo == "shared/lib")
  assert(packard.plugins[2].owner_repo == "dep/1")
  assert(packard.plugins[3].owner_repo == "dep/3")
  assert(packard.plugins[4].owner_repo == "dep/2")
  assert(packard.plugins[5].owner_repo == "user/main")
end

test_normalization()
test_defaults_and_overrides()
test_lazy_load_fields()
test_errors()
test_dependencies()
test_complex_dependencies()

print("Parser tests passed!")
