local State = require("packard.state")
local Cooldown = {}

---Register a new commit in the cooldown queue
---@param owner_repo string
---@param sha string
function Cooldown.register_commit(owner_repo, sha)
  -- Check blacklist first
  if State.is_blacklisted(owner_repo, sha) then
    return
  end

  -- Check if it's already installed (synced lockfile)
  -- We need the plugin name to check the lockfile
  -- The caller should ideally check this, but we can try to be safe.
  -- Actually, let's assume the caller checked the lockfile before calling register.

  -- Check if already in queue
  local s = State.read()
  local existing = s.queue[owner_repo]

  if existing then
    if existing.commit == sha then
      -- Already there
      return
    end
    -- Supersede: newer commit replaces older pending
    -- We keep the current timestamp as discovery for the NEW commit
  end

  State.queue_pending(owner_repo, sha)
end

---Check if a commit is eligible for review
---@param discovered_at string ISO 8601
---@param min_age_days number
---@return boolean eligible, number remaining_seconds
function Cooldown.check_eligibility(discovered_at, min_age_days)
  -- Parse ISO 8601 UTC timestamp
  -- Format: 2026-05-24T12:00:00Z
  local y, m, d, h, min, s = discovered_at:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)Z")
  if not y then
    return true, 0 -- Fallback for bad format
  end

  local discovered_time = os.time({
    year = tonumber(y) or 0,
    month = tonumber(m) or 1,
    day = tonumber(d) or 1,
    hour = tonumber(h) or 0,
    min = tonumber(min) or 0,
    sec = tonumber(s) or 0,
    isdst = false, -- UTC
  })

  -- `os.time()` returns local time if no table or if table doesn't specify.
  -- To get UTC time from `os.time()` with a table, it's tricky in Lua 5.1/JIT.
  -- Usually we should use `os.time(os.date("!*t"))` to get current UTC time.

  local now_utc = os.time(os.date("!*t") --[[@as osdateparam]])
  local age_seconds = now_utc - discovered_time
  local required_seconds = min_age_days * 86400

  local eligible = age_seconds >= required_seconds
  local remaining = math.max(0, required_seconds - age_seconds)

  return eligible, remaining
end

---Batch check eligibility for all pending commits
---@param plugins NormalizedPlugin[]
---@return table result { eligible: table<string, PendingEntry>, cooldown: table<string, {commit: string, remaining_days: number}> }
function Cooldown.get_status(plugins)
  local s = State.read()
  local result = { eligible = {}, cooldown = {} }

  -- Create a lookup for plugins by owner_repo to get min_age
  local plugin_map = {}
  for _, p in ipairs(plugins) do
    plugin_map[p.owner_repo] = p
  end

  for owner_repo, entry in pairs(s.queue) do
    local plugin = plugin_map[owner_repo]
    local min_age = plugin and plugin.minimum_release_age or 30

    local eligible, remaining = Cooldown.check_eligibility(entry.discovered_at, min_age)

    if eligible then
      result.eligible[owner_repo] = entry
    else
      result.cooldown[owner_repo] = {
        commit = entry.commit,
        remaining_days = math.ceil(remaining / 86400),
      }
    end
  end

  return result
end

return Cooldown
