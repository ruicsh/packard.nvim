local State = {}

local state_path = vim.fs.joinpath(vim.fn.stdpath("state"), "packard-state.json")
local ai_cache_path = vim.fs.joinpath(vim.fn.stdpath("state"), "packard-ai-cache.json")

---@class PendingEntry
---@field commit string
---@field discovered_at string ISO 8601

---@class UpdateLogEntry
---@field from string
---@field to string
---@field timestamp string ISO 8601

---@class AICacheEntry
---@field summary string
---@field risk string "Low"|"Medium"|"High"
---@field reasoning string
---@field cached_at string ISO 8601

---@class PackardState
---@field queue table<string, PendingEntry> Keyed by owner_repo
---@field blacklist table<string, string[]> Keyed by owner_repo
---@field update_log table<string, UpdateLogEntry[]> Keyed by owner_repo

---@type PackardState|nil
State._cache = nil
---@type table<string, AICacheEntry>|nil
State._ai_cache = nil

---Initialize state path and directory
function State._init()
  local dir = vim.fn.fnamemodify(state_path, ":h")
  if vim.fn.isdirectory(dir) == 0 then
    --[[@diagnostic disable-next-line: redundant-parameter]]
    vim.fn.mkdir(dir, "p")
  end
end

---Read AI cache from disk
---@return table<string, AICacheEntry>
function State.read_ai_cache()
  if State._ai_cache then
    return State._ai_cache
  end

  if vim.fn.filereadable(ai_cache_path) == 0 then
    State._ai_cache = {}
    return State._ai_cache
  end

  local f = io.open(ai_cache_path, "r")
  if not f then
    State._ai_cache = {}
    return State._ai_cache
  end

  local content = f:read("*a")
  f:close()

  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= "table" then
    State._ai_cache = {}
    return State._ai_cache
  end

  State._ai_cache = decoded
  return State._ai_cache
end

---Write AI cache to disk (atomic)
function State.write_ai_cache()
  if not State._ai_cache then
    return
  end

  State._init()
  local temp_path = ai_cache_path .. ".tmp"
  local f = io.open(temp_path, "w")
  if not f then
    error("packard: could not open temp AI cache file for writing: " .. temp_path)
  end

  f:write(vim.json.encode(State._ai_cache))
  f:close()

  os.rename(temp_path, ai_cache_path)
end

---Get AI cache entry
---@param owner_repo string
---@param from_sha string
---@param to_sha string
---@return AICacheEntry|nil
function State.get_ai_cache(owner_repo, from_sha, to_sha)
  local key = string.format("%s:%s:%s", owner_repo, from_sha, to_sha)
  return State.read_ai_cache()[key]
end

---Set AI cache entry
---@param owner_repo string
---@param from_sha string
---@param to_sha string
---@param result AICacheEntry
function State.set_ai_cache(owner_repo, from_sha, to_sha, result)
  local key = string.format("%s:%s:%s", owner_repo, from_sha, to_sha)
  State.read_ai_cache()[key] = result
  State.write_ai_cache()
end

---Invalidate the in-memory cache
function State.invalidate()
  State._cache = nil
  State._ai_cache = nil
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
    State._cache = {
      queue = {},
      blacklist = {},
      update_log = {},
    }
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
    error("packard: could not open temp state file for writing: " .. temp_path)
  end

  f:write(vim.json.encode(State._cache))
  f:close()

  os.rename(temp_path, state_path)
end

---Queue a pending update
---@param owner_repo string
---@param sha string
---@param timestamp string|nil ISO 8601, defaults to now
function State.queue_pending(owner_repo, sha, timestamp)
  local s = State.read()
  s.queue[owner_repo] = {
    commit = sha,
    discovered_at = timestamp or os.date("!%Y-%m-%dT%H:%M:%SZ") --[[@as string]],
  }
  State.write()
end

---Remove from queue
---@param owner_repo string
function State.dequeue(owner_repo)
  local s = State.read()
  s.queue[owner_repo] = nil
  State.write()
end

---Add to blacklist
---@param owner_repo string
---@param sha string
function State.blacklist(owner_repo, sha)
  local s = State.read()
  s.blacklist[owner_repo] = s.blacklist[owner_repo] or {}

  -- Check if already blacklisted
  for _, existing_sha in ipairs(s.blacklist[owner_repo]) do
    if existing_sha == sha then
      return
    end
  end

  table.insert(s.blacklist[owner_repo], sha)
  State.write()
end

---Check if commit is blacklisted
---@param owner_repo string
---@param sha string
---@return boolean
function State.is_blacklisted(owner_repo, sha)
  local s = State.read()
  local list = s.blacklist[owner_repo]
  if not list then
    return false
  end
  for _, blacklisted_sha in ipairs(list) do
    if blacklisted_sha == sha then
      return true
    end
  end
  return false
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

return State
