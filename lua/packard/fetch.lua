local Git = require("packard.git")
local Utils = require("packard.utils")
local Lockfile = require("packard.lockfile")
local Fetch = {}

---@class FetchResult
---@field owner_repo string
---@field success boolean
---@field new_sha string|nil
---@field error string|nil
---@field anomaly boolean
---@field force_push boolean|nil

---Check if the installed commit is still in the fetched upstream history.
---This detects force-pushes that removed the pinned commit from the branch.
---@param plugin NormalizedPlugin
---@param result FetchResult
local function check_force_push(plugin, result)
  local installed_sha = Lockfile.get_installed_commit(plugin.name)
  if not installed_sha then
    return -- nothing to compare against (not tracked in lockfile)
  end

  -- Compare installed commit against whatever was just fetched
  local fp_check = vim
    .system(
      { "git", "merge-base", "--is-ancestor", installed_sha, "FETCH_HEAD" },
      { cwd = Utils.get_plugin_path(plugin.name) }
    )
    :wait()

  -- exit code 0 = ancestor, non-zero = not ancestor (force-push)
  if fp_check.code ~= 0 then
    result.anomaly = true
    result.force_push = true
    result.error =
      string.format("installed commit %s no longer in upstream history (force-push?)", installed_sha:sub(1, 7))
  end
end

---Check updates for a list of plugins in parallel
---@param plugins NormalizedPlugin[]
---@param on_progress function|nil function(current, total)
---@return FetchResult[]
function Fetch.check_all(plugins, on_progress)
  if #plugins == 0 then
    return {}
  end

  -- T-3.1.1: Network probe
  if not Git.check_network(plugins[1].url, 5000) then
    error("packard: network unreachable")
  end

  local total = #plugins
  local jobs = {}

  -- Pre-resolve default branches in parallel for plugins that don't have one specified
  local branch_jobs = {}
  for i, plugin in ipairs(plugins) do
    if not plugin.branch then
      branch_jobs[i] = vim.system({ "git", "ls-remote", "--symref", plugin.url, "HEAD" })
    end
  end

  local resolved_branches = {}
  for i, job in pairs(branch_jobs) do
    local obj = job:wait(5000)
    if obj.code == 0 then
      for line in obj.stdout:gmatch("[^\r\n]+") do
        local branch = line:match("^ref: refs/heads/(%S+)%s+HEAD$")
        if branch then
          resolved_branches[i] = branch
          break
        end
      end
    end
    resolved_branches[i] = resolved_branches[i] or "HEAD"
  end

  -- T-3.1.2: Batch spawn
  for i, plugin in ipairs(plugins) do
    local plugin_path = Utils.get_plugin_path(plugin.name)

    -- Skip plugins that are not installed on disk
    if vim.fn.isdirectory(plugin_path) == 0 then
      -- Will be handled in the collection loop below
      jobs[i] = { plugin = plugin, missing = true }
    else
      -- T-1.1.4: Resolve default branch if not specified
      local branch = plugin.branch or resolved_branches[i] or "HEAD"

      local job = vim.system({ "git", "fetch", "origin", branch }, {
        cwd = plugin_path,
      })
      jobs[i] = { job = job, plugin = plugin, branch = branch }
    end
  end

  local results = {}
  local completed = 0

  -- T-3.1.3: Result collection
  for i, item in ipairs(jobs) do
    local plugin = item.plugin
    local result = { owner_repo = plugin.owner_repo, success = false, anomaly = false }

    if item.missing then
      -- Plugin not installed on disk
      result.error = "not installed"
    else
      local obj = item.job:wait()

      if obj.code == 0 then
        -- Fetch succeeded, now get the SHA of the remote branch
        local branch = item.branch or "FETCH_HEAD"
        local sha_obj = vim
          .system({ "git", "rev-parse", "origin/" .. branch }, {
            cwd = Utils.get_plugin_path(plugin.name),
          })
          :wait()

        if sha_obj.code == 0 then
          result.success = true
          result.new_sha = sha_obj.stdout:gsub("%s+", "")
          -- Check if force-push removed the installed commit from history
          check_force_push(plugin, result)
        else
          -- Maybe it's not origin/branch but just FETCH_HEAD
          local fh_obj = vim
            .system({ "git", "rev-parse", "FETCH_HEAD" }, {
              cwd = Utils.get_plugin_path(plugin.name),
            })
            :wait()
          if fh_obj.code == 0 then
            result.success = true
            result.new_sha = fh_obj.stdout:gsub("%s+", "")
            -- Check if force-push removed the installed commit from history
            check_force_push(plugin, result)
          else
            result.error = "git rev-parse failed"
          end
        end
      else
        -- T-3.1.4: Error handling
        if obj.code == 128 then
          result.error = "upstream unreachable or repo gone"
          result.anomaly = true
        else
          result.error = "git fetch failed with code " .. obj.code
        end
      end
    end

    results[i] = result
    completed = completed + 1

    -- T-3.1.5: Progress reporting
    if on_progress then
      on_progress(completed, total)
    end
  end

  return results
end

return Fetch
