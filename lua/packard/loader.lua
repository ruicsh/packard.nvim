local Utils = require("packard.utils")

local Loader = {}

Loader._debug = false

---Derive the Lua module name for auto-setup from a plugin name.
---Matches lazy.nvim's convention: strips .nvim/.vim suffix and nvim-/vim- prefix.
---@param plugin table NormalizedPlugin
---@return string|nil
function Loader._derive_modname(plugin)
  if plugin.main then
    return plugin.main
  end
  return plugin.name:gsub("%.n?vim$", ""):gsub("^n?vim%-", "")
end
local function _debug_msg(fmt, ...)
  if not Loader._debug and not vim.g.packard_debug then
    return
  end
  print(string.format(fmt, ...))
end

---Resolve path relative to stdpath('config') if relative
---@param path string
---@return string
function Loader.resolve_path(path)
  if path:match("^/") or path:match("^~") then
    return vim.fn.expand(path)
  end
  return vim.fs.joinpath(vim.fn.stdpath("config"), path)
end

---Load a single spec file
---@param filepath string
---@param modname string
---@return table specs, table errors, table warnings
function Loader.load_file(filepath, modname)
  local specs = {}
  local errors = {}
  local warnings = {}

  -- package.loaded[modname] = nil -- Clear cache if we used require
  -- But we use loadfile as per ADR-008

  local chunk, load_err = loadfile(filepath)
  if not chunk then
    table.insert(errors, string.format("%s: %s", filepath, load_err))
    return specs, errors, warnings
  end

  local ok, result = pcall(chunk)
  if not ok then
    table.insert(errors, string.format("%s: %s", filepath, result))
    return specs, errors, warnings
  end

  if type(result) == "table" then
    -- Detect array of specs vs single spec
    local is_array = false
    if type(result[1]) == "table" then
      is_array = true
    elseif result[2] ~= nil then
      is_array = true
    elseif result[1] ~= nil then
      -- Single element. Check if it has any non-integer keys
      local has_named_keys = false
      for k, _ in pairs(result) do
        if type(k) == "string" then
          has_named_keys = true
          break
        end
      end
      if not has_named_keys then
        is_array = true
      end
    end

    if is_array then
      for _, s in ipairs(result) do
        table.insert(specs, s)
      end
    elseif result[1] ~= nil or result.dir ~= nil then
      -- Single spec (either [1] source string, or dir-only local plugin)
      table.insert(specs, result)
    end
    -- If table is empty, we just skip it (nil return case)
  elseif result ~= nil then
    table.insert(warnings, string.format("%s: returned %s, expected table", filepath, type(result)))
  end

  return specs, errors, warnings
end

---Scan directory recursively, files first then subdirectories
---@param path string
---@param base_path string
---@return table specs, table errors, table warnings
function Loader._scan_recursive(path, base_path)
  local all_specs = {}
  local all_errors = {}
  local all_warnings = {}

  local entries = {}
  for name, type in vim.fs.dir(path) do
    if not name:match("^_") then
      table.insert(entries, { name = name, type = type })
    end
  end

  -- Sort entries alphabetically
  table.sort(entries, function(a, b)
    return a.name < b.name
  end)

  local files = {}
  local subdirs = {}

  for _, entry in ipairs(entries) do
    if entry.type == "file" and entry.name:match("%.lua$") then
      table.insert(files, entry.name)
    elseif entry.type == "directory" then
      table.insert(subdirs, entry.name)
    end
  end

  -- Process files first
  for _, filename in ipairs(files) do
    local filepath = vim.fs.joinpath(path, filename)
    local rel_path = filepath:sub(#base_path + 2):gsub("%.lua$", "")
    local modname = rel_path:gsub("[/\\]", ".")

    local specs, errors, warnings = Loader.load_file(filepath, modname)
    vim.list_extend(all_specs, specs)
    vim.list_extend(all_errors, errors)
    vim.list_extend(all_warnings, warnings)
  end

  -- Then subdirectories
  for _, dirname in ipairs(subdirs) do
    local subdir_path = vim.fs.joinpath(path, dirname)
    local specs, errors, warnings = Loader._scan_recursive(subdir_path, base_path)
    vim.list_extend(all_specs, specs)
    vim.list_extend(all_errors, errors)
    vim.list_extend(all_warnings, warnings)
  end

  return all_specs, all_errors, all_warnings
end

---Scan all spec files in the directory
---@param specs_dir string
---@return table specs, table errors, table warnings
function Loader.scan_all(specs_dir)
  local resolved = Loader.resolve_path(specs_dir)
  if vim.fn.isdirectory(resolved) == 0 then
    -- Check if it exists at all
    if vim.fn.filereadable(resolved) == 1 then
      error(string.format("packard.setup: specs_dir '%s' exists but is a file, not a directory", resolved))
    end
    error(string.format("packard.setup: specs_dir '%s' does not exist", resolved))
  end

  return Loader._scan_recursive(resolved, resolved)
end

---Source files from a specific directory (not all rtp entries).
---@param dir string The plugin directory root
---@param pattern string Glob pattern relative to dir (e.g., "plugin/**/*.lua")
local function source_local_glob(dir, pattern)
  local paths = vim.fn.globpath(dir, pattern, "r", true)
  for _, filepath in ipairs(paths) do
    pcall(vim.cmd, "silent! source " .. filepath)
  end
end

---@private
---Load and configure a single plugin.
---@param plugin table NormalizedPlugin
---@param plugins table All plugins (for dependency resolution)
function Loader.load_and_config(plugin, plugins)
  _debug_msg("[packard] load_and_config: '%s' (is_local=%s)", plugin.owner_repo, tostring(plugin.is_local))
  if plugin._cond then
    _debug_msg("[packard] load_and_config: '%s' is _cond, skipping", plugin.name)
    return
  end
  if package.loaded["packard.plugins." .. plugin.name] then
    return
  end
  package.loaded["packard.plugins." .. plugin.name] = true

  -- Force-load dependencies first
  if plugin.dependencies then
    for _, dep in ipairs(plugin.dependencies) do
      for _, p in ipairs(plugins) do
        if p.owner_repo == dep.owner_repo then
          Loader.load_and_config(p, plugins)
          break
        end
      end
    end
  end

  -- Load the plugin code
  if plugin.is_local then
    _debug_msg("[packard] load_and_config: local plugin '%s' — prepending rtp with '%s'", plugin.name, plugin.dir)
    vim.opt.rtp:prepend(plugin.dir)
    source_local_glob(plugin.dir, "plugin/**/*.vim")
    source_local_glob(plugin.dir, "plugin/**/*.lua")
    local ftdetect_vim = vim.fn.globpath(plugin.dir, "ftdetect/**/*.vim", "r", true)
    local ftdetect_lua = vim.fn.globpath(plugin.dir, "ftdetect/**/*.lua", "r", true)
    if #ftdetect_vim > 0 or #ftdetect_lua > 0 then
      _debug_msg("[packard] load_and_config: ftdetect files found, running filetype detect")
      source_local_glob(plugin.dir, "ftdetect/**/*.vim")
      source_local_glob(plugin.dir, "ftdetect/**/*.lua")
      pcall(vim.cmd, "filetype detect")
    end
  else
    _debug_msg("[packard] load_and_config: remote plugin '%s' — calling packadd", plugin.name)
    local ok, err = pcall(vim.cmd.packadd, { args = { plugin.name }, mods = { silent = true, emsg_silent = true } })
    if not ok then
      _debug_msg("[packard] load_and_config: packadd failed for '%s': %s", plugin.name, tostring(err))
    end
  end

  -- Resolve opts
  local opts = plugin.opts
  if type(opts) == "function" then
    local ok, result = pcall(opts)
    if ok then
      opts = result
    else
      vim.notify(string.format("packard: opts function error for '%s': %s", plugin.name, result), vim.log.levels.ERROR)
      opts = {}
    end
  end

  -- Run config function if defined, or auto-setup
  if type(plugin.config) == "function" then
    _debug_msg("[packard] calling explicit config for '%s'", plugin.name)
    plugin.config(plugin, opts or {})
  elseif plugin.config == true or (plugin.config == nil and opts ~= nil) then
    local modname = Loader._derive_modname(plugin)
    _debug_msg("[packard] auto-config: requiring '%s' for '%s'", modname, plugin.name)
    local ok, mod = pcall(require, modname)
    if not ok and not plugin.main and modname ~= plugin.name then
      ok, mod = pcall(require, plugin.name)
    end
    if ok and type(mod) == "table" and type(mod.setup) == "function" then
      _debug_msg("[packard] auto-config: calling '%s'.setup()", modname)
      mod.setup(opts or {})
    end
  end
end

---Register keymaps and commands for a plugin.
---This is extracted from setup_eager_load so it can be reused when
---lazy-loading a plugin (e.g., via the ColorSchemePre autocmd).
---@param plugin table NormalizedPlugin
function Loader.register_triggers(plugin)
  -- 1. Keys
  if plugin.keys then
    local resolved = plugin.keys
    if type(resolved) == "function" then
      local ok, result = pcall(resolved)
      if ok then
        resolved = result
      else
        vim.notify(string.format("packard: keys function error for '%s': %s", plugin.name, result), vim.log.levels.WARN)
        resolved = nil
      end
    end

    if resolved then
      local keys = type(resolved) == "table" and resolved or { resolved }
      for _, key in ipairs(keys) do
        local lhs, rhs, mode
        if type(key) == "string" then
          lhs = key
          mode = "n"
        elseif type(key) == "table" then
          local first = key[1]
          if type(first) == "string" and first:match("^[nivxsotc]+$") and type(key[2]) == "string" then
            mode = first
            lhs = key[2]
            rhs = key[3]
          else
            mode = key.mode or "n"
            lhs = key[1]
            rhs = key[2]
          end
        end

        if lhs and rhs then
          local map_opts = {}
          if type(key) == "table" then
            for k, v in pairs(key) do
              if type(k) ~= "number" and k ~= "mode" then
                map_opts[k] = v
              end
            end
          end
          local modes ---@type string[]
          if type(mode) == "string" then
            modes = vim.split(mode, ",")
          elseif type(mode) == "table" then
            modes = mode
          else
            modes = { "n" }
          end
          for _, m in ipairs(modes) do
            -- Silently skip if keymap already exists
            local expanded = vim.api.nvim_replace_termcodes(lhs, true, true, true)
            local existing = vim.fn.maparg(expanded, m)
            if existing == "" then
              _debug_msg("[packard] mapping %s (%s) for %s", lhs, m, plugin.name)
              pcall(vim.keymap.set, m, lhs, rhs, map_opts)
            else
              _debug_msg("[packard] skipping %s (%s) for %s: already mapped", lhs, m, plugin.name)
            end
          end
        else
          if lhs then
            _debug_msg("[packard] skipping %s for %s: rhs is nil", lhs, plugin.name)
          end
        end
      end
    end
  end

  -- 2. Commands
  if plugin.cmd then
    local cmds = type(plugin.cmd) == "table" and plugin.cmd or { plugin.cmd }
    for _, cmd in ipairs(cmds) do
      -- Silently skip if command already exists
      pcall(vim.api.nvim_create_user_command, cmd, function(args)
        local bang = args.bang and "!" or ""
        local command = cmd .. bang .. (args.args and #args.args > 0 and " " .. args.args or "")
        vim.cmd(command)
      end, { bang = true, nargs = "*", range = true, desc = string.format("packard: %s", plugin.name) })
    end
  end
end

---@private
---Set up eager loading for all plugins.
---@param plugins table All plugins
---@param load_fn function Function to call to load a plugin (single arg: plugin)
function Loader.setup_eager_load(plugins, load_fn)
  -- Pre-populate package.path with each plugin's lua/ directory
  for _, plugin in ipairs(plugins) do
    if not plugin._cond then
      local lua_dir = Utils.get_plugin_path(plugin) .. "/lua"
      package.path = lua_dir .. "/?.lua;" .. lua_dir .. "/?/init.lua;" .. package.path
    end
  end

  for _, plugin in ipairs(plugins) do
    if not plugin._cond then
      -- 1. Run init() hook
      if type(plugin.init) == "function" then
        local ok, err = pcall(plugin.init, plugin)
        if not ok then
          vim.notify(string.format("packard: init function error for '%s': %s", plugin.name, err), vim.log.levels.ERROR)
        end
      end

      -- 2. Load and config
      load_fn(plugin)

      -- 3. Keys + Commands
      Loader.register_triggers(plugin)
    end
  end
end

return Loader
