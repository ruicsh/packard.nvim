local Helpers = require("tests.helpers")
local packard = require("packard")
local Lockfile = require("packard.lockfile")

Helpers.describe("Colorscheme Autoload", function()
  -- Setup mocks (same pattern as lazy_spec.lua)
  local original_pack_add = vim.pack.add
  vim.pack.add = function() end

  local original_isdirectory = vim.fn.isdirectory
  vim.fn.isdirectory = function()
    return 1
  end

  local original_get_installed = Lockfile.get_installed_commit
  Lockfile.get_installed_commit = function()
    return "abc1234"
  end

  local original_getcompletion = vim.fn.getcompletion
  vim.fn.getcompletion = function(_, _)
    return {
      "default",
      "habamax",
      "blue",
      "darkblue",
      "desert",
      "elflord",
      "evening",
      "industry",
      "koehler",
      "morning",
      "murphy",
      "pablo",
      "peachpuff",
      "ron",
      "shine",
      "slate",
      "torte",
      "zellner",
    }
  end

  local original_get_plugin_path = require("packard.utils").get_plugin_path

  -- Helper: fire the ColorSchemePre autocmd callback for a given colorscheme name
  local function fire_colorscheme(name)
    local autocmds = vim.api.nvim_get_autocmds({ event = "ColorSchemePre", group = "packard_colorscheme" })
    for _, au in ipairs(autocmds) do
      if au.desc == "packard: colorscheme autoload" and au.callback then
        au.callback({ match = name })
      end
    end
  end

  -- Helper: reset packard state between tests
  local function reset_packard()
    for _, name in ipairs({
      "test-plugin",
      "tokyonight",
      "mytheme",
      "vimtheme",
      "already-loaded",
      "cond-blocked",
      "local-theme",
    }) do
      package.loaded["packard.plugins." .. name] = nil
    end
    pcall(vim.api.nvim_del_augroup_by_name, "packard_colorscheme")
  end

  -- Test 1: Built-in colorscheme short-circuits
  Helpers.it("short-circuits built-in Neovim colorschemes", function()
    reset_packard()
    local config_called = false

    local tmpdir = vim.fn.tempname()
    --[[@diagnostic disable-next-line: redundant-parameter]]
    vim.fn.mkdir(tmpdir .. "/colors/default", "p")
    local f = io.open(tmpdir .. "/colors/default.lua", "w")
    if f then
      f:write("vim.g.colors_name = 'default'")
      f:close()
    end

    require("packard.utils").get_plugin_path = function()
      return tmpdir
    end

    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/test-plugin",
          event = "BufReadPost",
          config = function()
            config_called = true
          end,
        },
      },
    })

    fire_colorscheme("default")

    require("packard.utils").get_plugin_path = original_get_plugin_path
    vim.fn.delete(tmpdir, "rf")
    Helpers.expect(config_called).to_be(false)
  end)

  -- Test 2: Matching colors/<name>.lua loads plugin
  Helpers.it("loads plugin when colors/<name>.lua matches", function()
    reset_packard()
    local config_called = false

    local tmpdir = vim.fn.tempname()
    --[[@diagnostic disable-next-line: redundant-parameter]]
    vim.fn.mkdir(tmpdir .. "/colors/tokyonight", "p")
    local f = io.open(tmpdir .. "/colors/tokyonight.lua", "w")
    if f then
      f:write("vim.g.colors_name = 'tokyonight'")
      f:close()
    end

    require("packard.utils").get_plugin_path = function()
      return tmpdir
    end

    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/tokyonight",
          event = "BufReadPost",
          config = function()
            config_called = true
          end,
        },
      },
    })

    fire_colorscheme("tokyonight")

    require("packard.utils").get_plugin_path = original_get_plugin_path
    vim.fn.delete(tmpdir, "rf")
    Helpers.expect(config_called).to_be(true)
  end)

  -- Test 3: Matching colors/<name>.vim also works
  Helpers.it("loads plugin when colors/<name>.vim matches", function()
    reset_packard()
    local config_called = false

    local tmpdir = vim.fn.tempname()
    --[[@diagnostic disable-next-line: redundant-parameter]]
    vim.fn.mkdir(tmpdir .. "/colors/mytheme", "p")
    local f = io.open(tmpdir .. "/colors/mytheme.vim", "w")
    if f then
      f:write("let g:colors_name = 'mytheme'")
      f:close()
    end

    require("packard.utils").get_plugin_path = function()
      return tmpdir
    end

    packard.setup({
      self_management = false,
      plugins = {
        {
          "bar/mytheme",
          event = "BufReadPost",
          config = function()
            config_called = true
          end,
        },
      },
    })

    fire_colorscheme("mytheme")

    require("packard.utils").get_plugin_path = original_get_plugin_path
    vim.fn.delete(tmpdir, "rf")
    Helpers.expect(config_called).to_be(true)
  end)

  -- Test 4: No matching file → no-op
  Helpers.it("does nothing when no colors/<name> file exists", function()
    reset_packard()
    local config_called = false

    local tmpdir = vim.fn.tempname()

    require("packard.utils").get_plugin_path = function()
      return tmpdir
    end

    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/nocolor",
          event = "BufReadPost",
          config = function()
            config_called = true
          end,
        },
      },
    })

    fire_colorscheme("nonexistent")

    require("packard.utils").get_plugin_path = original_get_plugin_path
    vim.fn.delete(tmpdir, "rf")
    Helpers.expect(config_called).to_be(false)
  end)

  -- Test 5: Already-loaded plugin is skipped
  Helpers.it("skips already-loaded plugins", function()
    reset_packard()
    local config_called = false

    local tmpdir = vim.fn.tempname()
    --[[@diagnostic disable-next-line: redundant-parameter]]
    vim.fn.mkdir(tmpdir .. "/colors/already-loaded", "p")
    local f = io.open(tmpdir .. "/colors/already-loaded.lua", "w")
    if f then
      f:write("vim.g.colors_name = 'already-loaded'")
      f:close()
    end

    require("packard.utils").get_plugin_path = function()
      return tmpdir
    end

    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/already-loaded",
          event = "BufReadPost",
          config = function()
            config_called = true
          end,
        },
      },
    })

    -- Mark plugin as already loaded
    package.loaded["packard.plugins.already-loaded"] = true

    fire_colorscheme("already-loaded")

    require("packard.utils").get_plugin_path = original_get_plugin_path
    vim.fn.delete(tmpdir, "rf")
    Helpers.expect(config_called).to_be(false)
  end)

  -- Test 6: cond = false plugin is skipped
  Helpers.it("skips plugins with cond = false", function()
    reset_packard()
    local config_called = false

    local tmpdir = vim.fn.tempname()
    --[[@diagnostic disable-next-line: redundant-parameter]]
    vim.fn.mkdir(tmpdir .. "/colors/cond-blocked", "p")
    local f = io.open(tmpdir .. "/colors/cond-blocked.lua", "w")
    if f then
      f:write("vim.g.colors_name = 'cond-blocked'")
      f:close()
    end

    require("packard.utils").get_plugin_path = function()
      return tmpdir
    end

    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/cond-blocked",
          cond = false,
          event = "BufReadPost",
          config = function()
            config_called = true
          end,
        },
      },
    })

    fire_colorscheme("cond-blocked")

    require("packard.utils").get_plugin_path = original_get_plugin_path
    vim.fn.delete(tmpdir, "rf")
    Helpers.expect(config_called).to_be(false)
  end)

  -- Test 7: Re-setup is safe (augroup cleared)
  Helpers.it("is safe to call setup multiple times (augroup cleared)", function()
    reset_packard()

    local tmpdir = vim.fn.tempname()
    --[[@diagnostic disable-next-line: redundant-parameter]]
    vim.fn.mkdir(tmpdir .. "/colors/theme1", "p")
    local f = io.open(tmpdir .. "/colors/theme1.lua", "w")
    if f then
      f:write("vim.g.colors_name = 'theme1'")
      f:close()
    end

    require("packard.utils").get_plugin_path = function()
      return tmpdir
    end

    packard.setup({
      self_management = false,
      plugins = { { "foo/theme1", event = "BufReadPost", config = function() end } },
    })

    -- Setup again
    reset_packard()
    require("packard.utils").get_plugin_path = function()
      return tmpdir
    end

    packard.setup({
      self_management = false,
      plugins = { { "foo/theme1", event = "BufReadPost", config = function() end } },
    })

    require("packard.utils").get_plugin_path = original_get_plugin_path
    vim.fn.delete(tmpdir, "rf")

    -- Should have exactly one ColorSchemePre autocmd
    local autocmds = vim.api.nvim_get_autocmds({ event = "ColorSchemePre", group = "packard_colorscheme" })
    local count = 0
    for _, au in ipairs(autocmds) do
      if au.desc == "packard: colorscheme autoload" then
        count = count + 1
      end
    end
    Helpers.expect(count).to_be(1)
  end)

  -- Test 8: Local plugin (dir field) is scanned via plugin.dir directly
  Helpers.it("scans local plugin dir directly", function()
    reset_packard()
    local config_called = false

    local tmpdir = vim.fn.tempname()
    --[[@diagnostic disable-next-line: redundant-parameter]]
    vim.fn.mkdir(tmpdir .. "/colors/local-theme", "p")
    local f = io.open(tmpdir .. "/colors/local-theme.lua", "w")
    if f then
      f:write("vim.g.colors_name = 'local-theme'")
      f:close()
    end

    require("packard.utils").get_plugin_path = function(plugin_or_name)
      if type(plugin_or_name) == "table" and plugin_or_name.dir then
        return plugin_or_name.dir
      end
      return tmpdir
    end

    packard.setup({
      self_management = false,
      plugins = {
        {
          dir = tmpdir,
          name = "local-theme",
          event = "BufReadPost",
          config = function()
            config_called = true
          end,
        },
      },
    })

    fire_colorscheme("local-theme")

    require("packard.utils").get_plugin_path = original_get_plugin_path
    vim.fn.delete(tmpdir, "rf")
    Helpers.expect(config_called).to_be(true)
  end)

  -- Restore mocks
  vim.pack.add = original_pack_add
  vim.fn.isdirectory = original_isdirectory
  Lockfile.get_installed_commit = original_get_installed
  vim.fn.getcompletion = original_getcompletion
  require("packard.utils").get_plugin_path = original_get_plugin_path
end)
