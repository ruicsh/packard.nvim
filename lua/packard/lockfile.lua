local Lockfile = {}

local lockfile_path = vim.fs.joinpath(vim.fn.stdpath("config"), "nvim-pack-lock.json")

---@class LockfileEntry
---@field src string URL
---@field ref string SHA
---@field rev string|nil
---@field version string|nil

Lockfile._cache = nil

---Read and parse the lockfile
---@return table<string, LockfileEntry> Keyed by plugin name
function Lockfile.read()
  if Lockfile._cache then
    return Lockfile._cache
  end

  if vim.fn.filereadable(lockfile_path) == 0 then
    -- Don't cache the empty result: the lockfile may appear after vim.pack.add()
    -- writes it, and caching would mask the update until invalidate() is called.
    return {}
  end

  local f = io.open(lockfile_path, "r")
  if not f then
    return {}
  end

  local content = f:read("*a")
  f:close()

  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= "table" then
    return {}
  end

  Lockfile._cache = decoded
  return Lockfile._cache
end

---Invalidate the in-memory cache
function Lockfile.invalidate()
  Lockfile._cache = nil
end

---Get the installed commit SHA for a plugin
---@param name string The plugin name (derived from repo or explicit)
---@return string|nil
function Lockfile.get_installed_commit(name)
  local data = Lockfile.read()

  -- Neovim 0.12 format: data.plugins[name].rev
  if data.plugins and data.plugins[name] then
    return data.plugins[name].rev or data.plugins[name].ref
  end

  -- Legacy/Mock format: data[name].ref
  if data[name] then
    return data[name].ref or data[name].rev
  end

  return nil
end

---Check if a plugin is tracked in the lockfile
---@param name string
---@return boolean
function Lockfile.has_plugin(name)
  local data = Lockfile.read()
  if data.plugins and data.plugins[name] then
    return true
  end
  return data[name] ~= nil
end

return Lockfile
