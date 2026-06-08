-- packard.nvim — slim top-level orchestrator.
--
-- Subsystem implementations live in:
--   core/       — setup, check, commands, bootstrap
--   loader.lua  — plugin loading and configuration
--
-- This file wires them together, exposes the M table that callers
-- (including tests) require as `local packard = require("packard")`.

local core_bootstrap = require("packard.core.bootstrap")
local core_check = require("packard.core.check")
local core_commands = require("packard.core.commands")
local core_setup = require("packard.core.setup")
local loader = require("packard.loader")

local M = {}

---@class PackardConfig
---@field defaults table
---@field plugins table
---@field ai_review table|nil

---@type PackardConfig|nil
M.config = nil

---@type NormalizedPlugin[]
M.plugins = {}

---@private
M._is_checking = false

---@private
M._is_offline = false

---@private
---Load and configure a single plugin.
---@param plugin table NormalizedPlugin
M._load_and_config = function(plugin)
  loader.load_and_config(plugin, M.plugins)
end

---@private

---Set up eager loading for all plugins.
M._setup_eager_load = function()
  loader.setup_eager_load(M.plugins, M._load_and_config)
end

---@private
---Bootstrap: install via vim.pack.add, build, auto-deps, state, PackChanged.
M._bootstrap = function()
  core_bootstrap.bootstrap(M)
end

---@private
---Register the :Packard user command.
M._register_commands = function()
  core_commands.register_commands(M)
end

---Initialize packard.nvim
---@param opts table
function M.setup(opts)
  if opts and opts.debug then
    loader._debug = true
  end
  return core_setup.setup(opts, M)
end

---Run update check for all plugins
function M.check()
  core_check.check(M)
end

---@private
---Diagnose a plugin's state.
---@param name string Plugin name or substring of owner_repo (e.g. "readline")
---@return table|nil
function M._diagnose(name)
  local results = {}
  local Utils = require("packard.utils")

  for _, p in ipairs(M.plugins) do
    if p.name:find(name, 1, true) or p.owner_repo:find(name, 1, true) then
      results[p.owner_repo] = {
        name = p.name,
        owner_repo = p.owner_repo,
        is_local = p.is_local,
        dir = p.dir,
        _cond = p._cond,
      }
      local r = results[p.owner_repo]

      -- Check package.path for this plugin's lua dir
      local plugin_path = Utils.get_plugin_path(p)
      local lua_dir = plugin_path .. "/lua"
      r.lua_dir = lua_dir
      r.lua_dir_exists = vim.fn.isdirectory(lua_dir) == 1
      r.in_package_path = package.path:find(lua_dir, 1, true) ~= nil
    end
  end

  if next(results) then
    vim.notify("[packard] _diagnose:\n" .. vim.inspect(results), vim.log.levels.INFO)
  else
    vim.notify(string.format("[packard] _diagnose: no plugin found matching '%s'", name), vim.log.levels.WARN)
  end
  return results
end

return M
