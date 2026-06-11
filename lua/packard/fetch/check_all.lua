local Git = require("packard.git")
local Utils = require("packard.utils")
local Lockfile = require("packard.lockfile")
local Semver = require("packard.semver")

---@class FetchResult
---@field owner_repo string
---@field success boolean
---@field new_sha string|nil
---@field new_tag string|nil
---@field tag_sha string|nil
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
    .system({ "git", "merge-base", "--is-ancestor", installed_sha, "FETCH_HEAD" }, { cwd = Utils.get_plugin_path(plugin) })
    :wait()

  -- exit code 0 = ancestor, 1 = not ancestor (force-push), other = git error
  if fp_check.code == 1 then
    result.anomaly = true
    result.force_push = true
    result.error =
      string.format("installed commit %s no longer in upstream history (force-push?)", installed_sha:sub(1, 7))
  elseif fp_check.code ~= 0 then
    result.anomaly = true
    result.error = "force-push check failed: " .. (fp_check.stderr or "unknown error")
  end
end

---Check updates for a list of plugins in parallel
---@param plugins NormalizedPlugin[]
---@param on_progress function|nil function(current, total)
---@return FetchResult[]
local function check_all(plugins, on_progress)
  if #plugins == 0 then
    return {}
  end

  -- T-3.1.1: Network probe (skip if all plugins are local)
  local first_remote
  for _, p in ipairs(plugins) do
    if not p.is_local then
      first_remote = p
      break
    end
  end
  if first_remote and not Git.check_network(first_remote.url, 5000) then
    error("packard: network unreachable")
  end

  local total = #plugins
  local jobs = {}

  -- Pre-resolve default branches and tags in parallel (skip local plugins)
  local branch_jobs = {}
  local tag_jobs = {}
  for i, plugin in ipairs(plugins) do
    if plugin.is_local then
      -- No remote operations for local plugins
    elseif not plugin.branch and not plugin.version then
      branch_jobs[i] = vim.system({ "git", "ls-remote", "--symref", plugin.url, "HEAD" })
    elseif plugin.version and not plugin.branch then
      -- S2: Combine ls-remote calls for default branch and tags
      tag_jobs[i] = vim.system({ "git", "ls-remote", "--symref", "--tags", plugin.url })
    elseif plugin.version then
      tag_jobs[i] = vim.system({ "git", "ls-remote", "--tags", plugin.url })
    end
  end

  local resolved_branches = {}
  for i, job in pairs(branch_jobs) do
    local obj = job:wait(5000)
    if obj and obj.code == 0 then
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
    if plugin.is_local then
      -- Local plugins have no remote to fetch; treat as up-to-date
      jobs[i] = { plugin = plugin, is_local = true }
    elseif plugin.pin then
      -- Pinned plugins are skipped during updates
      jobs[i] = { plugin = plugin, is_pinned = true }
    else
      local plugin_path = Utils.get_plugin_path(plugin)

      -- Skip plugins that are not installed on disk
      if vim.fn.isdirectory(plugin_path) == 0 then
        -- Will be handled in the collection loop below
        jobs[i] = { plugin = plugin, missing = true }
      elseif plugin.version then
        -- S1: For version-tracked plugins, we also need to fetch tags to ensure
        -- git objects are present and for force-push checking.
        local job = vim.system({ "git", "fetch", "--tags", "origin" }, {
          cwd = plugin_path,
        })
        jobs[i] = { job = job, plugin = plugin, is_version = true }
      else
        -- T-1.1.4: Resolve default branch if not specified
        local branch = plugin.branch or resolved_branches[i] or "HEAD"

        local job = vim.system({ "git", "fetch", "origin", branch }, {
          cwd = plugin_path,
        })
        jobs[i] = { job = job, plugin = plugin, branch = branch }
      end
    end
  end

  local results = {}
  local completed = 0

  -- T-3.1.3: Result collection
  for i, item in ipairs(jobs) do
    local plugin = item.plugin
    local result = { owner_repo = plugin.owner_repo, success = false, anomaly = false }

    if item.is_local then
      -- Local plugin: no remote to fetch, always up-to-date
      result.success = true
    elseif item.is_pinned then
      -- Pinned plugin: skip check, always up-to-date
      result.success = true
    elseif item.missing then
      -- Plugin not installed on disk
      result.error = "not installed"
    elseif item.is_version then
      -- S1: Version-tracked plugin, wait for fetch then resolve tags
      local obj = item.job:wait()
      if obj.code == 0 then
        if plugin.version and tag_jobs[i] then
          local tag_obj = tag_jobs[i]:wait(5000)
          if tag_obj and tag_obj.code == 0 then
            local tags = Git.parse_ls_remote_tags(tag_obj.stdout)
            local range = Semver.to_range(plugin.version)
            local best = range and Semver.pick_best(tags, range) or nil
            if best then
              result.success = true
              result.new_tag = best.tag
              result.tag_sha = best.sha
              -- Check if force-push removed the installed commit from history
              check_force_push(plugin, result)
            else
              result.error = "no matching version found"
            end
          else
            result.error = "git ls-remote --tags failed"
          end
        else
          result.error = "internal error: no tag job for version-tracked plugin"
          result.anomaly = true
        end
      else
        if obj.code == 128 then
          result.error = "upstream unreachable or repo gone"
          result.anomaly = true
        else
          result.error = "git fetch --tags failed with code " .. obj.code
        end
      end
    else
      local obj = item.job:wait()

      if obj.code == 0 then
        -- Fetch succeeded, now get the SHA of the remote branch
        local branch = item.branch or "FETCH_HEAD"
        local sha_obj = vim
          .system({ "git", "rev-parse", "origin/" .. branch }, {
            cwd = Utils.get_plugin_path(plugin),
          })
          :wait()

        if sha_obj.code == 0 then
          result.success = true
          result.new_sha = sha_obj.stdout:gsub("%s+", "")
          -- Check if force-push removed the installed commit from history
          -- Only applicable for branch-tracked plugins (no version constraint)
          if not plugin.version then
            check_force_push(plugin, result)
          end
        else
          -- Maybe it's not origin/branch but just FETCH_HEAD
          local fh_obj = vim
            .system({ "git", "rev-parse", "FETCH_HEAD" }, {
              cwd = Utils.get_plugin_path(plugin),
            })
            :wait()
          if fh_obj.code == 0 then
            result.success = true
            result.new_sha = fh_obj.stdout:gsub("%s+", "")
            -- Check if force-push removed the installed commit from history
            if not plugin.version then
              check_force_push(plugin, result)
            end
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

return {
  check_all = check_all,
}
