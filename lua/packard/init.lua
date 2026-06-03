-- packard.nvim — slim top-level orchestrator.
--
-- Subsystem implementations live in:
--   core/       — setup, check, commands, bootstrap
--   lazy/       — lazy-loading triggers and plugin config execution
--
-- This file wires them together, exposes the M table that callers
-- (including tests) require as `local packard = require("packard")`.

local core_bootstrap = require("packard.core.bootstrap")
local core_check = require("packard.core.check")
local core_commands = require("packard.core.commands")
local core_setup = require("packard.core.setup")
local lazy = require("packard.lazy")

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
---Execute all plugin init() functions.
---Wrapper retained for test mocking (callers pass plugins explicitly).
---@param plugins table|nil Optional list of plugins to process (defaults to M.plugins)
M._run_init_functions = function(plugins)
  core_setup.run_init_functions(plugins or M.plugins)
end

---@private
---Load and configure a single plugin (used by lazy triggers).
---@param plugin table NormalizedPlugin
M._load_and_config = function(plugin)
  lazy.load_and_config(plugin, M.plugins)
end

---@private
---Set up lazy-loading triggers (keymaps, commands, events, filetypes).
M._setup_lazy_load = function()
  lazy.setup_lazy_load(M.plugins, M._load_and_config)
end

---@private
---Set up colorscheme auto-load via ColorSchemePre autocmd.
M._setup_colorscheme = function()
  lazy.setup_colorscheme_autoload(M.plugins, M._load_and_config)
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
  return core_setup.setup(opts, M)
end

---Run update check for all plugins
function M.check()
  core_check.check(M)
end

---@private
---Diagnose a plugin's state: whether it was parsed, its lazy-load setup, and
---whether stub keymaps exist.
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
        lazy = p.lazy,
        has_keys = p.keys ~= nil,
        keys_type = type(p.keys),
        _cond = p._cond,
        triggers = {},
      }
      local r = results[p.owner_repo]

      -- Check package.path for this plugin's lua dir
      local plugin_path = Utils.get_plugin_path(p)
      local lua_dir = plugin_path .. "/lua"
      r.lua_dir = lua_dir
      r.lua_dir_exists = vim.fn.isdirectory(lua_dir) == 1
      r.in_package_path = package.path:find(lua_dir, 1, true) ~= nil

      -- Detect stub keymaps by checking vim.fn.mapcheck (non-destructive).
      -- mapcheck returns a dict with the mapping info, or empty string if none.
      r.found_mappings = {}
      if p.keys then
        local resolved = p.keys
        if type(resolved) == "function" then
          local ok, result = pcall(resolved)
          if ok then
            resolved = result
          else
            resolved = nil
            r.keys_error = tostring(result)
          end
        end
        if resolved then
          local keys = type(resolved) == "table" and resolved or { resolved }
          for _, k in ipairs(keys) do
            local lhs = type(k) == "table" and (k[1] or k.lhs) or k
            local mode_str = type(k) == "table" and k.mode or "n"
            ---@type string[]
            ---@diagnostic disable-next-line: assign-type-mismatch
            local mode_list = type(mode_str) == "string" and { mode_str } or mode_str
            for _, m in ipairs(mode_list) do
              local existing = vim.fn.mapcheck(lhs, m)
              if existing and type(existing) == "table" then
                table.insert(
                  r.found_mappings,
                  string.format("mode=%s lhs=%s desc=%s", m, lhs, existing.desc or "(none)")
                )
              end
            end
          end
          r.found_count = #r.found_mappings
        end
      end
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
