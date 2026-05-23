local Parser = {}

---@class NormalizedPlugin
---@field owner_repo string
---@field name string
---@field url string
---@field branch string|nil
---@field minimum_release_age number
---@field lazy boolean
---@field priority number|nil
---@field config function|nil
---@field opts table|nil
---@field event string|string[]|table|nil
---@field cmd string|string[]|table|nil
---@field keys string|string[]|table|nil
---@field ft string|string[]|table|nil
---@field ai_review table|nil Per-plugin AI config override
---@field spec table Original spec fields

---Normalize plugin specs
---@param plugins table List of plugin specs from user
---@param defaults table|nil Global defaults
---@return NormalizedPlugin[]
function Parser.parse_all(plugins, defaults)
  defaults = defaults or {}
  local normalized = {}
  local seen = {}

  for i, spec in ipairs(plugins) do
    if type(spec) == "string" then
      spec = { spec }
    end

    if type(spec) ~= "table" then
      error(string.format("packard: plugin at index %d: expected string or table, got %s", i, type(spec)))
    end

    local source = spec[1]
    if type(source) ~= "string" then
      error(string.format("packard: plugin at index %d: missing 'owner/repo' string", i))
    end

    -- Check for SSH URLs early
    if source:match("^git@") or source:match("^ssh://") then
      error("packard: SSH URLs are not supported. Use HTTPS (public repos only).")
    end

    local owner_repo, name, url

    if source:match("^https?://") then
      -- It's a full URL
      url = source
      -- Try to extract owner/repo
      -- Matches: https://github.com/owner/repo or https://github.com/owner/repo.git
      local path = source:match("^https?://[^/]+/(.+)$")
      if path then
        owner_repo = path:gsub("%.git$", "")
      else
        error(string.format("packard: invalid plugin source '%s'. Expected 'owner/repo'.", source))
      end
    elseif source:match("^[^/]+/[^/]+$") then
      -- It's owner/repo
      owner_repo = source
      url = "https://github.com/" .. source .. ".git"
    else
      error(string.format("packard: invalid plugin source '%s'. Expected 'owner/repo'.", source))
    end

    if seen[owner_repo] then
      error(string.format("packard: duplicate plugin '%s' detected at index %d", owner_repo, i))
    end
    seen[owner_repo] = true

    -- Derive name
    name = spec.name or owner_repo:match("/([^/]+)$")
    if not name then
      error(string.format("packard: could not derive name for plugin '%s'", owner_repo))
    end

    -- Field extraction
    local branch = spec.branch

    local min_age = spec.minimum_release_age or defaults.minimum_release_age or 30
    if type(min_age) ~= "number" or min_age < 0 then
      error(string.format("packard: 'minimum_release_age' for '%s' must be a number (days)", owner_repo))
    end

    local lazy = spec.lazy
    if lazy == nil then
      lazy = true
    end

    table.insert(normalized, {
      owner_repo = owner_repo,
      name = name,
      url = url,
      branch = branch,
      minimum_release_age = min_age,
      lazy = lazy,
      priority = spec.priority,
      config = spec.config,
      opts = spec.opts,
      event = spec.event,
      cmd = spec.cmd,
      keys = spec.keys,
      ft = spec.ft,
      ai_review = spec.ai_review,
      spec = spec,
    })
  end

  return normalized
end

return Parser
