local Build = require("packard.build")
local Lockfile = require("packard.lockfile")
local State = require("packard.state")
local UI = require("packard.ui")
local Utils = require("packard.utils")

local M = {}

---@private
---Bootstrap: register PackChanged handler, install plugins via vim.pack.add,
---run builds, auto-detect deps, and initialize state.
function M.bootstrap(ctx)
  local function build_pack_spec(plugin)
    -- Local plugins have no remote source; skip vim.pack.add
    if plugin.is_local then
      return nil
    end
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

  -- Look up entries in both Neovim 0.12 format (data.plugins[name])
  -- and legacy/mock format (data[name]).
  local function get_lockfile_entry(data, name)
    if data.plugins and data.plugins[name] then
      return data.plugins[name]
    end
    return data[name]
  end

  -- Snapshot which plugins are already on disk before installation.
  -- This lets us run build steps only for newly installed plugins.
  -- For local plugins, the dir must already exist.
  local pre_installed = {}
  for _, plugin in ipairs(ctx.plugins) do
    if plugin.is_local then
      pre_installed[plugin.name] = true
      if vim.fn.isdirectory(plugin.dir) == 0 then
        vim.notify(string.format("packard: local plugin dir does not exist: '%s'", plugin.dir), vim.log.levels.WARN)
      end
    else
      pre_installed[plugin.name] = vim.fn.isdirectory(Utils.get_plugin_path(plugin.name)) == 1
    end
  end

  -- Register the PackChanged autocommand BEFORE vim.pack.add() so it
  -- catches the install event on first run.  Neovim docs say:
  -- "Create an autocommand before vim.pack.add() that lists the plugin."
  -- The augroup uses clear=true so re-registration is safe.
  vim.api.nvim_create_autocmd("PackChanged", {
    group = vim.api.nvim_create_augroup("packard", { clear = true }),
    callback = function(ev)
      local plugin_name = ev.data.spec.name

      -- Only log SHA changes for updates (not initial installs).
      -- The read order is intentional: read old_lock from cache first
      -- (pre-update state), then invalidate so the next read goes to disk
      -- (post-update state).  This lets us compare before vs after.
      if ev.data.kind == "update" then
        local old_lock = Lockfile.read()
        Lockfile.invalidate()
        local new_lock = Lockfile.read()

        local old_entry = get_lockfile_entry(old_lock, plugin_name)
        local new_entry = get_lockfile_entry(new_lock, plugin_name)
        local old_sha = old_entry and (old_entry.rev or old_entry.ref)
        local new_sha = new_entry and (new_entry.rev or new_entry.ref)

        if old_sha and new_sha and old_sha ~= new_sha then
          -- Find owner_repo for this plugin name
          local owner_repo
          local plugin
          for _, p in ipairs(ctx.plugins) do
            if p.name == plugin_name then
              owner_repo = p.owner_repo
              plugin = p
              break
            end
          end

          if owner_repo then
            -- Avoid duplicate entries: skip if already logged for this transition
            local s = State.read()
            local logs = s.update_log[owner_repo] or {}
            local already_logged = false
            if #logs > 0 and logs[1].from == old_sha and logs[1].to == new_sha then
              already_logged = true
            end

            if not already_logged then
              State.log_update(owner_repo, old_sha, new_sha)
              State.dequeue(owner_repo)

              -- Run build step for the updated plugin
              if plugin and not plugin.is_local then
                local plugin_path = Utils.get_plugin_path(plugin)
                if plugin.build ~= nil or Build._get_build_file(plugin_path) then
                  Build.run(plugin)
                  plugin._has_build = true
                end
              end
            end
          end
        end
      else
        -- For installs and other events, just invalidate cache so the
        -- next Lockfile.read() picks up the newly-written lockfile.
        Lockfile.invalidate()
      end

      -- Refresh dashboard if open
      if UI.win and vim.api.nvim_win_is_valid(UI.win) then
        UI.render()
      end
    end,
  })

  -- Call Neovim's built-in pack manager
  -- Pass all specs in a single vim.pack.add() call so Neovim installs them
  -- in parallel with a unified progress indicator instead of one-by-one.
  if vim.pack and vim.pack.add then
    -- Build all specs upfront; skip local plugins
    local all_specs = {}
    for _, plugin in ipairs(ctx.plugins) do
      local pack_spec = build_pack_spec(plugin)
      if pack_spec then
        table.insert(all_specs, pack_spec)
      end
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
      if not plugin.is_local and not installed[plugin.name] then
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
  -- For local plugins, build steps run on every startup (always "fresh install").
  for _, plugin in ipairs(ctx.plugins) do
    if not pre_installed[plugin.name] or plugin.is_local then
      -- Plugin was just installed; check if it has a build step
      local plugin_path = Utils.get_plugin_path(plugin)
      if plugin.build ~= nil or Build._get_build_file(plugin_path) then
        Build.run(plugin)
      end
    end
  end

  -- Cache whether each plugin has a build step (avoids repeated filereadable calls in the UI).
  for _, plugin in ipairs(ctx.plugins) do
    local plugin_path = Utils.get_plugin_path(plugin)
    plugin._has_build = plugin.build ~= nil or Build._get_build_file(plugin_path) ~= nil
  end

  -- Auto-resolve undeclared dependencies
  local Deps = require("packard.deps")
  local new_deps = Deps.verify_and_install(ctx.plugins)
  if #new_deps > 0 then
    -- Add to tracked plugins for future update checks
    vim.list_extend(ctx.plugins, new_deps)
  end

  -- Persist initial state on first run so it's explicitly tracked
  if not State.exists() then
    State.read() -- Initialize in-memory cache with empty defaults
    State.write() -- Write packard-state.json to disk
  end
end

return M
