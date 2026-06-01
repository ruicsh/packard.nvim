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

return M
