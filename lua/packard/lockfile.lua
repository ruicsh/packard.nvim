local Lockfile = {}

local lockfile_path = vim.fs.joinpath(vim.fn.stdpath("config"), "nvim-pack-lock.json")

---@class LockfileEntry
---@field src string URL
---@field ref string SHA
---@field version string|nil

Lockfile._cache = nil

---Read and parse the lockfile
---@return table<string, LockfileEntry> Keyed by plugin name
function Lockfile.read()
  if Lockfile._cache then
    return Lockfile._cache
  end

  if vim.fn.filereadable(lockfile_path) == 0 then
    Lockfile._cache = {}
    return Lockfile._cache
  end

  local f = io.open(lockfile_path, "r")
  if not f then
    Lockfile._cache = {}
    return Lockfile._cache
  end

  local content = f:read("*a")
  f:close()

  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= "table" then
    Lockfile._cache = {}
    return Lockfile._cache
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
  if data[name] then
    return data[name].ref
  end
  return nil
end

---Check if a plugin is tracked in the lockfile
---@param name string
---@return boolean
function Lockfile.has_plugin(name)
  local data = Lockfile.read()
  return data[name] ~= nil
end

return Lockfile
