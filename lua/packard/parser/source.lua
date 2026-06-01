local Utils = require("packard.utils")

local M = {}

---Parse a remote plugin source string (owner/repo or URL).
---@param source string
---@param spec table
---@return string owner_repo, string name, string url
local function parse_remote(source, spec)
  if source:match("^git@") or source:match("^ssh://") then
    error("packard: SSH URLs are not supported. Use HTTPS (public repos only).")
  end
  local owner_repo
  local url
  if source:match("^https?://") then
    url = source
    local path = source:match("^https?://[^/]+/(.+)$")
    if path then
      owner_repo = path:gsub("%.git$", "")
    else
      error(string.format("packard: invalid plugin source '%s'. Expected 'owner/repo'.", source))
    end
  elseif source:match("^[^/]+/[^/]+$") then
    owner_repo = source
    url = "https://github.com/" .. source .. ".git"
  else
    error(string.format("packard: invalid plugin source '%s'. Expected 'owner/repo'.", source))
  end
  local name = spec.name or owner_repo:match("/([^/]+)$")
  if not name then
    error(string.format("packard: could not derive name for plugin '%s'", owner_repo))
  end
  return owner_repo, name, url
end

---Parse a local plugin spec (dir field only).
---@param spec table
---@return string owner_repo, string name, nil url
local function parse_local(spec)
  local dir = spec.dir
  local plugin_dir = Utils.norm(dir)
  local name = spec.name or Utils.path_name(dir)
  if name == "" then
    error(string.format("packard: could not derive a valid plugin name from dir '%s'", dir))
  end
  return plugin_dir, name, nil
end

---Parse a plugin source.
---If `source` (the [1] string) is nil and `spec.dir` is provided, treats the
---plugin as a local filesystem plugin.  If both source and dir are provided,
---raises an error.
---@param source string|nil
---@param spec table
---@return string owner_repo, string name, string|nil url, boolean is_local
function M.parse(source, spec)
  if source then
    if spec.dir then
      error(string.format("packard: plugin '%s': 'dir' and a remote source cannot both be specified", source))
    end
    local owner_repo, name, url = parse_remote(source, spec)
    return owner_repo, name, url, false
  elseif spec.dir then
    local owner_repo, name = parse_local(spec)
    return owner_repo, name, nil, true
  else
    error("packard: plugin: missing 'owner/repo' string or 'dir' field")
  end
end

return M
