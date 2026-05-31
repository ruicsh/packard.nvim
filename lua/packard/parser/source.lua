local M = {}

---Parse a plugin source string into owner/repo, name, and URL.
---Raises errors for SSH URLs, invalid formats, and unnameable repos.
---@param source string The source string from spec[1]
---@param spec table The full spec table (used for spec.name)
---@return string owner_repo
---@return string name
---@return string url
function M.parse(source, spec)
  -- Reject SSH URLs early — public HTTPS only
  if source:match("^git@") or source:match("^ssh://") then
    error("packard: SSH URLs are not supported. Use HTTPS (public repos only).")
  end

  local owner_repo
  local url

  if source:match("^https?://") then
    -- Full URL
    url = source
    local path = source:match("^https?://[^/]+/(.+)$")
    if path then
      owner_repo = path:gsub("%.git$", "")
    else
      error(string.format("packard: invalid plugin source '%s'. Expected 'owner/repo'.", source))
    end
  elseif source:match("^[^/]+/[^/]+$") then
    -- owner/repo shorthand
    owner_repo = source
    url = "https://github.com/" .. source .. ".git"
  else
    error(string.format("packard: invalid plugin source '%s'. Expected 'owner/repo'.", source))
  end

  -- Derive name from spec.name or the repo portion of owner_repo
  local name = spec.name or owner_repo:match("/([^/]+)$")
  if not name then
    error(string.format("packard: could not derive name for plugin '%s'", owner_repo))
  end

  return owner_repo, name, url
end

return M
