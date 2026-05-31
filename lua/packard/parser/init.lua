local Source = require("packard.parser.source")
local Validate = require("packard.parser.validate")
local Deps = require("packard.parser.deps")

local Parser = {}

---@class NormalizedPlugin
---@field owner_repo string
---@field name string
---@field url string
---@field branch string|nil
---@field version string|nil
---@field tag string|nil
---@field commit string|nil
---@field minimum_release_age number
---@field lazy boolean
---@field priority number|nil
---@field config function|boolean|nil
---@field main string|nil
---@field init function|nil
---@field opts table|nil
---@field event string|string[]|table|nil
---@field cmd string|string[]|table|nil
---@field keys string|string[]|table|function|nil
---@field ft string|string[]|table|nil
---@field ai_review table|nil Per-plugin AI config override
---@field cond boolean|function|nil Conditional loading (evaluated once at setup)
---@field build function|string|string[]|false|nil Post-install/update build step
---@field dependencies table[]|nil Array of { owner_repo: string, spec: any }
---@field is_dependency boolean|nil True if auto-injected
---@field depended_by string[]|nil Plugins that depend on this one
---@field spec table Original spec fields
---@field _cond boolean|nil Internal flag set by init.lua when cond blocks loading
---@field _has_build boolean|nil Cached: true if plugin has a build step (explicit or auto-detected)

---Normalize plugin specs: parse sources, validate fields, resolve dependencies,
---and produce a topologically-sorted list of NormalizedPlugin records.
---@param plugins table List of plugin specs from user
---@param defaults table|nil Global defaults
---@return NormalizedPlugin[]
function Parser.parse_all(plugins, defaults)
  defaults = defaults or {}
  local normalized = {}
  local seen = {}

  ---Normalize a single plugin spec into a NormalizedPlugin record.
  ---Returns nil when the plugin is a duplicate (already in seen).
  ---@param spec string|table
  ---@param is_dep boolean
  ---@return NormalizedPlugin|nil
  local function normalize_one(spec, is_dep)
    if type(spec) == "string" then
      spec = { spec }
    end

    if type(spec) ~= "table" then
      error(string.format("packard: plugin: expected string or table, got %s", type(spec)))
    end

    local source = spec[1]
    if type(source) ~= "string" then
      error("packard: plugin: missing 'owner/repo' string")
    end

    -- Parse source
    local owner_repo, name, url = Source.parse(source, spec)

    -- Dedup
    if seen[owner_repo] then
      return nil
    end

    -- Validate pin fields (branch, tag, commit, version, min_age)
    local pin = Validate.pin_fields(spec, owner_repo, defaults)

    -- Validate runtime fields (config, init, main, build)
    Validate.runtime_fields(spec, owner_repo)

    -- Resolve lazy default
    local lazy = Validate.resolve_lazy(spec, is_dep)

    -- Normalize dependencies
    local deps = Deps.normalize(spec, owner_repo)

    -- Assemble plugin record
    local plugin = {
      owner_repo = owner_repo,
      name = name,
      url = url,
      branch = pin.branch,
      version = pin.version,
      tag = pin.tag,
      commit = pin.commit,
      minimum_release_age = pin.min_age,
      lazy = lazy,
      priority = spec.priority,
      config = spec.config,
      main = spec.main,
      init = spec.init,
      opts = spec.opts,
      event = spec.event,
      cmd = spec.cmd,
      keys = spec.keys,
      ft = spec.ft,
      build = spec.build,
      ai_review = spec.ai_review,
      cond = spec.cond,
      dependencies = deps,
      is_dependency = is_dep,
      depended_by = {},
      spec = spec,
    }

    seen[owner_repo] = plugin
    table.insert(normalized, plugin)
    return plugin
  end

  -- Phase 1: Normalize user-declared plugins
  for _, spec in ipairs(plugins) do
    normalize_one(spec, false)
  end

  -- Phase 2: Resolve transitive dependencies
  Deps.resolve_transitive(normalized, seen, normalize_one)

  -- Phase 3: Topological Sort (Kahn's Algorithm)
  local sorted = {}
  local in_degree = {}
  local queue = {}

  for _, p in ipairs(normalized) do
    in_degree[p.owner_repo] = #(p.dependencies or {})
    if in_degree[p.owner_repo] == 0 then
      table.insert(queue, p)
    end
  end

  local function sort_queue()
    table.sort(queue, function(a, b)
      local pa = a.priority or 0
      local pb = b.priority or 0
      if pa ~= pb then
        return pa > pb
      end
      return a.owner_repo < b.owner_repo
    end)
  end

  while #queue > 0 do
    sort_queue()
    local p = table.remove(queue, 1)
    table.insert(sorted, p)

    for _, parent_repo in ipairs(p.depended_by) do
      in_degree[parent_repo] = in_degree[parent_repo] - 1
      if in_degree[parent_repo] == 0 then
        table.insert(queue, seen[parent_repo])
      end
    end
  end

  -- Check for circular dependencies
  if #sorted < #normalized then
    vim.notify("packard: circular dependency detected. Falling back to insertion order.", vim.log.levels.WARN)
    return normalized
  end

  return sorted
end

return Parser
