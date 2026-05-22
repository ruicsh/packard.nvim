local URL = {}

---Detect the forge from a git URL
---@param url string
---@return string|nil forge
function URL.detect_forge(url)
  if url:find("github.com") then
    return "github"
  elseif url:find("gitlab.com") then
    return "gitlab"
  elseif url:find("bitbucket.org") then
    return "bitbucket"
  end
  return nil
end

---Build a compare URL for GitHub
---@param owner string
---@param repo string
---@param from string
---@param to string
---@return string
function URL.build_github_compare(owner, repo, from, to)
  return string.format("https://github.com/%s/%s/compare/%s...%s", owner, repo, from, to)
end

---Build a compare URL for GitLab
---@param owner string
---@param repo string
---@param from string
---@param to string
---@return string
function URL.build_gitlab_compare(owner, repo, from, to)
  return string.format("https://gitlab.com/%s/%s/-/compare/%s...%s", owner, repo, from, to)
end

---Build a compare URL for Bitbucket
---@param owner string
---@param repo string
---@param from string
---@param to string
---@return string
function URL.build_bitbucket_compare(owner, repo, from, to)
  -- Bitbucket compare URL: https://bitbucket.org/<owner>/<repo>/branches/compare/<to>%0D<from>
  -- Note the reverse order and URL encoding of newline if using UI,
  -- but simple compare is: https://bitbucket.org/<owner>/<repo>/compare/<to>..<from>
  return string.format("https://bitbucket.org/%s/%s/compare/%s..%s", owner, repo, to, from)
end

---Build a compare URL for any supported forge
---@param remote_url string
---@param from_sha string
---@param to_sha string
---@return string|nil
function URL.build_compare_url(remote_url, from_sha, to_sha)
  local forge = URL.detect_forge(remote_url)
  if not forge then
    return nil
  end

  -- Extract owner and repo
  -- Assumes HTTPS URL: https://host.com/path/to/repo(.git)
  local path = remote_url:match("https?://[^/]+/(.+)$")
  if not path then
    return nil
  end
  path = path:gsub("%.git$", "")

  local parts = vim.split(path, "/")
  if #parts < 2 then
    return nil
  end

  local repo = parts[#parts]
  local owner = table.concat(parts, "/", 1, #parts - 1)

  if forge == "github" then
    return URL.build_github_compare(owner, repo, from_sha, to_sha)
  elseif forge == "gitlab" then
    return URL.build_gitlab_compare(owner, repo, from_sha, to_sha)
  elseif forge == "bitbucket" then
    return URL.build_bitbucket_compare(owner, repo, from_sha, to_sha)
  end

  return nil
end

return URL
