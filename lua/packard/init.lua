local M = {}
local Parser = require("packard.parser")
local Loader = require("packard.loader")
local Fetch = require("packard.fetch")
local Cooldown = require("packard.cooldown")
local Lockfile = require("packard.lockfile")
local State = require("packard.state")
local UI = require("packard.ui")

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
function M._bootstrap()
  local function build_pack_spec(plugin)
    -- Create the spec for vim.pack.add
    local pack_spec = {
      src = plugin.url,
      name = plugin.name,
      opt = plugin.lazy,
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
      local best = Semver.pick_best(tags, range)
      if best then
        pack_spec.version = best.tag
      elseif plugin.branch then
        pack_spec.version = plugin.branch
      end
    elseif plugin.branch then
      pack_spec.version = plugin.branch
    end

    -- T-1.2.1: Pass lazy-load fields to vim.pack.add
    if plugin.spec then
      for k, v in pairs(plugin.spec) do
        -- Don't overwrite what we already set (src, name, version, opt)
        -- Skip integer keys (like [1] = owner/repo) as they are not valid vim.pack fields
        if type(k) == "string" and pack_spec[k] == nil then
          pack_spec[k] = v
        end
      end
    end
    return pack_spec
  end

  -- Call Neovim's built-in pack manager
  if vim.pack and vim.pack.add then
    local failed = {}
    for _, plugin in ipairs(M.plugins) do
      local pack_spec = build_pack_spec(plugin)
      -- confirm=false because packard manages plugins programmatically:
      -- user opted in by listing them in packard.setup().  vim.pack.add
      -- defaults to confirm=true which prompts mid-startup and can hang
      -- or fail when run headless or from an init script.
      --[[@diagnostic disable-next-line: redundant-parameter]]
      local ok, err = pcall(vim.pack.add, { pack_spec }, { confirm = false })
      if not ok then
        local err_msg = tostring(err)
        table.insert(failed, { owner_repo = plugin.owner_repo, error = err_msg })
        -- Check for common git auth/network errors to set offline flag
        if err_msg:match("Username") or err_msg:match("Device not configured") or err_msg:match("network") then
          M._is_offline = true
        end
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
  -- Filter enabled = false and handle duplicates (last wins)
  local final_specs = {}
  local seen = {}

  for i = #plugins, 1, -1 do
    local p = plugins[i]
    if type(p) == "string" then
      p = { p }
    end
    local source = p[1]
    if source and not seen[source] then
      if p.enabled ~= false then
        table.insert(final_specs, 1, p)
      end
      seen[source] = true
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
