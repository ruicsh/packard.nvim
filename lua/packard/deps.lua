local Deps = {}
local Utils = require("packard.utils")

---@type table<string, string>
Deps.KNOWN_MODULES = {
  ["blink.lib"] = "saghen/blink.lib",
  ["plenary"] = "nvim-lua/plenary.nvim",
  ["plenary.async"] = "nvim-lua/plenary.nvim",
  ["plenary.path"] = "nvim-lua/plenary.nvim",
  ["nvim-web-devicons"] = "nvim-tree/nvim-web-devicons",
  ["nui"] = "MunifTanjim/nui.nvim",
  ["nui.popup"] = "MunifTanjim/nui.nvim",
  ["nui.menu"] = "MunifTanjim/nui.nvim",
  ["nui.input"] = "MunifTanjim/nui.nvim",
}

---Build a set of all modules currently available in the runtime path
---@return table<string, boolean>
function Deps.build_available_set()
  local set = {}
  local rtp = vim.api.nvim_get_option_value("runtimepath", {})
  local paths = vim.split(rtp, ",")

  for _, path in ipairs(paths) do
    local lua_path = vim.fs.joinpath(path, "lua")
    if vim.fn.isdirectory(lua_path) == 1 then
      for name, type in vim.fs.dir(lua_path) do
        if type == "directory" then
          set[name] = true
        elseif type == "file" and name:match("%.lua$") then
          set[name:gsub("%.lua$", "")] = true
        end
      end
    end
  end
  return set
end

---Scan a directory for require() calls
---@param dir string
---@return table<string, boolean>
function Deps.scan_requires(dir)
  local found = {}
  local files = {}

  -- Scan plugin/*.lua
  local plugin_dir = vim.fs.joinpath(dir, "plugin")
  if vim.fn.isdirectory(plugin_dir) == 1 then
    for name, type in vim.fs.dir(plugin_dir) do
      if type == "file" and name:match("%.lua$") then
        table.insert(files, vim.fs.joinpath(plugin_dir, name))
      end
    end
  end

  -- Scan lua/**/init.lua
  local lua_dir = vim.fs.joinpath(dir, "lua")
  if vim.fn.isdirectory(lua_dir) == 1 then
    for name, type in vim.fs.dir(lua_dir) do
      if type == "directory" then
        local init_file = vim.fs.joinpath(lua_dir, name, "init.lua")
        if vim.fn.filereadable(init_file) == 1 then
          table.insert(files, init_file)
        end
      end
    end
  end

  local patterns = {
    "require%s*%(?%s*[\"']([^\"']+)[\"']%s*%)?",
    "require%s*[\"']([^\"']+)[\"']",
  }

  for _, file in ipairs(files) do
    local f = io.open(file, "r")
    if f then
      local content = f:read("*all")
      f:close()
      if content then
        for _, pattern in ipairs(patterns) do
          for module in content:gmatch(pattern) do
            -- Filter out local requires (starting with .)
            if not module:match("^%.") then
              found[module] = true
            end
          end
        end
      end
    end
  end

  return found
end

---Verify and install missing dependencies
---@param plugins NormalizedPlugin[]
---@return NormalizedPlugin[] New plugins to add to M.plugins
function Deps.verify_and_install(plugins)
  local available = Deps.build_available_set()
  local new_plugins = {}
  local seen_owner_repos = {}
  for _, p in ipairs(plugins) do
    seen_owner_repos[p.owner_repo] = true
  end

  -- Collect all dependency specs for a single batch vim.pack.add() call.
  -- Keyed by owner_repo to deduplicate and accumulate depended_by lists.
  ---@type table<string, {pack_spec: table, owner_repo: string, name: string, url: string, module: string, depended_by: string[]}>
  local dep_map = {}

  for _, plugin in ipairs(plugins) do
    local path = Utils.get_plugin_path(plugin)
    if vim.fn.isdirectory(path) == 1 then
      local requires = Deps.scan_requires(path)
      for module in pairs(requires) do
        -- Check if module available (either direct match or prefix match)
        local is_available = available[module]
        if not is_available then
          local parts = vim.split(module, "%.")
          if #parts > 1 then
            if available[parts[1]] then
              is_available = true
            end
          end
        end

        if not is_available then
          -- Resolve via mapping
          local owner_repo = Deps.KNOWN_MODULES[module]
          if not owner_repo then
            -- Try prefix match in mapping
            local parts = vim.split(module, "%.")
            if #parts > 1 then
              owner_repo = Deps.KNOWN_MODULES[parts[1]]
            end
          end

          if owner_repo and not seen_owner_repos[owner_repo] then
            local name = owner_repo:match("/([^/]+)$")
            if name then
              local url = "https://github.com/" .. owner_repo .. ".git"
              if not dep_map[owner_repo] then
                dep_map[owner_repo] = {
                  pack_spec = {
                    src = url,
                    name = name,
                    opt = true, -- Auto-deps should follow packard's lazy default
                  },
                  owner_repo = owner_repo,
                  name = name,
                  url = url,
                  module = module,
                  depended_by = {},
                }
              end
              table.insert(dep_map[owner_repo].depended_by, plugin.owner_repo)
              seen_owner_repos[owner_repo] = true
            end
          end
        end
      end
    end
  end

  -- Batch install all collected dependencies in a single vim.pack.add() call
  local dep_specs = vim.tbl_values(dep_map)
  if #dep_specs > 0 then
    local specs_for_add = {}
    for _, dep in ipairs(dep_specs) do
      specs_for_add[#specs_for_add + 1] = dep.pack_spec
    end

    -- Offline detection is handled by the caller (_bootstrap) which calls
    -- vim.pack.add for the primary plugins before this. Dependency failures
    -- are silently skipped — vim.pack.get() below still reflects the truth.
    --[[@diagnostic disable-next-line: redundant-parameter]]
    pcall(vim.pack.add, specs_for_add, { confirm = false })

    -- Check which dependencies actually made it to disk
    local installed = {}
    for _, p in ipairs(vim.pack.get()) do
      installed[p.spec.name] = true
    end

    for _, dep in ipairs(dep_specs) do
      if installed[dep.name] then
        table.insert(new_plugins, {
          owner_repo = dep.owner_repo,
          name = dep.name,
          url = dep.url,
          lazy = true,
          minimum_release_age = 30,
          is_dependency = true,
          depended_by = dep.depended_by,
        })

        -- Add to available set so subsequent plugins see it
        local mod_prefix = dep.module:match("^([^%.]+)") or dep.module
        available[mod_prefix] = true
        available[dep.module] = true
      end
    end
  end

  return new_plugins
end

return Deps
