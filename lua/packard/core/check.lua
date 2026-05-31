local Cooldown = require("packard.cooldown")
local Fetch = require("packard.fetch")
local Lockfile = require("packard.lockfile")
local UI = require("packard.ui")

local M = {}

---@private
---Run update check for all plugins.
function M.check(ctx)
  if ctx._is_checking then
    print("packard: update check already in progress")
    return
  end
  ctx._is_checking = true
  UI.check_state = "running"
  UI.check_error_msg = nil

  print("packard: checking for updates...")

  local ok, results = pcall(Fetch.check_all, ctx.plugins, function(curr, total)
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
    UI.check_state = "error"
    UI.check_error_msg = tostring(results)
    if tostring(results):match("network unreachable") then
      ctx._is_offline = true
      print("packard: skipping update check (offline)")
    else
      print("packard: check failed: " .. tostring(results))
    end
    ctx._is_checking = false
    if UI.win and vim.api.nvim_win_is_valid(UI.win) then
      UI.render()
    end
    return
  end

  ctx._is_offline = false
  local new_count = 0
  for _, res in ipairs(results) do
    if res.success then
      -- Find plugin to get its name (for lockfile check) and min_age
      local plugin
      for _, p in ipairs(ctx.plugins) do
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

  local status = Cooldown.get_status(ctx.plugins)
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

  UI.check_state = "done"
  UI.check_new_count = new_count
  UI.check_eligible = eligible
  UI.check_cooldown = in_cooldown

  ctx._is_checking = false
  if UI.win and vim.api.nvim_win_is_valid(UI.win) then
    UI.render()
  end
end

return M
