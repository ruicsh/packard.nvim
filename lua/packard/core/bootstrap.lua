local Build = require("packard.build")
local Lockfile = require("packard.lockfile")
local State = require("packard.state")
local UI = require("packard.ui")
local Utils = require("packard.utils")

local M = {}

---@private
---Bootstrap: install plugins via vim.pack.add, run builds, auto-detect deps,
---initialize state, and wire up the PackChanged autocommand.
function M.bootstrap(ctx)
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
      local tag_timeout = (ctx.config and ctx.config.defaults and ctx.config.defaults.tag_timeout) or 5000
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

  -- Snapshot which plugins are already on disk before installation.
  -- This lets us run build steps only for newly installed plugins.
  local pre_installed = {}
  for _, plugin in ipairs(ctx.plugins) do
    pre_installed[plugin.name] = vim.fn.isdirectory(Utils.get_plugin_path(plugin.name)) == 1
  end

  -- Call Neovim's built-in pack manager
  -- Pass all specs in a single vim.pack.add() call so Neovim installs them
  -- in parallel with a unified progress indicator instead of one-by-one.
  if vim.pack and vim.pack.add then
    -- Build all specs upfront
    local all_specs = {}
    for _, plugin in ipairs(ctx.plugins) do
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
        ctx._is_offline = true
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
    for _, plugin in ipairs(ctx.plugins) do
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

  -- Run build steps for newly installed plugins.
  -- Only run build if the plugin directory didn't exist before vim.pack.add()
  -- (i.e., it was just freshly installed). This avoids re-running build on
  -- every startup for already-installed plugins.
  for _, plugin in ipairs(ctx.plugins) do
    if not pre_installed[plugin.name] then
      -- Plugin was just installed; check if it has a build step
      if plugin.build ~= nil or Build._get_build_file(Utils.get_plugin_path(plugin.name)) then
        Build.run(plugin)
      end
    end
  end

  -- Cache whether each plugin has a build step (avoids repeated filereadable calls in the UI).
  for _, plugin in ipairs(ctx.plugins) do
    plugin._has_build = plugin.build ~= nil or Build._get_build_file(Utils.get_plugin_path(plugin.name)) ~= nil
  end

  -- Auto-resolve undeclared dependencies
  local Deps = require("packard.deps")
  local new_deps = Deps.verify_and_install(ctx.plugins)
  if #new_deps > 0 then
    -- Add to tracked plugins for future update checks
    vim.list_extend(ctx.plugins, new_deps)
    -- Run init functions for any newly discovered dependencies.
    -- verify_and_install() returns synthetic plugins with no user-provided init
    -- today, so this call is a no-op. Kept for future-proofing if the dep
    -- system ever supports user-provided init fields in dependency specs.
    ctx._run_init_functions(new_deps)
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
          for _, p in ipairs(ctx.plugins) do
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

              -- Run build step for the updated plugin
              for _, p in ipairs(ctx.plugins) do
                if p.name == name then
                  local plugin_path = Utils.get_plugin_path(p.name)
                  if p.build ~= nil or Build._get_build_file(plugin_path) then
                    Build.run(p)
                    -- Refresh the cache so the UI indicator stays accurate.
                    p._has_build = true
                  end
                  break
                end
              end
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

return M
