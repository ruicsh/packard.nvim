--[[@diagnostic disable: duplicate-set-field]]

local Helpers = require("tests.helpers")
local Colorscheme = require("packard.colorscheme")
local Loader = require("packard.loader")
local Utils = require("packard.utils")

-- Save originals once
local original_get_plugin_path = Utils.get_plugin_path
local original_getcompletion = vim.fn.getcompletion
local original_load_and_config = Loader.load_and_config
local original_register_triggers = Loader.register_triggers

-- Global test mocks for Loader methods
local loaded_plugins = {}
local triggered_plugins = {}

Loader.load_and_config = function(plugin, _plugins)
  table.insert(loaded_plugins, plugin.owner_repo)
end

Loader.register_triggers = function(plugin)
  table.insert(triggered_plugins, plugin.owner_repo)
end

vim.fn.getcompletion = function(str, cmdline)
  if str == "" and cmdline == "color" then
    return { "default", "habamax" }
  end
  return {}
end

local function clear(t)
  for i = #t, 1, -1 do
    t[i] = nil
  end
end

local function reset_tracking()
  clear(loaded_plugins)
  clear(triggered_plugins)
end

Helpers.describe("Colorscheme autoload (ADR-011)", function()
  Helpers.it("short-circuits when scheme is already built-in", function()
    reset_tracking()
    local temp_dir, cleanup = Helpers.with_temp_dir({})
    Utils.get_plugin_path = function(_plugin)
      return temp_dir
    end

    local plugin = {
      owner_repo = "owner/nvim",
      name = "nvim",
      _cond = true,
    }

    Colorscheme.register({ plugin })
    -- "default" is in getcompletion return, so callback returns early
    pcall(vim.cmd.colorscheme, "default")

    Helpers.expect(plugin._cond).to_be(true)
    Helpers.expect(#loaded_plugins).to_be(0)
    Helpers.expect(#triggered_plugins).to_be(0)
    cleanup()
  end)

  Helpers.it("loads a cond-blocked plugin that provides the colorscheme", function()
    reset_tracking()
    local temp_dir, cleanup = Helpers.with_temp_dir({
      ["colors/test_scheme.lua"] = "-- mock colorscheme",
    })
    Utils.get_plugin_path = function(_plugin)
      return temp_dir
    end

    local init_called = false
    local plugin = {
      owner_repo = "owner/test-scheme",
      name = "test-scheme",
      _cond = true,
      init = function()
        init_called = true
      end,
      url = "https://github.com/owner/test-scheme",
    }

    Colorscheme.register({ plugin })
    pcall(vim.cmd.colorscheme, "test_scheme")

    Helpers.expect(plugin._cond).to_be_nil()
    Helpers.expect(init_called).to_be(true)
    Helpers.expect(#loaded_plugins).to_be(1)
    Helpers.expect(loaded_plugins[1]).to_be("owner/test-scheme")
    Helpers.expect(#triggered_plugins).to_be(1)
    Helpers.expect(triggered_plugins[1]).to_be("owner/test-scheme")
    cleanup()
  end)

  Helpers.it("loads a cond-blocked plugin that provides a .vim colorscheme", function()
    reset_tracking()
    local temp_dir, cleanup = Helpers.with_temp_dir({
      ["colors/vim_scheme.vim"] = "colorscheme vim_scheme",
    })
    Utils.get_plugin_path = function(_plugin)
      return temp_dir
    end

    local plugin = {
      owner_repo = "owner/vim-scheme",
      name = "vim-scheme",
      _cond = true,
    }

    Colorscheme.register({ plugin })
    pcall(vim.cmd.colorscheme, "vim_scheme")

    Helpers.expect(plugin._cond).to_be_nil()
    Helpers.expect(#loaded_plugins).to_be(1)
    Helpers.expect(loaded_plugins[1]).to_be("owner/vim-scheme")
    cleanup()
  end)

  Helpers.it("skips already-loaded plugins (no _cond)", function()
    reset_tracking()
    local temp_dir, cleanup = Helpers.with_temp_dir({
      ["colors/regular.lua"] = "-- mock",
    })
    Utils.get_plugin_path = function(_plugin)
      return temp_dir
    end

    local plugin = {
      owner_repo = "owner/regular",
      name = "regular",
      -- no _cond — plugin already loaded during setup_eager_load
    }

    Colorscheme.register({ plugin })
    pcall(vim.cmd.colorscheme, "regular")

    -- Plugin was never cond-blocked
    Helpers.expect(plugin._cond).to_be_nil()
    -- Should NOT reload the plugin
    Helpers.expect(#loaded_plugins).to_be(0)
    Helpers.expect(#triggered_plugins).to_be(0)
    cleanup()
  end)

  Helpers.it("does nothing when no plugin provides the scheme", function()
    reset_tracking()
    local temp_dir, cleanup = Helpers.with_temp_dir({})
    Utils.get_plugin_path = function(_plugin)
      return temp_dir
    end

    local plugin = {
      owner_repo = "owner/other",
      name = "other",
      _cond = true,
    }

    Colorscheme.register({ plugin })
    pcall(vim.cmd.colorscheme, "nonexistent_scheme")

    Helpers.expect(plugin._cond).to_be(true)
    Helpers.expect(#loaded_plugins).to_be(0)
    Helpers.expect(#triggered_plugins).to_be(0)
    cleanup()
  end)

  Helpers.it("skips plugin when plugin directory does not exist", function()
    reset_tracking()
    Utils.get_plugin_path = function(_plugin)
      return "/nonexistent/path"
    end

    local plugin = {
      owner_repo = "owner/missing",
      name = "missing",
      _cond = true,
    }

    Colorscheme.register({ plugin })
    pcall(vim.cmd.colorscheme, "missing")

    Helpers.expect(plugin._cond).to_be(true)
    Helpers.expect(#loaded_plugins).to_be(0)
    Helpers.expect(#triggered_plugins).to_be(0)
  end)

  Helpers.it("returns early on empty scheme name", function()
    reset_tracking()
    local temp_dir, cleanup = Helpers.with_temp_dir({})
    Utils.get_plugin_path = function(_plugin)
      return temp_dir
    end

    local plugin = {
      owner_repo = "owner/empty",
      name = "empty",
      _cond = true,
    }

    Colorscheme.register({ plugin })
    vim.api.nvim_exec_autocmds("ColorSchemePre", { pattern = "" })

    Helpers.expect(plugin._cond).to_be(true)
    Helpers.expect(#loaded_plugins).to_be(0)
    cleanup()
  end)
end)

-- Restore originals
Utils.get_plugin_path = original_get_plugin_path
vim.fn.getcompletion = original_getcompletion
Loader.load_and_config = original_load_and_config
Loader.register_triggers = original_register_triggers
