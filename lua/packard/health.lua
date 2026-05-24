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
  if Git.check_network(packard.plugins[1].url, 2000) then
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
end

return Health
