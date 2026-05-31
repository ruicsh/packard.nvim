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
---@field init function|nil
---@field opts table|nil
---@field event string|string[]|table|nil
---@field cmd string|string[]|table|nil
---@field keys string|string[]|table|function|nil
---@field ft string|string[]|table|nil
---@field ai_review table|nil Per-plugin AI config override
---@field cond boolean|function|nil Conditional loading (evaluated once at setup)
---@field dependencies table[]|nil Array of { owner_repo: string, spec: any }
---@field is_dependency boolean|nil True if auto-injected
---@field depended_by string[]|nil Plugins that depend on this one
---@field spec table Original spec fields
---@field _cond boolean|nil Internal flag set by init.lua when cond blocks loading

---Normalize plugin specs
---@param plugins table List of plugin specs from user
---@param defaults table|nil Global defaults
---@return NormalizedPlugin[]
function Parser.parse_all(plugins, defaults)
  defaults = defaults or {}
  local normalized = {}
  local seen = {}

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

    -- Check for SSH URLs early
    if source:match("^git@") or source:match("^ssh://") then
      error("packard: SSH URLs are not supported. Use HTTPS (public repos only).")
    end

    local owner_repo, name, url

    if source:match("^https?://") then
      -- It's a full URL
      url = source
      -- Try to extract owner/repo
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
      return nil
    end

    -- Derive name
    name = spec.name or owner_repo:match("/([^/]+)$")
    if not name then
      error(string.format("packard: could not derive name for plugin '%s'", owner_repo))
    end

    -- Field extraction
    local branch = spec.branch
    local tag = spec.tag
    if tag and type(tag) ~= "string" then
      error(string.format("packard: 'tag' for '%s' must be a string", owner_repo))
    end

    local commit = spec.commit
    if commit then
      if type(commit) ~= "string" then
        error(string.format("packard: 'commit' for '%s' must be a string", owner_repo))
      end
      if not commit:match("^%x+$") then
        error(string.format("packard: invalid commit SHA '%s' for '%s'", commit, owner_repo))
      end
    end

    local version = spec.version
    if version == nil and not tag and not commit and not branch then
      version = defaults.version
    end
    if version == false then
      version = nil
    end

    if version then
      local Semver = require("packard.semver")
      if not Semver.to_range(version) then
        error(string.format("packard: invalid version constraint '%s' for '%s'", version, owner_repo))
      end
    end

    local min_age = spec.minimum_release_age or defaults.minimum_release_age or 30
    if type(min_age) ~= "number" or min_age < 0 then
      error(string.format("packard: 'minimum_release_age' for '%s' must be a number (days)", owner_repo))
    end

    local lazy = spec.lazy
    if lazy == nil then
      if is_dep then
        lazy = false -- Dependencies default to eager to ensure availability
      else
        lazy = true -- User plugins default to lazy
      end
    end

    -- Validate config and init — config accepts function or true (auto-setup shortcut)
    if spec.config ~= nil and type(spec.config) ~= "function" and spec.config ~= true then
      error(string.format("packard: 'config' for '%s' must be a function or true", owner_repo))
    end
    if spec.init and type(spec.init) ~= "function" then
      error(string.format("packard: 'init' for '%s' must be a function", owner_repo))
    end

    -- Normalize dependencies to canonical owner/repo strings
    local deps
    if spec.dependencies then
      deps = {}
      for _, d in ipairs(spec.dependencies) do
        local d_source = type(d) == "string" and d or d[1]
        if type(d_source) ~= "string" then
          error(string.format("packard: invalid dependency for '%s'", owner_repo))
        end

        local d_owner_repo
        if d_source:match("^https?://") then
          local d_path = d_source:match("^https?://[^/]+/(.+)$")
          d_owner_repo = d_path and d_path:gsub("%.git$", "")
        elseif d_source:match("^[^/]+/[^/]+$") then
          d_owner_repo = d_source
        end

        if not d_owner_repo then
          error(string.format("packard: invalid dependency source '%s' for '%s'", d_source, owner_repo))
        end
        table.insert(deps, { owner_repo = d_owner_repo, spec = d })
      end
    end

    local plugin = {
      owner_repo = owner_repo,
      name = name,
      url = url,
      branch = branch,
      version = version,
      tag = tag,
      commit = commit,
      minimum_release_age = min_age,
      lazy = lazy,
      priority = spec.priority,
      config = spec.config,
      init = spec.init,
      opts = spec.opts,
      event = spec.event,
      cmd = spec.cmd,
      keys = spec.keys,
      ft = spec.ft,
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

  -- Initial pass: user-declared plugins
  for _, spec in ipairs(plugins) do
    normalize_one(spec, false)
  end

  -- Second pass: resolve dependencies (recursive)
  local i = 1
  while i <= #normalized do
    local plugin = normalized[i]
    if plugin.dependencies then
      for _, dep_info in ipairs(plugin.dependencies) do
        local dep_owner_repo = dep_info.owner_repo
        if not seen[dep_owner_repo] then
          -- Auto-inject missing dependency, preserving full spec if table
          local dep_spec = type(dep_info.spec) == "table" and dep_info.spec or { dep_owner_repo }
          normalize_one(dep_spec, true)
        else
          -- Merge dependency spec fields into already-registered plugin
          -- (e.g., branch from dependency spec should apply to top-level plugin)
          local dep_spec = dep_info.spec
          local existing = seen[dep_owner_repo]

          -- If it's used as a dependency, it should be eager to ensure availability,
          -- unless the dependency spec explicitly overrides it to lazy.
          if type(dep_spec) == "table" then
            if dep_spec.lazy ~= nil then
              existing.lazy = dep_spec.lazy
            else
              existing.lazy = false
            end

            if dep_spec.branch ~= nil and existing.branch == nil then
              existing.branch = dep_spec.branch
            end
            if dep_spec.version ~= nil and existing.version == nil then
              existing.version = dep_spec.version
            end
            if dep_spec.tag ~= nil and existing.tag == nil then
              existing.tag = dep_spec.tag
            end
            if dep_spec.commit ~= nil and existing.commit == nil then
              existing.commit = dep_spec.commit
            end
          else
            existing.lazy = false
          end
        end
        -- Link reverse dependency
        local dep_plugin = seen[dep_owner_repo]
        if dep_plugin then
          local already_linked = false
          for _, parent in ipairs(dep_plugin.depended_by) do
            if parent == plugin.owner_repo then
              already_linked = true
              break
            end
          end
          if not already_linked then
            table.insert(dep_plugin.depended_by, plugin.owner_repo)
          end
        end
      end
    end
    i = i + 1
  end

  -- Final pass: Topological Sort (Kahn's Algorithm)
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
