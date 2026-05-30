local Semver = {}

---@class Version
---@field major number
---@field minor number
---@field patch number
---@field prerelease string|nil

---@class Range
---@field from Version
---@field to Version|nil
---@field include_prerelease boolean

---Parse a version string into a Version object
---@param str string
---@return Version|nil
function Semver.parse(str)
  if not str then
    return nil
  end
  -- strip 'v' prefix
  str = str:gsub("^v", "")

  local major, minor, patch, prerelease = str:match("^(%d+)%.(%d+)%.(%d+)(%-?.*)$")
  if not major then
    major, minor, prerelease = str:match("^(%d+)%.(%d+)(%-?.*)$")
    patch = 0
  end
  if not major then
    major, prerelease = str:match("^(%d+)(%-?.*)$")
    minor = 0
    patch = 0
  end

  if not major then
    return nil
  end

  if prerelease == "" then
    prerelease = nil
  end
  if prerelease and prerelease:sub(1, 1) == "-" then
    prerelease = prerelease:sub(2)
  end

  return setmetatable({
    major = tonumber(major),
    minor = tonumber(minor),
    patch = tonumber(patch),
    prerelease = prerelease,
  }, {
    __lt = Semver.lt,
    __eq = Semver.eq,
    __tostring = function(t)
      local s = string.format("%d.%d.%d", t.major, t.minor, t.patch)
      if t.prerelease then
        s = s .. "-" .. t.prerelease
      end
      return s
    end,
  })
end

function Semver.lt(a, b)
  if a.major ~= b.major then
    return a.major < b.major
  end
  if a.minor ~= b.minor then
    return a.minor < b.minor
  end
  if a.patch ~= b.patch then
    return a.patch < b.patch
  end
  if a.prerelease and not b.prerelease then
    return true
  end
  if not a.prerelease and b.prerelease then
    return false
  end
  if a.prerelease and b.prerelease then
    return a.prerelease < b.prerelease
  end
  return false
end

function Semver.eq(a, b)
  return a.major == b.major and a.minor == b.minor and a.patch == b.patch and a.prerelease == b.prerelease
end

---Convert a spec string to a Range
---@param spec string
---@return Range|nil
function Semver.to_range(spec)
  if spec == "*" then
    return { from = Semver.parse("0.0.0"), include_prerelease = false }
  end

  -- Caret ^1.2.3
  local caret = spec:match("%^(.+)")
  if caret then
    local v = Semver.parse(caret)
    if not v then
      return nil
    end
    local to = { major = v.major + 1, minor = 0, patch = 0 }
    return { from = v, to = to, include_prerelease = v.prerelease ~= nil }
  end

  -- Tilde ~1.2.3
  local tilde = spec:match("~(.+)")
  if tilde then
    local v = Semver.parse(tilde)
    if not v then
      return nil
    end
    local to = { major = v.major, minor = v.minor + 1, patch = 0 }
    return { from = v, to = to, include_prerelease = v.prerelease ~= nil }
  end

  -- GTE >=1.2.3
  local gte = spec:match("^>=%s*(.+)$")
  if gte then
    local v = Semver.parse(gte)
    if not v then
      return nil
    end
    return { from = v, include_prerelease = v.prerelease ~= nil }
  end

  -- GT >1.2.3
  local gt = spec:match("^>%s*(.+)$")
  if gt then
    local v = Semver.parse(gt)
    if not v then
      return nil
    end
    -- v+1.patch
    local from = { major = v.major, minor = v.minor, patch = v.patch + 1 }
    return { from = from, include_prerelease = false }
  end

  -- Bare version or wildcards
  local bare = spec:match("^=?%s*([%d%.%*x%-%.%a]+)$")
  if bare then
    local clean = bare:gsub("%.%*", ""):gsub("%.x", "")
    local v = Semver.parse(clean)
    if not v then
      return nil
    end

    if bare:match("^%d+$") or bare:match("^%d+%.%*$") or bare:match("^%d+%.x$") then
      -- "1" or "1.*" or "1.x"
      return { from = v, to = { major = v.major + 1, minor = 0, patch = 0 }, include_prerelease = false }
    elseif bare:match("^%d+%.%d+$") or bare:match("^%d+%.%d+%.%*$") or bare:match("^%d+%.%d+%.x$") then
      -- "1.2" or "1.2.*" or "1.2.x"
      return { from = v, to = { major = v.major, minor = v.minor + 1, patch = 0 }, include_prerelease = false }
    else
      -- "1.2.3" -> tilde
      return {
        from = v,
        to = { major = v.major, minor = v.minor + 1, patch = 0 },
        include_prerelease = v.prerelease ~= nil,
      }
    end
  end

  return nil
end

---Check if a version matches a range
---@param version Version
---@param range Range
---@return boolean
function Semver.match(version, range)
  -- Exclude prereleases unless explicitly requested
  if version.prerelease and not range.include_prerelease then
    return false
  end

  if Semver.lt(version, range.from) then
    return false
  end
  if range.to and not Semver.lt(version, range.to) then
    return false
  end

  return true
end

---Pick the best version from a list of tags
---@param tags {tag: string, sha: string}[]
---@param range Range
---@return {tag: string, sha: string}|nil
function Semver.pick_best(tags, range)
  local best = nil
  local best_v = nil

  for _, t in ipairs(tags) do
    local v = Semver.parse(t.tag)
    if v and Semver.match(v, range) then
      if not best_v or Semver.lt(best_v, v) then
        best = t
        best_v = v
      end
    end
  end

  return best
end

return Semver
