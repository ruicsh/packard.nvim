local Source = require("packard.parser.source")
local Validate = require("packard.parser.validate")
local Deps = require("packard.parser.deps")

local Parser = {}

-- Known valid spec fields for packard.
local KNOWN_FIELDS = {
  [1] = true,
  branch = true,
  tag = true,
  commit = true,
  version = true,
  pin = true,
  minimum_release_age = true,
  priority = true,
  config = true,
  init = true,
  main = true,
  build = true,
  name = true,
  dir = true,
  url = true,
  enabled = true,
  cond = true,
  opts = true,
  keys = true,
  cmd = true,
  dependencies = true,
  data = true,
  ai_review = true,
}

-- Known lazy.nvim spec fields that packard explicitly does not support.
-- Maps field name to a user-facing message explaining why.
local KNOWN_UNSUPPORTED = {
  event = "lazy-loading on events is not supported; packard loads all plugins eagerly",
  ft = "lazy-loading on file types is not supported; packard loads all plugins eagerly",
  lazy = "lazy-loading is not supported; packard loads all plugins eagerly",
  dev = "the dev field is not supported; use dir for local development",
  import = "per-plugin import is not supported; use specs_dir for global spec loading",
  optional = "optional plugins are not supported",
  specs = "nested specs are not supported",
  module = "module loading control is not supported",
  submodules = "submodule control is not supported; all submodules are fetched",
}

-- Deduplicate field warnings so each unsupported field is warned once per session.
local warned_fields = {}

---@class NormalizedPlugin
---@field owner_repo string
---@field name string
---@field url string|nil nil for local (dir-based) plugins
---@field dir string|nil Absolute normalized path for local plugins
---@field is_local boolean true when dir is provided (no remote git operations)
---@field pin boolean|nil
---@field branch string|nil
---@field version string|nil
---@field tag string|nil
---@field commit string|nil
---@field minimum_release_age number
---@field priority number|nil
---@field config function|boolean|nil
---@field main string|nil
---@field init function|nil
---@field opts table|nil
---@field cmd string|string[]|table|nil
---@field keys string|string[]|table|function|nil
---@field ai_review table|nil Per-plugin AI config override
---@field cond boolean|function|nil Conditional loading (evaluated once at setup)
---@field build function|string|string[]|false|nil Post-install/update build step
---@field dependencies table[]|nil Array of { owner_repo: string, spec: any }
---@field is_dependency boolean|nil True if auto-injected
---@field depended_by string[]|nil Plugins that depend on this one
---@field spec table Original spec fields
---@field _cond boolean|nil Internal flag set by init.lua when cond blocks loading
---@field _has_build boolean|nil Cached: true if plugin has a build step (explicit or auto-detected)

---Merge fields from a new spec into an existing spec (raw or normalized).
---@param existing table The existing spec or NormalizedPlugin
---@param spec table The new spec to merge from
---@param owner_repo string
function Parser.merge_specs(existing, spec, owner_repo)
  -- Merge dependencies
  if spec.dependencies then
    existing.dependencies = existing.dependencies or {}
    -- If 'existing' is a NormalizedPlugin, it will have an owner_repo field.
    -- Raw specs in setup.lua don't have this field yet.
    if existing.owner_repo then
      local new_deps = Deps.normalize(spec, owner_repo)
      for _, nd in ipairs(new_deps or {}) do
        table.insert(existing.dependencies, nd)
      end
    else
      -- Raw spec merge
      if type(existing.dependencies) == "table" and type(spec.dependencies) == "table" then
        for _, dep in ipairs(spec.dependencies) do
          table.insert(existing.dependencies, dep)
        end
      else
        existing.dependencies = spec.dependencies
      end
    end
  end

  -- Merge keys
  if spec.keys ~= nil then
    if type(existing.keys) == "function" or type(spec.keys) == "function" then
      local old_keys = existing.keys
      local new_keys = spec.keys
      existing.keys = function()
        local res1 = type(old_keys) == "function" and old_keys() or old_keys or {}
        if type(res1) ~= "table" then
          res1 = { res1 }
        end
        local res2 = type(new_keys) == "function" and new_keys() or new_keys or {}
        if type(res2) ~= "table" then
          res2 = { res2 }
        end
        -- NOTE: vim.list_extend mutates res1 in place. Since res1 is often a
        -- new table here, it's safe. Reassignment confirms the return value.
        return vim.list_extend(res1, res2)
      end
    else
      local old_keys = type(existing.keys) == "table" and existing.keys or { existing.keys }
      local new_keys = type(spec.keys) == "table" and spec.keys or { spec.keys }
      existing.keys = vim.list_extend(old_keys, new_keys)
    end
  end

  -- Merge opts
  if spec.opts ~= nil then
    if type(existing.opts) == "table" and type(spec.opts) == "table" then
      existing.opts = vim.tbl_deep_extend("force", existing.opts, spec.opts)
    else
      existing.opts = spec.opts
    end
  end

  -- Merge cmd
  if spec.cmd ~= nil then
    if type(existing.cmd) == "table" and type(spec.cmd) == "table" then
      for _, item in ipairs(spec.cmd) do
        table.insert(existing.cmd, item)
      end
    else
      existing.cmd = spec.cmd
    end
  end

  -- Last one wins for other fields
  local override_fields = {
    "branch",
    "version",
    "tag",
    "commit",
    "minimum_release_age",
    "priority",
    "config",
    "init",
    "main",
    "ai_review",
    "cond",
    "build",
    "dir",
    "name",
    "pin",
  }
  for _, field in ipairs(override_fields) do
    if spec[field] ~= nil then
      existing[field] = spec[field]
    end
  end
end

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
    if type(source) ~= "string" and not spec.dir then
      error("packard: plugin: missing 'owner/repo' string or 'dir' field")
    end

    -- Validate dir field before parsing
    Validate.validate_dir(spec)

    -- Parse source (handles both remote and local)
    local owner_repo, name, url, is_local = Source.parse(source, spec)

    -- Merge specs for the same plugin
    if seen[owner_repo] then
      Parser.merge_specs(seen[owner_repo], spec, owner_repo)
      return nil
    end

    -- Validate pin fields (branch, tag, commit, version, min_age)
    local pin = Validate.pin_fields(spec, owner_repo, defaults)

    -- Validate runtime fields (config, init, main, build)
    Validate.runtime_fields(spec, owner_repo)

    -- Normalize dependencies
    local deps = Deps.normalize(spec, owner_repo)

    -- Assemble plugin record
    local plugin = {
      owner_repo = owner_repo,
      name = name,
      url = url,
      dir = is_local and owner_repo or nil,
      is_local = is_local or false,
      branch = pin.branch,
      version = pin.version,
      tag = pin.tag,
      commit = pin.commit,
      pin = pin.pin,
      minimum_release_age = pin.min_age,
      priority = spec.priority,
      config = spec.config,
      main = spec.main,
      init = spec.init,
      opts = spec.opts,
      cmd = spec.cmd,
      keys = spec.keys,
      build = spec.build,
      ai_review = spec.ai_review,
      cond = spec.cond,
      dependencies = deps,
      is_dependency = is_dep,
      depended_by = {},
      spec = spec,
    }

    -- Warn about unsupported spec fields (once per field name per session)
    for key, _ in pairs(spec) do
      if not KNOWN_FIELDS[key] and not warned_fields[key] then
        warned_fields[key] = true
        local msg = KNOWN_UNSUPPORTED[key]
        if msg then
          vim.notify(string.format("packard: '%s' for '%s': %s", key, owner_repo, msg), vim.log.levels.WARN)
        else
          vim.notify(
            string.format("packard: unrecognized spec field '%s' in '%s'", key, owner_repo),
            vim.log.levels.WARN
          )
        end
      end
    end

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
