local Health = {}
local Lockfile = require("packard.lockfile")
local State = require("packard.state")
local Cooldown = require("packard.cooldown")
local Git = require("packard.git")
local Utils = require("packard.utils")

function Health.check()
  local packard = require("packard")
  local config = packard.config
  if not config then
    vim.health.error("packard.setup() has not been called")
    return
  end

  -- Configuration
  vim.health.start("Configuration")
  vim.health.ok(string.format("%d plugins declared in spec", #packard.plugins))
  vim.health.info(string.format("Global minimum_release_age: %d days", config.defaults.minimum_release_age or 30))
  if config.plugins_dir then
    local Loader = require("packard.loader")
    local resolved = Loader.resolve_path(config.plugins_dir)
    if vim.fn.isdirectory(resolved) == 1 then
      vim.health.ok(string.format("plugins_dir: %s", resolved))
    else
      vim.health.error(string.format("plugins_dir: %s (NOT FOUND)", resolved))
    end
  end

  -- Lockfile
  vim.health.start("Lockfile")
  local lock_data = Lockfile.read()
  local lock_count = 0
  for _ in pairs(lock_data) do
    lock_count = lock_count + 1
  end
  vim.health.ok(string.format("nvim-pack-lock.json: %d plugins tracked", lock_count))

  for _, plugin in ipairs(packard.plugins) do
    if not lock_data[plugin.name] then
      vim.health.warn(string.format("Plugin '%s' is in spec but not in lockfile", plugin.owner_repo))
    end
  end

  -- Pending Queue
  vim.health.start("Pending Queue")
  local s = State.read()
  local status = Cooldown.get_status(packard.plugins)
  local eligible = 0
  for _ in pairs(status.eligible) do
    eligible = eligible + 1
  end
  local cooldown = 0
  for _ in pairs(status.cooldown) do
    cooldown = cooldown + 1
  end

  vim.health.info(string.format("%d pending updates", eligible + cooldown))
  vim.health.info(string.format("%d eligible for review", eligible))
  vim.health.info(string.format("%d in cooldown", cooldown))

  local bl_count = 0
  for _, list in pairs(s.blacklist) do
    bl_count = bl_count + #list
  end
  vim.health.ok(string.format("%d blacklisted commit(s)", bl_count))

  -- AI Review
  vim.health.start("AI Review")
  if config.ai_review then
    local ai = config.ai_review
    vim.health.ok(string.format("AI Review configured (provider: %s, model: %s)", ai.provider, ai.model))
    if not ai.url then
      vim.health.error("ai_review.url is missing")
    end
    -- Check for curl
    if vim.fn.executable("curl") == 1 then
      vim.health.ok("curl is available")
    else
      vim.health.error("curl is NOT available (required for AI review)")
    end
  else
    vim.health.info("AI Review not configured")
  end

  -- Network
  vim.health.start("Network")
  if #packard.plugins == 0 then
    vim.health.info("No plugins configured (skipping network check)")
  elseif Git.check_network(packard.plugins[1].url, 2000) then
    vim.health.ok("Network available")
  else
    vim.health.warn("Network unavailable")
  end

  -- Plugins
  vim.health.start("Plugins")
  for _, plugin in ipairs(packard.plugins) do
    local path = Utils.get_plugin_path(plugin.name)
    if vim.fn.isdirectory(path) == 1 then
      vim.health.ok(string.format("'%s': installed", plugin.owner_repo))
    else
      vim.health.warn(string.format("'%s': directory missing at %s", plugin.owner_repo, path))
    end
  end

  -- Dependencies
  vim.health.start("Dependencies")
  local Deps = require("packard.deps")
  local available = Deps.build_available_set()
  local missing_count = 0

  for _, plugin in ipairs(packard.plugins) do
    local path = Utils.get_plugin_path(plugin.name)
    if vim.fn.isdirectory(path) == 1 then
      local requires = Deps.scan_requires(path)
      for module in pairs(requires) do
        local is_available = available[module]
        if not is_available then
          local parts = vim.split(module, "%.")
          if #parts > 1 and available[parts[1]] then
            is_available = true
          end
        end

        if not is_available then
          local owner_repo = Deps.KNOWN_MODULES[module]
          if not owner_repo then
            local parts = vim.split(module, "%.")
            if #parts > 1 then
              owner_repo = Deps.KNOWN_MODULES[parts[1]]
            end
          end

          if owner_repo then
            vim.health.ok(string.format("'%s' requires '%s' (auto-resolved to %s)", plugin.owner_repo, module, owner_repo))
          else
            vim.health.error(string.format("'%s' requires missing module '%s' (unresolvable)", plugin.owner_repo, module))
            missing_count = missing_count + 1
          end
        end
      end
    end
  end

  if missing_count == 0 then
    vim.health.ok("All runtime dependencies resolved or available")
  end
end

return Health
