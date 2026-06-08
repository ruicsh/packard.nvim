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
local original_setup_eager_load = packard._setup_eager_load
packard._setup_eager_load = function() end

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

local function test_config_true()
  print("Testing config = true...")
  packard.setup({
    self_management = false,
    plugins = {
      { "plugin/f", config = true },
    },
  })

  local p = packard.plugins[1]
  assert(p.config == true, "config should be stored as true")
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

  -- Invalid config type (string)
  assert_error(function()
    packard.setup({ self_management = false, plugins = { { "a/b", config = "not a function" } } })
  end, "must be a function or true")

  -- Invalid config type (false)
  assert_error(function()
    packard.setup({ self_management = false, plugins = { { "a/b", config = false } } })
  end, "must be a function or true")

  -- Invalid init type
  assert_error(function()
    packard.setup({ self_management = false, plugins = { { "a/b", init = "not a function" } } })
  end, "must be a function")

  -- Invalid main type
  assert_error(function()
    packard.setup({ self_management = false, plugins = { { "a/b", main = true } } })
  end, "must be a string")

  assert_error(function()
    packard.setup({ self_management = false, plugins = { { "a/b", main = 42 } } })
  end, "must be a string")
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

  -- 1a. Dependency should be eager even if declared as top-level plugin
  packard.setup({
    self_management = false,
    plugins = {
      { "owner/repo", dependencies = { "dep/a" } },
      { "dep/a" },
    },
  })

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

local function test_dir_local_plugin()
  print("Testing dir local plugin...")
  packard.setup({
    self_management = false,
    plugins = {
      { dir = "/tmp/test-plugin" },
    },
  })

  assert(#packard.plugins == 1)
  local p = packard.plugins[1]
  assert(p.is_local == true, "should be marked as local")
  assert(p.dir == "/tmp/test-plugin", "dir should be the normalized path")
  assert(p.url == nil, "url should be nil for local plugins")
  assert(p.name == "test-plugin", "name derived from dir path")
  assert(p.owner_repo == "/tmp/test-plugin", "owner_repo is the normalized dir path")
end

local function test_dir_with_name()
  print("Testing dir with explicit name...")
  packard.setup({
    self_management = false,
    plugins = {
      { dir = "/tmp/custom-path", name = "my-plugin" },
    },
  })

  local p = packard.plugins[1]
  assert(p.name == "my-plugin", "explicit name should override path-derived name")
  assert(p.is_local == true)
  assert(p.dir == "/tmp/custom-path")
end

local function test_dir_tilde_expansion()
  print("Testing dir tilde expansion...")
  packard.setup({
    self_management = false,
    plugins = {
      { dir = "~/projects/foo.nvim" },
    },
  })

  local p = packard.plugins[1]
  assert(p.is_local == true)
  -- The "~" should be expanded to the home directory
  assert(not p.dir:match("^~"), "tilde should be expanded")
  assert(p.dir:match("projects/foo%.nvim$"), "should end with projects/foo.nvim")
  assert(p.name == "foo.nvim", "name derived from dir path")
end

local function test_dir_and_source_error()
  print("Testing dir with source error...")
  assert_error(function()
    packard.setup({ self_management = false, plugins = { { "owner/repo", dir = "/tmp/x" } } })
  end, "cannot both be specified")
end

local function test_dir_missing_source_and_dir()
  print("Testing missing source and dir error...")
  assert_error(function()
    packard.setup({ self_management = false, plugins = { {} } })
  end, "must have a 'owner/repo' string or 'dir' field")
end

local function test_dir_empty_string_error()
  print("Testing empty dir string error...")
  assert_error(function()
    packard.setup({ self_management = false, plugins = { { dir = "" } } })
  end, "must not be empty")
end

local function test_dir_non_string_error()
  print("Testing non-string dir error...")
  assert_error(function()
    packard.setup({ self_management = false, plugins = { { dir = 42 } } })
  end, "must be a string, got number")
end

local function test_main_field()
  print("Testing main field...")

  -- 1. main field is extracted and stored
  packard.setup({
    self_management = false,
    plugins = {
      { "owner/repo-a", main = "custom.module" },
      { "owner/repo-b" },
    },
  })

  local a, b
  for _, p in ipairs(packard.plugins) do
    if p.owner_repo == "owner/repo-a" then
      a = p
    elseif p.owner_repo == "owner/repo-b" then
      b = p
    end
  end

  assert(a.main == "custom.module", "main field should be stored as provided")
  assert(b.main == nil, "main field should be nil when not specified")
end

local function test_version_fields()
  print("Testing version fields...")

  -- 1. Explicit version, tag, commit
  packard.setup({
    self_management = false,
    plugins = {
      { "owner/v", version = "1.*" },
      { "owner/t", tag = "v1.2.3" },
      { "owner/c", commit = "abcdef" },
    },
  })

  -- Sort: c, t, v
  assert(packard.plugins[1].owner_repo == "owner/c")
  assert(packard.plugins[1].commit == "abcdef")
  assert(packard.plugins[2].owner_repo == "owner/t")
  assert(packard.plugins[2].tag == "v1.2.3")
  assert(packard.plugins[3].owner_repo == "owner/v")
  assert(packard.plugins[3].version == "1.*")

  -- 2. Defaults
  packard.setup({
    self_management = false,
    defaults = { version = "*" },
    plugins = {
      "owner/a",
      { "owner/b", branch = "dev" },
      { "owner/c", version = "1.0" },
      { "owner/d", version = false },
    },
  })

  -- alphabetical order of owner_repo: a, b, c, d
  assert(packard.plugins[1].owner_repo == "owner/a")
  assert(packard.plugins[1].version == "*")

  assert(packard.plugins[2].owner_repo == "owner/b")
  assert(packard.plugins[2].branch == "dev")
  assert(packard.plugins[2].version == nil) -- branch overrides default version

  assert(packard.plugins[3].owner_repo == "owner/c")
  assert(packard.plugins[3].version == "1.0") -- explicit overrides default

  assert(packard.plugins[4].owner_repo == "owner/d")
  assert(packard.plugins[4].version == nil) -- version = false disables default

  -- 3. Invalid version error
  assert_error(function()
    packard.setup({ self_management = false, plugins = { { "a/b", version = ">>1.0" } } })
  end, "invalid version constraint")
end
local function test_spec_merging()
  print("Testing spec merging...")

  -- 1. Merging keys, opts, and dependencies
  packard.setup({
    self_management = false,
    plugins = {
      { "owner/repo", keys = { "k1" }, opts = { a = 1 }, dependencies = { "dep/1" } },
      { "owner/repo", keys = { "k2" }, opts = { b = 2 }, dependencies = { "dep/2" } },
    },
  })

  assert(#packard.plugins == 3) -- dep/1, dep/2, owner/repo
  local p = packard.plugins[3]
  assert(p.owner_repo == "owner/repo")
  assert(#p.keys == 2)
  assert(p.keys[1] == "k1")
  assert(p.keys[2] == "k2")
  assert(p.opts.a == 1)
  assert(p.opts.b == 2)
  assert(#p.dependencies == 2)
  assert(p.dependencies[1].owner_repo == "dep/1")
  assert(p.dependencies[2].owner_repo == "dep/2")

  -- 2. Merging function-based keys
  packard.setup({
    self_management = false,
    plugins = {
      {
        "owner/func",
        keys = function()
          return { "fk1" }
        end,
      },
      { "owner/func", keys = { "fk2" } },
    },
  })

  assert(#packard.plugins == 1)
  local pf = packard.plugins[1]
  assert(type(pf.keys) == "function")
  local keys = pf.keys()
  assert(#keys == 2)
  assert(keys[1] == "fk1")
  assert(keys[2] == "fk2")

  -- 3. Last one wins for config/init
  local init_calls = 0
  packard.setup({
    self_management = false,
    plugins = {
      {
        "owner/last",
        init = function()
          init_calls = init_calls + 1
        end,
      },
      {
        "owner/last",
        init = function()
          init_calls = init_calls + 10
        end,
      },
    },
  })

  assert(#packard.plugins == 1)
  packard.plugins[1].init()
  assert(init_calls == 10)
end

test_normalization()

test_defaults_and_overrides()
test_config_true()
test_errors()
test_dependencies()
test_complex_dependencies()
test_main_field()
test_version_fields()
test_dir_local_plugin()
test_dir_with_name()
test_dir_tilde_expansion()
test_dir_and_source_error()
test_dir_missing_source_and_dir()
test_dir_empty_string_error()
test_dir_non_string_error()
test_spec_merging()

print("Parser tests passed!")
