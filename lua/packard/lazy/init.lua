---@private
---Lazy loading subsystem: sets up keymap, command, event, and filetype triggers
---that load a plugin on first use, then run its config/opts.

local Utils = require("packard.utils")

local M = {}

---@private
---Load and configure a single plugin.
---@param plugin table NormalizedPlugin
---@param plugins table All plugins (for dependency resolution)
function M.load_and_config(plugin, plugins)
  if plugin._cond then
    return
  end
  if package.loaded["packard.plugins." .. plugin.name] then
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
  if plugin.is_local then
    -- Local plugins are outside packpath, so add dir to rtp directly
    vim.opt.rtp:prepend(plugin.dir)
  else
    -- bang=false for packadd ensures plugin/ and ftdetect/ are sourced
    pcall(vim.cmd.packadd, plugin.name)
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
    plugin.config(plugin, opts or {})
  elseif plugin.config == true or (plugin.config == nil and opts ~= nil) then
    -- Auto-config: lazy.nvim convention
    --   config = true → always calls require(MAIN).setup(opts or {})
    --   opts present + no config → calls require(MAIN).setup(opts or {})
    local modname = plugin.main or plugin.name:gsub("%.nvim$", "")
    local ok, mod = pcall(require, modname)
    if not ok and not plugin.main and modname ~= plugin.name then
      ok, mod = pcall(require, plugin.name)
    end
    if ok and type(mod) == "table" and type(mod.setup) == "function" then
      mod.setup(opts or {})
    end
  end
end

---@private
---Set up lazy-loading triggers for all plugins.
---@param plugins table All plugins
---@param load_fn function Function to call to load a plugin (single arg: plugin)
function M.setup_lazy_load(plugins, load_fn)
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
          local ok, result = pcall(resolved)
          if ok then
            resolved = result
          else
            resolved = nil
            vim.notify(
              string.format("packard: keys function error for '%s': %s", plugin.name, result),
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

              -- Capture locals for the closure
              local capture_lhs = lhs
              local capture_mode = mode
              local capture_rhs = rhs
              local capture_opts = real_map_opts

              vim.keymap.set(capture_mode, capture_lhs, function()
                -- Delete the stub
                pcall(vim.keymap.del, capture_mode, capture_lhs)
                -- Load the plugin
                load_fn(plugin)
                -- If user provided a RHS, set the real mapping and trigger it
                if capture_rhs then
                  vim.keymap.set(capture_mode, capture_lhs, capture_rhs, capture_opts)
                  -- Replay the keys
                  local feed = vim.api.nvim_replace_termcodes(capture_lhs, true, true, true)
                  vim.api.nvim_feedkeys(feed, "m", false)
                else
                  -- Load-only trigger, just replay the original keys
                  -- which might now be mapped by the plugin itself
                  local feed = vim.api.nvim_replace_termcodes(capture_lhs, true, true, true)
                  vim.api.nvim_feedkeys(feed, "m", false)
                end
              end, { desc = string.format("packard: load %s", plugin.name) })
            end
          end
        end
      end

      -- 2. Commands
      if plugin.cmd then
        has_triggers = true
        local cmds = type(plugin.cmd) == "table" and plugin.cmd or { plugin.cmd }
        for i = 1, #cmds do
          local cmd = cmds[i]
          -- Shadow the inner loop variable for closure capture
          local cmd = cmd
          vim.api.nvim_create_user_command(cmd, function(args)
            -- Delete all stub commands for this plugin
            for i2 = 1, #cmds do
              local c = cmds[i2]
              pcall(vim.api.nvim_del_user_command, c)
            end
            -- Load the plugin
            load_fn(plugin)
            -- Replay the command
            local bang = args.bang and "!" or ""
            vim.cmd(cmd .. bang .. " " .. args.args)
          end, {
            bang = true,
            nargs = "*",
            range = true,
            complete = function(_, line)
              -- Delete stubs to allow real completion if any
              for i2 = 1, #cmds do
                local c = cmds[i2]
                pcall(vim.api.nvim_del_user_command, c)
              end
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
          local group = vim.api.nvim_create_augroup("packard_load_" .. plugin.name, { clear = true })

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
        vim.api.nvim_create_autocmd("FileType", {
          group = vim.api.nvim_create_augroup("packard_ft_load_" .. plugin.name, { clear = true }),
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

return M
