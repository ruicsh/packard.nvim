local SELF_PROTECT_OWNER_REPO = "ruic/packard.nvim"
local SELF_PROTECT_REPO = "packard.nvim"

local Orphans = {}

---Get all plugin directories currently in the opt path
---@return string[]
function Orphans.get_opt_dirs()
  local opt_path = vim.fs.joinpath(vim.fn.stdpath("data"), "site", "pack", "core", "opt")
  if vim.fn.isdirectory(opt_path) == 0 then
    return {}
  end

  local dirs = {}
  for name, type in vim.fs.dir(opt_path) do
    if type == "directory" then
      table.insert(dirs, name)
    end
  end
  table.sort(dirs)
  return dirs
end

---Find orphans (plugins on disk but not in spec, or stale metadata)
---@param spec_plugins NormalizedPlugin[] Normalized plugins
---@param state PackardState The current packard state
---@return table { dirs: string[], state: string[] }
function Orphans.find_orphans(spec_plugins, state)
  local spec_names = {}
  for _, p in ipairs(spec_plugins) do
    spec_names[p.name] = true
  end

  -- 1. Find orphaned directories
  local opt_dirs = Orphans.get_opt_dirs()
  local orphaned_dirs = {}
  for _, dir in ipairs(opt_dirs) do
    -- Self-protection: never clean packard itself
    -- Note: We assumes packard is named 'packard.nvim' or 'packard'
    if dir ~= SELF_PROTECT_REPO and dir ~= "packard" and not spec_names[dir] then
      table.insert(orphaned_dirs, dir)
    end
  end

  -- 2. Find stale state metadata
  local stale_state = {}
  local active_owner_repos = {}
  for _, p in ipairs(spec_plugins) do
    active_owner_repos[p.owner_repo] = true
  end

  -- Check queue
  if state.queue then
    for owner_repo, _ in pairs(state.queue) do
      if not active_owner_repos[owner_repo] and owner_repo ~= SELF_PROTECT_OWNER_REPO then
        stale_state[owner_repo] = true
      end
    end
  end

  -- Check blacklist
  if state.blacklist then
    for owner_repo, _ in pairs(state.blacklist) do
      if not active_owner_repos[owner_repo] and owner_repo ~= SELF_PROTECT_OWNER_REPO then
        stale_state[owner_repo] = true
      end
    end
  end

  local stale_list = {}
  for owner_repo, _ in pairs(stale_state) do
    table.insert(stale_list, owner_repo)
  end
  table.sort(stale_list)

  return {
    dirs = orphaned_dirs,
    state = stale_list,
  }
end

return Orphans
