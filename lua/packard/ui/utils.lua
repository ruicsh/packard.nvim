---Pure formatting utilities — no UI state dependency.

---@param timestamp string
---@return string
local function _format_age(timestamp)
  -- Parse ISO 8601 UTC timestamp
  -- Format: 2026-05-24 T 12:00:00Z
  local y, m, d, h, min, s = timestamp:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)Z")
  if not y then
    return ""
  end

  local t = os.time({
    year = tonumber(y) or 0,
    month = tonumber(m) or 1,
    day = tonumber(d) or 1,
    hour = tonumber(h) or 0,
    min = tonumber(min) or 0,
    sec = tonumber(s) or 0,
    isdst = false, -- UTC
  })
  -- DST note: same caveat as cooldown.lua. ±1 hour error at DST boundaries.
  -- Acceptable for display purposes.

  local now_utc = os.time(os.date("!*t") --[[@as osdateparam]])
  local diff = now_utc - t
  local days = math.floor(diff / 86400)

  if days == 0 then
    return "today"
  end
  if days == 1 then
    return "yesterday"
  end
  return days .. " days ago"
end

---Format a time difference in seconds as a short abbreviated string.
---Single-unit precision, right for columnar display.
---@param seconds number
---@return string
local function _format_age_abbreviated(seconds)
  if type(seconds) ~= "number" or seconds < 0 then
    return "?"
  end

  local minutes = math.floor(seconds / 60)
  local hours = math.floor(minutes / 60)
  local days = math.floor(hours / 24)

  if seconds < 60 then
    return "now"
  elseif minutes < 60 then
    return minutes .. "m"
  elseif hours < 24 then
    return hours .. "h"
  elseif days < 7 then
    return days .. "d"
  elseif days < 28 then
    local weeks = math.floor(days / 7)
    return weeks .. "w"
  elseif days < 365 then
    local months = math.max(1, math.floor(days / 30.44))
    return months .. "M"
  else
    local years = math.floor(days / 365.25)
    return years .. "y"
  end
end

return function(UI)
  UI._format_age = _format_age
  UI._format_age_abbreviated = _format_age_abbreviated
end
