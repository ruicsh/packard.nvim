local State = {}

local state_path = vim.fs.joinpath(vim.fn.stdpath("state"), "packard-state.json")

---@class PendingEntry
---@field commit string
---@field tag string|nil
---@field discovered_at string ISO 8601

---@class UpdateLogEntry
---@field from string
---@field to string
---@field timestamp string ISO 8601

---@class PackardState
---@field queue table<string, PendingEntry> Keyed by owner_repo
---@field blacklist table<string, string[]> Keyed by owner_repo
---@field update_log table<string, UpdateLogEntry[]> Keyed by owner_repo

---@type PackardState|nil
State._cache = nil

---Initialize state path and directory
function State._init()
  local dir = vim.fn.fnamemodify(state_path, ":h")
  if vim.fn.isdirectory(dir) == 0 then
    --[[@diagnostic disable-next-line: redundant-parameter]]
    vim.fn.mkdir(dir, "p")
  end
end

---Check if state file exists
---@return boolean
function State.exists()
  return vim.fn.filereadable(state_path) == 1
end

---Read state from disk
---@return PackardState
function State.read()
  if State._cache then
    return State._cache
  end

  if vim.fn.filereadable(state_path) == 0 then
    State._cache = { queue = {}, blacklist = {}, update_log = {} }
    return State._cache
  end

  local f = io.open(state_path, "r")
  if not f then
    State._cache = { queue = {}, blacklist = {}, update_log = {} }
    return State._cache
  end

  local content = f:read("*a")
  f:close()

  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= "table" then
    State._cache = { queue = {}, blacklist = {}, update_log = {} }
    return State._cache
  end

  -- Ensure all fields exist
  decoded.queue = decoded.queue or {}
  decoded.blacklist = decoded.blacklist or {}
  decoded.update_log = decoded.update_log or {}

  State._cache = decoded
  return State._cache
end

---Write state to disk (atomic)
function State.write()
  if not State._cache then
    return
  end

  State._init()
  local temp_path = state_path .. ".tmp"
  local f = io.open(temp_path, "w")
  if not f then
    vim.notify("packard: could not open temp state file: " .. temp_path, vim.log.levels.ERROR)
    return
  end
  local ok, write_err = pcall(f.write, f, vim.json.encode(State._cache))
  f:close()
  if not ok then
    os.remove(temp_path)
    vim.notify("packard: state write failed: " .. tostring(write_err), vim.log.levels.ERROR)
    return
  end
  os.rename(temp_path, state_path)
end

---Log an update
---@param owner_repo string
---@param from string
---@param to string
---@param timestamp string|nil ISO 8601, defaults to now
function State.log_update(owner_repo, from, to, timestamp)
  local s = State.read()
  s.update_log[owner_repo] = s.update_log[owner_repo] or {}

  table.insert(s.update_log[owner_repo], 1, {
    from = from,
    to = to,
    timestamp = timestamp or os.date("!%Y-%m-%dT%H:%M:%SZ") --[[@as string]],
  })

  -- Cap at 10 per plugin
  if #s.update_log[owner_repo] > 10 then
    table.remove(s.update_log[owner_repo])
  end

  State.write()
end

-- Merge submodules
require("packard.state.pending")(State)
require("packard.state.ai_cache")(State)

---Invalidate the in-memory cache
function State.invalidate()
  State._cache = nil
  State._ai_cache = nil
end

return State
