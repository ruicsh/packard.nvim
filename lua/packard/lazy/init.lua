---@private
---Lazy loading subsystem: sets up keymap, command, event, and filetype triggers
---that load a plugin on first use, then run its config/opts.

local Utils = require("packard.utils")

local M = {}

M._debug = false
local function _debug_msg(fmt, ...)
  if not M._debug and not vim.g.packard_debug then
    return
  end
  print(string.format(fmt, ...))
end

---@type table<string, { cleanups: function[] }>
local _plugin_stubs = {}

---Deactivates all lazy-loading triggers (keys, commands, events, ft) for a plugin.
---Matches lazy.nvim's Handler.disable(plugin).
---@param plugin_name string
local function disable_triggers(plugin_name)
  if _plugin_stubs[plugin_name] then
    _debug_msg("[packard] disabling all triggers for '%s'", plugin_name)
    for _, cleanup in ipairs(_plugin_stubs[plugin_name].cleanups) do
      cleanup()
    end
    _plugin_stubs[plugin_name] = nil
  end
end

---Source files from a specific directory (not all rtp entries).
---This matches :packadd behavior which sources plugin/ and ftdetect/ files
---for the specific plugin only, not from the entire rtp.
---@param dir string The plugin directory root
---@param pattern string Glob pattern relative to dir (e.g., "plugin/**/*.lua")
local function source_local_glob(dir, pattern)
  -- "r" flag enables recursive matching with **; list=true returns a Lua table
  local paths = vim.fn.globpath(dir, pattern, "r", true)
  for _, filepath in ipairs(paths) do
    pcall(vim.cmd.source, filepath)
  end
end

---@private
---Load and configure a single plugin.
---@param plugin table NormalizedPlugin
---@param plugins table All plugins (for dependency resolution)
function M.load_and_config(plugin, plugins)
  _debug_msg(
    "[packard] load_and_config called for '%s' (is_local=%s, name=%s)",
    plugin.owner_repo,
    tostring(plugin.is_local),
    plugin.name
  )
  if plugin._cond then
    _debug_msg("[packard] load_and_config: '%s' is _cond, skipping", plugin.name)
    return
  end
  if package.loaded["packard.plugins." .. plugin.name] then
    _debug_msg("[packard] load_and_config: '%s' already loaded, skipping", plugin.name)
    return
  end
  package.loaded["packard.plugins." .. plugin.name] = true

  -- Force-load dependencies first (even if lazy), matching lazy.nvim behavior.
  -- Without this, a deferred dependency (e.g. event="VeryLazy") would never run
  -- its config before an eager dependent that references it.
  if plugin.dependencies then
    for _, dep in ipairs(plugin.dependencies) do
      for _, p in ipairs(plugins) do
        if p.owner_repo == dep.owner_repo then
          M.load_and_config(p, plugins)
          break
        end
      end
    end
  end

  -- Load the plugin code
  disable_triggers(plugin.name)
  if plugin.is_local then
    _debug_msg("[packard] load_and_config: local plugin '%s' — prepending rtp with '%s'", plugin.name, plugin.dir)
    -- Local plugins are outside packpath, so add dir to rtp directly
    vim.opt.rtp:prepend(plugin.dir)
    -- Source plugin/ and ftdetect/ files (matching :packadd behavior).
    -- globpath only searches the specific directory, not all rtp entries.
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
    -- bang=false for packadd ensures plugin/ and ftdetect/ are sourced
    local ok, err = pcall(vim.cmd.packadd, plugin.name)
    if not ok then
      _debug_msg("[packard] load_and_config: packadd failed for '%s': %s", plugin.name, tostring(err))
    end
  end

  -- Resolve opts: lazy.nvim convention — opts can be a function returning a table
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
    -- Explicit config function — call with (plugin, opts)
    _debug_msg("[packard] calling explicit config for '%s'", plugin.name)
    plugin.config(plugin, opts or {})
  elseif plugin.config == true or (plugin.config == nil and opts ~= nil) then
    -- Auto-config: lazy.nvim convention
    --   config = true → always calls require(MAIN).setup(opts or {})
    --   opts present + no config → calls require(MAIN).setup(opts or {})
    local modname = plugin.main or plugin.name:gsub("%.nvim$", "")
    _debug_msg("[packard] auto-config: requiring '%s' for '%s'", modname, plugin.name)
    local ok, mod = pcall(require, modname)
    if not ok and not plugin.main and modname ~= plugin.name then
      _debug_msg("[packard] auto-config: retry require '%s' for '%s'", plugin.name, plugin.name)
      ok, mod = pcall(require, plugin.name)
    end
    if ok and type(mod) == "table" and type(mod.setup) == "function" then
      _debug_msg("[packard] auto-config: calling '%s'.setup()", modname)
      mod.setup(opts or {})
    else
      if not ok then
        _debug_msg("[packard] auto-config: require failed: %s", tostring(mod))
      elseif type(mod) ~= "table" then
        _debug_msg("[packard] auto-config: module is not a table: %s", type(mod))
      elseif type(mod.setup) ~= "function" then
        _debug_msg("[packard] auto-config: module.setup is not a function: %s", type(mod.setup))
      end
    end
  end
end

---@private
---Set up lazy-loading triggers for all plugins.
---@param plugins table All plugins
---@param load_fn function Function to call to load a plugin (single arg: plugin)
function M.setup_lazy_load(plugins, load_fn)
  -- Pre-populate package.path with each plugin's lua/ directory so spec functions
  -- (keys, cmd, event, ft) can require() the plugin's main module at setup time.
  -- This matches lazy.nvim: keys = function() local r = require("plugin") ... end
  -- resolves without sourcing plugin/, ftdetect/, colors/, or syntax/ files.
  local prepended_paths = {}
  for _, plugin in ipairs(plugins) do
    if not plugin._cond then
      local lua_dir = Utils.get_plugin_path(plugin) .. "/lua"
      table.insert(prepended_paths, string.format("%s (is_local=%s)", lua_dir, tostring(plugin.is_local)))
      package.path = lua_dir .. "/?.lua;" .. lua_dir .. "/?/init.lua;" .. package.path
    end
  end
  _debug_msg(
    "[packard] setup_lazy_load: prepended %d plugin lua/ dirs to package.path\n%s",
    #prepended_paths,
    table.concat(prepended_paths, "\n")
  )

  for _, plugin in ipairs(plugins) do
    -- Shadow the loop variable so closures capture the per-iteration value,
    -- not the reused loop variable (Lua for-loop scoping semantics).
    local plugin = plugin
    if not plugin._cond then
      local has_triggers = false

      -- 1. Keys
      if plugin.keys then
        -- Resolve function: call it (pcall) and use its return value
        local resolved = plugin.keys
        if type(resolved) == "function" then
          _debug_msg(
            "[packard] resolving keys fn for '%s' (is_local=%s, dir=%s)",
            plugin.name,
            tostring(plugin.is_local),
            plugin.dir or "(none)"
          )
          local ok, result = pcall(resolved)
          if ok then
            resolved = result
            local count = type(resolved) == "table" and #resolved or 1
            _debug_msg("[packard] keys fn OK for '%s': %d entry(ies)", plugin.name, count)
          else
            _debug_msg("[packard] keys fn ERROR for '%s': %s", plugin.name, tostring(result))
            resolved = nil
            vim.notify(
              string.format("[packard] keys function ERROR for '%s': %s", plugin.name, result),
              vim.log.levels.WARN
            )
          end
        end
        if resolved then
          has_triggers = true
          local keys = type(resolved) == "table" and resolved or { resolved }
          -- Flatten: resolve any inner functions returned from merged specs
          local flat = {}
          for _, k in ipairs(keys) do
            if type(k) == "function" then
              local ok, result = pcall(k)
              if ok and result then
                if type(result) == "table" then
                  for _, item in ipairs(result) do
                    table.insert(flat, item)
                  end
                else
                  table.insert(flat, result)
                end
              elseif not ok then
                vim.notify(
                  string.format("packard: keys function error for '%s': %s", plugin.name, tostring(result)),
                  vim.log.levels.WARN
                )
              end
            else
              table.insert(flat, k)
            end
          end
          keys = flat

          for i = 1, #keys do
            local key = keys[i]
            local lhs, rhs, mode
            if type(key) == "string" then
              lhs = key
              mode = "n"
            elseif type(key) == "table" then
              -- lazy.nvim key format: { [mode?], lhs, [rhs], ... }
              -- Detect if first element is a mode string (valid mode chars only).
              -- Also require key[2] to be a string — otherwise it's { lhs, rhs, ... }
              -- format where lhs happens to be a single char like "n" or "v".
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

            if lhs then
              -- Expand modes: comma-separated string or table to list of single-char modes
              local modes = {}
              if type(mode) == "string" then
                modes = vim.split(mode, ",")
              elseif type(mode) == "table" then
                modes = mode
              else
                modes = { "n" }
              end

              -- Build opts for the real mapping (after trigger fires)
              -- Include all non-positional, non-consumed keys from the key spec
              local real_map_opts = {}
              if type(key) == "table" then
                for k, v in pairs(key) do
                  if type(k) ~= "number" and k ~= "mode" then
                    real_map_opts[k] = v
                  end
                end
              end
              real_map_opts.desc = real_map_opts.desc or string.format("packard: load %s", plugin.name)

              -- Check for NOP: if RHS is "" or "<nop>", set directly without lazy-loading
              local is_nop = type(rhs) == "string" and (rhs == "" or rhs:lower() == "<nop>")

              for _, m in ipairs(modes) do
                if is_nop then
                  _debug_msg("[packard] NOP mapping for '%s': mode=%s lhs=%s", plugin.name, m, lhs)
                  vim.keymap.set(m, lhs, rhs, real_map_opts)
                else
                  -- Independent stub for each mode
                  local capture_mode = m
                  local capture_lhs = lhs
                  local capture_rhs = rhs
                  local capture_opts = real_map_opts

                  _debug_msg(
                    "[packard] creating stub keymap: mode=%s lhs=%s rhs=%s plugin=%s",
                    capture_mode,
                    capture_lhs,
                    tostring(capture_rhs),
                    plugin.name
                  )

                  local stub_desc = real_map_opts.desc

                  -- Track stub for centralized cleanup
                  _plugin_stubs[plugin.name] = _plugin_stubs[plugin.name] or { cleanups = {} }
                  table.insert(_plugin_stubs[plugin.name].cleanups, function()
                    if capture_rhs then
                      -- lazy.nvim compatibility: delete first, then set.
                      -- In some Neovim versions/scenarios, just calling set() on an active
                      -- expr mapping might not replace it reliably for the current sequence.
                      pcall(vim.keymap.del, capture_mode, capture_lhs, { buffer = nil })
                      vim.keymap.set(capture_mode, capture_lhs, capture_rhs, capture_opts)
                    else
                      -- No RHS to restore; delete the stub immediately.
                      pcall(vim.keymap.del, capture_mode, capture_lhs, { buffer = nil })
                    end
                  end)

                  vim.keymap.set(capture_mode, capture_lhs, function()
                    _debug_msg(
                      "[packard] stub FIRED: mode=%s lhs=%s plugin=%s rhs=%s",
                      capture_mode,
                      capture_lhs,
                      plugin.name,
                      tostring(capture_rhs)
                    )

                    -- Step 1: Cleanup all stubs for this plugin (including this one).
                    -- Matches lazy.nvim's Handler:_del(keys) + Handler.disable(plugin)
                    disable_triggers(plugin.name)

                    -- Step 2: Load the plugin
                    load_fn(plugin)
                    _debug_msg("[packard] load_fn completed for '%s'", plugin.name)

                    -- Step 3: Replay the keypress synchronously to trigger the real mapping.
                    -- This matches lazy.nvim's synchronous feedkeys behavior.
                    if capture_mode:sub(-1) == "a" then
                      -- Abbreviations need extra care
                      capture_lhs = capture_lhs .. "<C-]>"
                    end
                    local feed = vim.api.nvim_replace_termcodes("<Ignore>" .. capture_lhs, true, true, true)
                    vim.api.nvim_feedkeys(feed, "i", false)

                    -- Return nil so the expr mapping itself feeds nothing.
                    return
                  end, {
                    expr = true,
                    desc = stub_desc,
                    nowait = capture_opts.nowait,
                    replace_keycodes = capture_opts.replace_keycodes,
                    buffer = nil, -- match lazy.nvim exactly
                  })
                end
              end
            end
          end
        end
      end

      -- 2. Commands
      if plugin.cmd then
        has_triggers = true
        local cmds = type(plugin.cmd) == "table" and plugin.cmd or { plugin.cmd }

        -- Track stubs for centralized cleanup
        _plugin_stubs[plugin.name] = _plugin_stubs[plugin.name] or { cleanups = {} }
        table.insert(_plugin_stubs[plugin.name].cleanups, function()
          for i2 = 1, #cmds do
            local c = cmds[i2]
            pcall(vim.api.nvim_del_user_command, c)
          end
        end)

        for i = 1, #cmds do
          local cmd = cmds[i]
          -- Shadow the inner loop variable for closure capture
          local cmd = cmd
          vim.api.nvim_create_user_command(cmd, function(args)
            -- Step 1: Disable all triggers
            disable_triggers(plugin.name)
            -- Step 2: Load the plugin
            load_fn(plugin)
            -- Step 3: Replay the command
            local bang = args.bang and "!" or ""
            vim.cmd(cmd .. bang .. " " .. args.args)
          end, {
            bang = true,
            nargs = "*",
            range = true,
            complete = function(_, line)
              -- Step 1: Disable all triggers to allow real completion
              disable_triggers(plugin.name)
              -- Step 2: Load the plugin
              load_fn(plugin)
              return vim.fn.getcompletion(line, "cmdline")
            end,
            desc = string.format("packard: load %s", plugin.name),
          })
        end
      end

      -- 3. Events
      if plugin.event then
        has_triggers = true
        local events = type(plugin.event) == "table" and plugin.event or { plugin.event }

        -- Filter out pseudo-events like 'VeryLazy' which are not native Neovim events
        local has_deferred = false
        local plain_events = {} -- events without a pattern (e.g. "BufReadPost")
        local event_patterns = {} -- events that have a pattern (event_name -> { pattern, ... })
        --[[@diagnostic disable-next-line: param-type-mismatch]]
        for _, e in ipairs(events) do
          if e == "VeryLazy" or e == "LazyFile" then
            has_deferred = true
          else
            -- Parse event string: "EventName pattern" or just "EventName"
            --[[@diagnostic disable-next-line: param-type-mismatch]]
            local event_name, pattern = e:match("^(%S+)%s+(.+)$")
            if event_name then
              -- Event has a pattern; store as a list to support multiple patterns for the same event
              event_patterns[event_name] = event_patterns[event_name] or {}
              table.insert(event_patterns[event_name], (Utils.convert_control_chars(pattern)))
            else
              table.insert(plain_events, e)
            end
          end
        end

        if #plain_events > 0 or next(event_patterns) or has_deferred then
          local group_name = "packard_load_" .. plugin.name
          local group = vim.api.nvim_create_augroup(group_name, { clear = true })

          -- Track stub for centralized cleanup
          _plugin_stubs[plugin.name] = _plugin_stubs[plugin.name] or { cleanups = {} }
          table.insert(_plugin_stubs[plugin.name].cleanups, function()
            pcall(vim.api.nvim_del_augroup_by_name, group_name)
          end)

          if #plain_events > 0 then
            --[[@diagnostic disable-next-line: param-type-mismatch]]
            vim.api.nvim_create_autocmd(plain_events, {
              group = group,
              once = true,
              callback = function()
                load_fn(plugin)
              end,
              desc = string.format("packard: load %s", plugin.name),
            })
          end

          -- Create separate autocmds for events with patterns
          for ev, pats in pairs(event_patterns) do
            for _, pat in ipairs(pats) do
              vim.api.nvim_create_autocmd(ev, {
                group = group,
                pattern = pat,
                once = true,
                callback = function()
                  load_fn(plugin)
                end,
                desc = string.format("packard: load %s", plugin.name),
              })
            end
          end

          if has_deferred then
            vim.api.nvim_create_autocmd("UIEnter", {
              group = group,
              once = true,
              callback = function()
                vim.schedule(function()
                  load_fn(plugin)
                end)
              end,
              desc = string.format("packard: load %s (deferred)", plugin.name),
            })
          end
        end
      end

      -- 4. Filetypes
      if plugin.ft then
        has_triggers = true
        local fts = type(plugin.ft) == "table" and plugin.ft or { plugin.ft }
        local group_name = "packard_ft_load_" .. plugin.name
        local group = vim.api.nvim_create_augroup(group_name, { clear = true })

        -- Track stub for centralized cleanup
        _plugin_stubs[plugin.name] = _plugin_stubs[plugin.name] or { cleanups = {} }
        table.insert(_plugin_stubs[plugin.name].cleanups, function()
          pcall(vim.api.nvim_del_augroup_by_name, group_name)
        end)

        vim.api.nvim_create_autocmd("FileType", {
          group = group,
          pattern = fts,
          once = true,
          callback = function()
            load_fn(plugin)
          end,
          desc = string.format("packard: load %s", plugin.name),
        })
      end

      -- Eager load if lazy=false, or if no triggers are defined
      -- (a plugin with no triggers and lazy=true would never load otherwise)
      if plugin.lazy == false or not has_triggers then
        load_fn(plugin)
      end
    end
  end
end

---@private
---Set up the colorscheme auto-load: a single ColorSchemePre autocmd that,
---on :colorscheme <name>, scans every plugin's install path for
---colors/<name>.{lua,vim} and triggers load_and_config on the first match.
---Matches lazy.nvim behavior exactly. Built-in Neovim colorschemes short-circuit.
---@param plugins table All plugins (for iteration)
---@param load_fn function load_and_config callable (single arg: plugin)
function M.setup_colorscheme_autoload(plugins, load_fn)
  local group = vim.api.nvim_create_augroup("packard_colorscheme", { clear = true })
  vim.api.nvim_create_autocmd("ColorSchemePre", {
    group = group,
    callback = function(event)
      local name = event.match
      if not name or name == "" then
        return
      end
      -- Short-circuit built-in Neovim colorschemes
      local builtins = vim.fn.getcompletion("", "color")
      if vim.tbl_contains(builtins, name) then
        return
      end
      -- Scan each unloaded plugin's install path
      for _, plugin in ipairs(plugins) do
        if not plugin._cond and not package.loaded["packard.plugins." .. plugin.name] then
          local base = Utils.get_plugin_path(plugin)
          for _, ext in ipairs({ "lua", "vim" }) do
            local path = base .. "/colors/" .. name .. "." .. ext
            if vim.uv and vim.uv.fs_stat and vim.uv.fs_stat(path) then
              load_fn(plugin)
              return
            end
          end
        end
      end
    end,
    desc = "packard: colorscheme autoload",
  })
end

return M
