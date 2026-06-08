local M = {}

---Normalize a plugin's dependencies into canonical { owner_repo, spec } entries.
---@param spec table Raw plugin spec
---@param owner_repo string
---@return table[]|nil Array of { owner_repo: string, spec: any }
function M.normalize(spec, owner_repo)
  if not spec.dependencies then
    return nil
  end

  local deps = {}
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
  return deps
end

---Resolve missing transitive dependencies and merge dep specs into already-registered plugins.
---Mutates `normalized` and `seen` in-place.
---@param normalized table[] Ordered list of NormalizedPlugin records
---@param seen table Map of owner_repo → NormalizedPlugin
---@param normalize_one function Callback to normalize a single spec: (spec, is_dep) → plugin|nil
function M.resolve_transitive(normalized, seen, normalize_one)
  local i = 1
  while i <= #normalized do
    local plugin = normalized[i]
    if plugin.dependencies then
      for _, dep_info in ipairs(plugin.dependencies) do
        local dep_owner_repo = dep_info.owner_repo
        if not seen[dep_owner_repo] then
          -- Auto-inject missing dependency
          local dep_spec = type(dep_info.spec) == "table" and dep_info.spec or { dep_owner_repo }
          normalize_one(dep_spec, true)
        else
          -- Merge dependency spec fields into already-registered plugin
          local dep_spec = dep_info.spec
          local existing = seen[dep_owner_repo]

          if type(dep_spec) == "table" then
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
end

return M
