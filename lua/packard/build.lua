local Utils = require("packard.utils")

local Build = {}

---Check for auto-detect build files in the plugin directory.
---Matches lazy.nvim: looks for "build.lua" then "build/init.lua".
---@param plugin_path string
---@return string|nil
function Build._get_build_file(plugin_path)
  for _, path in ipairs({ "build.lua", "build/init.lua" }) do
    if vim.fn.filereadable(plugin_path .. "/" .. path) == 1 then
      return path
    end
  end
end

---Execute a single build step.
---@param plugin table NormalizedPlugin
---@param plugin_path string
---@param build_item string|function
---@return boolean success, string|nil error_msg
function Build._execute_one(plugin, plugin_path, build_item)
  if type(build_item) == "function" then
    -- Lua function — called with the plugin table
    local ok, err = pcall(build_item, plugin)
    if not ok then
      return false, tostring(err)
    end
    return true
  elseif type(build_item) == "string" then
    if build_item:sub(1, 1) == ":" then
      -- Neovim command (e.g., ":TSUpdate")
      local ok, result = pcall(vim.cmd, build_item:sub(2))
      if not ok then
        return false, tostring(result)
      end
      return true
    elseif build_item:match("%.lua$") then
      -- Lua file in the plugin directory (e.g., "build.lua")
      local filepath = plugin_path .. "/" .. build_item
      local chunk, err = loadfile(filepath)
      if not chunk then
        return false, err
      end
      local ok, run_err = pcall(chunk)
      if not ok then
        return false, tostring(run_err)
      end
      return true
    else
      -- Shell command — run via vim.system in the plugin directory
      local shell = vim.env.SHELL or vim.o.shell
      local shell_args = shell:find("cmd.exe", 1, true) and "/c" or "-c"
      --[[@diagnostic disable-next-line: redundant-parameter]]
      local obj = vim
        .system({ shell, shell_args, build_item }, {
          cwd = plugin_path,
        })
        :wait()
      if obj.code ~= 0 then
        local msg = obj.stderr and obj.stderr ~= "" and obj.stderr or obj.stdout
        return false, msg and msg:gsub("%s+$", "") or ("exited with code " .. obj.code)
      end
      return true
    end
  end

  return false, "unsupported build type: " .. type(build_item)
end

---Run build steps for a plugin.
---
---Build types supported (matching lazy.nvim):
---  - `fun(plugin)`: Lua function called with the plugin table
---  - `":Command"`: Neovim command executed via vim.cmd
---  - `"*.lua"`: Lua file loaded from the plugin directory
---  - any other string: shell command run via vim.system
---  - list of any of the above: run sequentially
---  - `false`: explicitly skip (even if build.lua exists)
---
---If no `build` field is set but `build.lua` or `build/init.lua` exists
---in the plugin directory, that file is used automatically.
---
---@param plugin table NormalizedPlugin
---@param opts {force?: boolean}?  # `force` is reserved for a future "skip if already built" optimization; currently a no-op.
---@return boolean success
function Build.run(plugin, opts)
  opts = opts or {}

  local builders = plugin.build
  local plugin_path = Utils.get_plugin_path(plugin)

  -- Check if plugin is actually installed on disk
  if vim.fn.isdirectory(plugin_path) == 0 then
    vim.notify(
      string.format("packard: build skipped for '%s': plugin not installed", plugin.owner_repo),
      vim.log.levels.WARN
    )
    return false
  end

  -- `build = false` means explicitly skip, even if build.lua exists
  if builders == false then
    return true
  end

  -- Load the plugin so its commands (e.g., TSUpdate) are available for build steps
  local ok_pack, pack_err = pcall(vim.cmd.packadd, plugin.name)
  if not ok_pack then
    vim.notify(
      string.format("packard: could not load plugin '%s' for build: %s", plugin.owner_repo, tostring(pack_err)),
      vim.log.levels.DEBUG
    )
  end

  -- Auto-detect build files if no explicit build field
  if not builders then
    builders = Build._get_build_file(plugin_path)
  end

  -- Nothing to build
  if not builders then
    return true
  end

  -- Normalize to list
  if type(builders) ~= "table" then
    builders = { builders }
  end

  local all_ok = true
  for _, build_item in ipairs(builders) do
    local ok, err = Build._execute_one(plugin, plugin_path, build_item)
    if not ok then
      all_ok = false
      vim.notify(string.format("packard: build error for '%s': %s", plugin.owner_repo, err), vim.log.levels.ERROR)
      -- Continue trying remaining steps even if one fails
    end
  end

  return all_ok
end

return Build
