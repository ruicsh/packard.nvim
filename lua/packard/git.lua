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

return Git
