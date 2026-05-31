local M = {}
local Parser = require("packard.parser")
local Loader = require("packard.loader")
local Fetch = require("packard.fetch")
local Cooldown = require("packard.cooldown")
local Lockfile = require("packard.lockfile")
local State = require("packard.state")
local UI = require("packard.ui")
local Utils = require("packard.utils")

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
---Merge trigger fields from new_spec into existing_spec (raw spec tables).
---@param existing table Plugin spec already in final_specs
---@param new_spec table Duplicate plugin spec to merge triggers from
function M._merge_spec_triggers(existing, new_spec)
  local trigger_fields = { "keys", "cmd", "event", "ft" }
  for _, field in ipairs(trigger_fields) do
    local a = existing[field]
    local b = new_spec[field]
    if a and b then
      local merged = {}
      local seen = {}
      local function add(val)
        if val == nil then
          return
        end
        if type(val) == "string" then
          if not seen[val] then
            seen[val] = true
            table.insert(merged, val)
          end
        elseif type(val) == "table" then
          local key = vim.inspect(val)
          if not seen[key] then
            seen[key] = true
            table.insert(merged, val)
          end
        elseif type(val) == "function" then
          table.insert(merged, val)
        end
      end
      local function flatten(v)
        if type(v) == "table" then
          if v[1] ~= nil then
            for _, item in ipairs(v) do
              add(item)
            end
          elseif next(v) then
            add(v)
          end
        else
          add(v)
        end
      end
      flatten(a)
      flatten(b)
      existing[field] = merged
    elseif b then
      existing[field] = b
    end
  end
end

---@private
function M._load_and_config(plugin)
  if package.loaded["packard.plugins." .. plugin.name] then
    return
  end
  package.loaded["packard.plugins." .. plugin.name] = true

  -- Force-load dependencies first (even if lazy), matching lazy.nvim behavior.
  -- Without this, a deferred dependency (e.g. event="VeryLazy") would never run
  -- its config before an eager dependent that references it.
  if plugin.dependencies then
    for _, dep in ipairs(plugin.dependencies) do
      for _, p in ipairs(M.plugins) do
        if p.owner_repo == dep.owner_repo then
          M._load_and_config(p)
          break
        end
      end
    end
  end

  -- Load the plugin code
  -- bang=false for packadd ensures plugin/ and ftdetect/ are sourced
  pcall(vim.cmd.packadd, plugin.name)

  -- Resolve opts: lazy.nvim convention — opts can be a function returning a table
  local opts = plugin.opts
  if type(opts) == "function" then
    local ok, result = pcall(opts)
    if ok then
      opts = result
    else
      vim.notify(
        string.format("packard: opts function error for '%s': %s", plugin.name, result),
        vim.log.levels.ERROR
      )
      opts = {}
    end
  end

  -- Run config function if defined
  if plugin.config then
    if type(plugin.config) == "function" then
      plugin.config(plugin, opts or {})
    end
  elseif opts ~= nil then
    -- Auto-config: lazy.nvim convention — opts implies require("plugin").setup(opts)
    local modname = plugin.name:gsub("%.nvim$", "")
    local ok, mod = pcall(require, modname)
    if not ok and modname ~= plugin.name then
      ok, mod = pcall(require, plugin.name)
    end
    if ok and type(mod) == "table" and type(mod.setup) == "function" then
      mod.setup(opts)
    end
  end
end

---@private
function M._setup_lazy_load()
  for _, plugin in ipairs(M.plugins) do
    -- Shadow the loop variable so closures capture the per-iteration value,
    -- not the reused loop variable (Lua for-loop scoping semantics).
    local plugin = plugin
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
              M._load_and_config(plugin)
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
          M._load_and_config(plugin)
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
            M._load_and_config(plugin)
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
              M._load_and_config(plugin)
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
                M._load_and_config(plugin)
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
                M._load_and_config(plugin)
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
          M._load_and_config(plugin)
        end,
        desc = string.format("packard: load %s", plugin.name),
      })
    end

    -- Eager load if lazy=false, or if no triggers are defined
    -- (a plugin with no triggers and lazy=true would never load otherwise)
    if plugin.lazy == false or not has_triggers then
      M._load_and_config(plugin)
    end
  end
end

---@private
function M._bootstrap()
  local function build_pack_spec(plugin)
    -- Create the spec for vim.pack.add
    local pack_spec = {
      src = plugin.url,
      name = plugin.name,
      version = nil, -- Set below
      data = plugin.spec.data, -- Pass through user data if any
    }

    -- Priority: lockfile SHA > commit > tag > version > branch
    local locked_sha = Lockfile.get_installed_commit(plugin.name)
    if locked_sha then
      pack_spec.version = locked_sha
    elseif plugin.commit then
      pack_spec.version = plugin.commit
    elseif plugin.tag then
      pack_spec.version = plugin.tag
    elseif plugin.version then
      -- Resolve version constraint to a tag
      local Semver = require("packard.semver")
      local Git = require("packard.git")
      local tag_timeout = (M.config and M.config.defaults and M.config.defaults.tag_timeout) or 5000
      local tags = Git.list_tags(plugin.url, tag_timeout)
      local range = Semver.to_range(plugin.version)
      local best = range and Semver.pick_best(tags, range) or nil
      if best then
        pack_spec.version = best.tag
      elseif plugin.branch then
        pack_spec.version = plugin.branch
      end
    elseif plugin.branch then
      pack_spec.version = plugin.branch
    end

    return pack_spec
  end

  -- Call Neovim's built-in pack manager
  -- Pass all specs in a single vim.pack.add() call so Neovim installs them
  -- in parallel with a unified progress indicator instead of one-by-one.
  if vim.pack and vim.pack.add then
    -- Build all specs upfront
    local all_specs = {}
    for _, plugin in ipairs(M.plugins) do
      local pack_spec = build_pack_spec(plugin)
      table.insert(all_specs, pack_spec)
    end

    -- confirm=false because packard manages plugins programmatically:
    -- user opted in by listing them in packard.setup().  vim.pack.add
    -- defaults to confirm=true which prompts mid-startup and can hang
    -- or fail when run headless or from an init script.
    --[[@diagnostic disable-next-line: redundant-parameter]]
    local ok, err = pcall(vim.pack.add, all_specs, { confirm = false })

    -- Check for common git auth/network errors to set offline flag
    if not ok then
      local err_msg = tostring(err)
      if err_msg:match("Username") or err_msg:match("Device not configured") or err_msg:match("network") then
        M._is_offline = true
      end
    end

    -- Determine which plugins actually made it to disk.
    -- vim.pack.get() returns plugins successfully registered via vim.pack.add(),
    -- so any expected plugin missing from it failed during installation.
    local installed = {}
    for _, p in ipairs(vim.pack.get()) do
      installed[p.spec.name] = true
    end

    -- Parse per-plugin errors from the batch vim.pack.add() error.
    -- Neovim formats these as: `name`:\n<message> separated by blank lines.
    local batch_errors = {}
    if not ok then
      for name, msg in tostring(err):gmatch("`([^`]+)`:\n([^\n]+)") do
        batch_errors[name] = msg
      end
    end

    local failed = {}
    for _, plugin in ipairs(M.plugins) do
      if not installed[plugin.name] then
        table.insert(failed, {
          owner_repo = plugin.owner_repo,
          error = batch_errors[plugin.name] or "installation failed",
        })
      end
    end

    if #failed > 0 then
      local lines = {}
      for _, f in ipairs(failed) do
        table.insert(lines, string.format("  - %s: %s", f.owner_repo, f.error))
      end
      vim.notify(
        string.format(
          "packard: failed to install %d plugin(s):\n%s\nAlready-installed plugins will still load. Run :Packard check to retry.",
          #failed,
          table.concat(lines, "\n")
        ),
        vim.log.levels.ERROR
      )
    end
  end

  -- Auto-resolve undeclared dependencies
  local Deps = require("packard.deps")
  local new_deps = Deps.verify_and_install(M.plugins)
  if #new_deps > 0 then
    -- Add to tracked plugins for future update checks
    vim.list_extend(M.plugins, new_deps)
  end

  -- Persist initial state on first run so it's explicitly tracked
  if not State.exists() then
    State.read() -- Initialize in-memory cache with empty defaults
    State.write() -- Write packard-state.json to disk
  end

  -- T-1.2.3: Implement PackChanged autocommand registration
  vim.api.nvim_create_autocmd("User", {
    pattern = "PackChanged",
    group = vim.api.nvim_create_augroup("packard", { clear = true }),
    callback = function()
      local old_lock = Lockfile.read()
      Lockfile.invalidate()
      local new_lock = Lockfile.read()

      -- Detect changes and update log
      for name, new_entry in pairs(new_lock) do
        local old_entry = old_lock[name]
        if old_entry and old_entry.ref ~= new_entry.ref then
          -- SHA changed
          -- Find owner_repo for this name
          local owner_repo
          for _, p in ipairs(M.plugins) do
            if p.name == name then
              owner_repo = p.owner_repo
              break
            end
          end

          if owner_repo then
            -- We only log if it's NOT already in the log for this exact from->to transition
            -- (to avoid duplicate entries if both UI and PackChanged log it)
            -- Actually, it's safer to just log it here and remove logging from UI.handle_approve
            -- but UI.handle_approve does dequeueing too.
            -- Let's check if it's already logged.
            local s = State.read()
            local logs = s.update_log[owner_repo] or {}
            local already_logged = false
            if #logs > 0 and logs[1].from == old_entry.ref and logs[1].to == new_entry.ref then
              already_logged = true
            end

            if not already_logged then
              State.log_update(owner_repo, old_entry.ref, new_entry.ref)
              -- If it was in the queue, dequeue it
              State.dequeue(owner_repo)
            end
          end
        end
      end

      -- T-6.4: Refresh dashboard if open
      if UI.win and vim.api.nvim_win_is_valid(UI.win) then
        UI.render()
      end
    end,
  })
end

---@private
function M._register_commands()
  vim.api.nvim_create_user_command("Packard", function(opts)
    local sub = opts.fargs[1]
    if not sub or sub == "" then
      UI.open(M.plugins, "installed", M._is_offline)
    elseif sub == "check" then
      M.check()
    elseif sub == "review" then
      UI.open(M.plugins, "pending", M._is_offline)
    elseif sub == "summary" then
      UI.open(M.plugins, "summary", M._is_offline)
    elseif sub == "clean" then
      UI.open(M.plugins, "clean", M._is_offline)
    elseif sub == "help" then
      UI.open(M.plugins, "help", M._is_offline)
    else
      print("packard: unknown subcommand '" .. sub .. "'")
    end
  end, {
    nargs = "?",
    complete = function(_, line)
      local l = vim.split(line, "%s+")
      local n = #l
      if n == 2 then
        local candidates = { "check", "review", "summary", "clean", "help" }
        local res = {}
        for _, c in ipairs(candidates) do
          if c:sub(1, #l[2]) == l[2] then
            table.insert(res, c)
          end
        end
        return res
      end
    end,
  })
end

---Initialize packard.nvim
---@param opts table
function M.setup(opts)
  -- NFR-003: Neovim version guard
  --[[@diagnostic disable-next-line: undefined-field]]
  if vim.version.lt(vim.version(), { 0, 12, 0 }) then
    error("packard requires Neovim >= 0.12")
  end

  if type(opts) ~= "table" then
    error(string.format("packard.setup: expected a table, got %s", type(opts)))
  end

  local plugins = {}
  local file_specs = {}

  if opts.plugins_dir then
    if type(opts.plugins_dir) ~= "string" then
      error("packard.setup: 'plugins_dir' must be a string")
    end
    local errors, warnings
    file_specs, errors, warnings = Loader.scan_all(opts.plugins_dir)

    if #errors > 0 then
      vim.notify(
        string.format("packard: %d spec file(s) failed to load:\n%s", #errors, table.concat(errors, "\n")),
        vim.log.levels.WARN
      )
    end
    if #warnings > 0 then
      vim.notify(
        string.format(
          "packard: %d spec file(s) returned non-table values and were skipped:\n%s",
          #warnings,
          table.concat(warnings, "\n")
        ),
        vim.log.levels.WARN
      )
    end
  end

  if opts.plugins then
    if type(opts.plugins) ~= "table" then
      error("packard.setup: 'plugins' must be a table")
    end
    -- Merge: file specs first, then inline
    -- Deduplication happens by owner_repo later in Parser.parse_all
    -- but we want to ensure inline wins on duplicates if we did it here.
    -- Actually Parser.parse_all raises error on duplicate.
    -- SPEC FR-039 says "inline wins. No duplicate error is raised."
    -- So we need to handle deduplication here or modify Parser.
    vim.list_extend(plugins, file_specs)
    vim.list_extend(plugins, opts.plugins)
  else
    plugins = file_specs
  end

  if #plugins == 0 and not opts.plugins_dir and not opts.plugins then
    error("packard.setup: at least one of 'plugins' or 'plugins_dir' must be provided")
  end

  local defaults = opts.defaults or {}
  if type(defaults) ~= "table" then
    error("packard.setup: 'defaults' must be a table")
  end

  if defaults.minimum_release_age ~= nil then
    if type(defaults.minimum_release_age) ~= "number" or defaults.minimum_release_age < 0 then
      error("packard.setup: 'defaults.minimum_release_age' must be a non-negative number")
    end
  end

  M.config = {
    defaults = defaults,
    plugins = opts.plugins,
    plugins_dir = opts.plugins_dir,
    ai_review = opts.ai_review,
    highlights = opts.highlights,
  }

  -- T-1.3.2: Include packard itself if not disabled
  -- Merge trigger fields (keys, cmd, event, ft) from duplicate specs.
  -- Non-trigger fields: last occurrence wins (so inline wins over file specs).
  local final_specs = {}
  local seen = {}

  for i = 1, #plugins do
    local p = plugins[i]
    if type(p) == "string" then
      p = { p }
    end
    local source = p[1]
    if source then
      if p.enabled == false then
        -- Drop disabled spec; also remove existing entry if present
        if seen[source] then
          -- Remove from final_specs
          local idx
          for j = 1, #final_specs do
            if final_specs[j][1] == source then
              idx = j
              break
            end
          end
          if idx then
            table.remove(final_specs, idx)
          end
          seen[source] = nil
        end
      elseif not seen[source] then
        table.insert(final_specs, p)
        seen[source] = p
      else
        -- Duplicate found: merge trigger fields, override non-trigger fields with later spec
        local existing = seen[source]
        M._merge_spec_triggers(existing, p)
        -- Non-trigger fields: later spec wins (so inline wins over file specs)
        local non_trigger = {
          "branch",
          "version",
          "tag",
          "commit",
          "minimum_release_age",
          "lazy",
          "priority",
          "config",
          "ai_review",
        }
        for _, field in ipairs(non_trigger) do
          if p[field] ~= nil then
            existing[field] = p[field]
          end
        end
        -- opts is deep-merged: all duplicate specs' submodule configs compose together
        -- (e.g. snacks.picker + snacks.zen both contribute to the final opts table)
        if p.opts ~= nil then
          if type(existing.opts) == "table" and type(p.opts) == "table" then
            existing.opts = vim.tbl_deep_extend("force", existing.opts, p.opts)
          else
            -- Non-table opts (e.g. functions): fall back to last-wins
            existing.opts = p.opts
          end
        end
      end
    end
  end

  if opts.self_management ~= false then
    local found = false
    for _, p in ipairs(final_specs) do
      local source = type(p) == "string" and p or p[1]
      if source:match("ruicsh/packard.nvim") then
        found = true
        break
      end
    end
    if not found then
      table.insert(final_specs, 1, "ruicsh/packard.nvim")
    end
  end

  M.plugins = Parser.parse_all(final_specs, defaults)
  if #M.plugins == 0 then
    print("packard: no plugins declared. Add plugins to packard.setup().")
    return M
  end

  -- Share config with UI
  UI.config = M.config

  M._bootstrap()
  M._setup_lazy_load()
  M._register_commands()

  -- T-7.1: Startup notification
  if opts.notifications ~= false then
    vim.schedule(function()
      local status = Cooldown.get_status(M.plugins)
      local count = 0
      for _ in pairs(status.eligible) do
        count = count + 1
      end
      if count > 0 then
        vim.notify(
          string.format("packard: %d plugins eligible for review. Run :Packard review", count),
          vim.log.levels.INFO
        )
      end
    end)
  end

  return M
end

---Run update check for all plugins
function M.check()
  if M._is_checking then
    print("packard: update check already in progress")
    return
  end
  M._is_checking = true

  print("packard: checking for updates...")

  local ok, results = pcall(Fetch.check_all, M.plugins, function(curr, total)
    if UI.win and vim.api.nvim_win_is_valid(UI.win) then
      UI.set_progress(curr, total, "fetching...")
    end
    if curr % 5 == 0 or curr == total then
      print(string.format("packard: fetched %d/%d...", curr, total))
    end
  end)

  if UI.win and vim.api.nvim_win_is_valid(UI.win) then
    UI.set_progress(0, 0)
  end

  if not ok then
    if tostring(results):match("network unreachable") then
      M._is_offline = true
      print("packard: skipping update check (offline)")
    else
      print("packard: check failed: " .. tostring(results))
    end
    M._is_checking = false
    if UI.win and vim.api.nvim_win_is_valid(UI.win) then
      UI.render()
    end
    return
  end

  M._is_offline = false
  local new_count = 0
  for _, res in ipairs(results) do
    if res.success then
      -- Find plugin to get its name (for lockfile check) and min_age
      local plugin
      for _, p in ipairs(M.plugins) do
        if p.owner_repo == res.owner_repo then
          plugin = p
          break
        end
      end

      if plugin then
        local installed = Lockfile.get_installed_commit(plugin.name)
        local target_sha
        local target_tag

        if plugin.commit or plugin.tag then
          -- Pinned to specific commit or tag, no auto-updates
        elseif plugin.version then
          target_sha = res.tag_sha
          target_tag = res.new_tag
        else
          target_sha = res.new_sha
        end

        if target_sha and installed ~= target_sha then
          Cooldown.register_commit(plugin.owner_repo, target_sha, target_tag)
          new_count = new_count + 1
        end
      end
    elseif res.anomaly then
      print(string.format("packard: anomaly detected for %s: %s", res.owner_repo, res.error))
    end
  end

  local status = Cooldown.get_status(M.plugins)
  local eligible = 0
  for _ in pairs(status.eligible) do
    eligible = eligible + 1
  end
  local in_cooldown = 0
  for _ in pairs(status.cooldown) do
    in_cooldown = in_cooldown + 1
  end

  print(
    string.format(
      "packard: done. %d new commits queued (%d in cooldown, %d eligible).",
      new_count,
      in_cooldown,
      eligible
    )
  )

  M._is_checking = false
  if UI.win and vim.api.nvim_win_is_valid(UI.win) then
    UI.render()
  end
end

return M
