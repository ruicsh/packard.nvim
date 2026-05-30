local Git = {}

---Resolve the default branch for a remote repository
---@param url string The HTTPS URL of the repository
---@param timeout number|nil Timeout in ms, defaults to 5000
---@return string|nil branch The name of the default branch (e.g., "main" or "master"), or nil on error
function Git.get_default_branch(url, timeout)
  timeout = timeout or 5000
  --[[@diagnostic disable-next-line: redundant-parameter]]
  local obj = vim.system({ "git", "ls-remote", "--symref", url, "HEAD" }):wait(timeout)
  if obj.code ~= 0 then
    return nil
  end

  -- Output format:
  -- ref: refs/heads/master	HEAD
  -- d043ad5d985a73e512727189f71c990b503612d6	HEAD
  for line in obj.stdout:gmatch("[^\r\n]+") do
    local branch = line:match("^ref: refs/heads/(%S+)%s+HEAD$")
    if branch then
      return branch
    end
  end

  return nil
end

---Check if network is available by probing a URL
---@param url string
---@param timeout number|nil Timeout in ms, defaults to 5000
---@return boolean
function Git.check_network(url, timeout)
  timeout = timeout or 5000
  --[[@diagnostic disable-next-line: redundant-parameter]]
  local obj = vim.system({ "git", "ls-remote", "--exit-code", url, "HEAD" }):wait(timeout)
  return obj.code == 0
end

---List tags for a remote repository
---@param url string
---@param timeout number|nil
---@return {tag: string, sha: string}[]
function Git.list_tags(url, timeout)
  timeout = timeout or 5000
  --[[@diagnostic disable-next-line: redundant-parameter]]
  local obj = vim.system({ "git", "ls-remote", "--tags", url }):wait(timeout)
  if obj.code ~= 0 then
    return {}
  end

  return Git.parse_ls_remote_tags(obj.stdout)
end

---Parse tags from git ls-remote --tags output
---@param stdout string
---@return {tag: string, sha: string}[]
function Git.parse_ls_remote_tags(stdout)
  local tags = {}
  local tag_map = {}

  for line in stdout:gmatch("[^\r\n]+") do
    local sha, ref = line:match("^(%x+)%s+(%S+)$")
    if sha and ref then
      local tag = ref:match("^refs/tags/(.+)$")
      if tag then
        local base_tag = tag:gsub("%^{}$", "")
        local is_deref = tag ~= base_tag

        if is_deref then
          tag_map[base_tag] = sha
        elseif not tag_map[tag] then
          tag_map[tag] = sha
        end
      end
    end
  end

  for tag, sha in pairs(tag_map) do
    table.insert(tags, { tag = tag, sha = sha })
  end

  return tags
end

return Git
