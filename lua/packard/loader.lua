local Loader = {}

---Resolve path relative to stdpath('config') if relative
---@param path string
---@return string
function Loader.resolve_path(path)
  if path:match("^/") or path:match("^~") then
    return vim.fn.expand(path)
  end
  return vim.fs.joinpath(vim.fn.stdpath("config"), path)
end

---Load a single spec file
---@param filepath string
---@param modname string
---@return table specs, table errors, table warnings
function Loader.load_file(filepath, modname)
  local specs = {}
  local errors = {}
  local warnings = {}

  -- package.loaded[modname] = nil -- Clear cache if we used require
  -- But we use loadfile as per ADR-008

  local chunk, load_err = loadfile(filepath)
  if not chunk then
    table.insert(errors, string.format("%s: %s", filepath, load_err))
    return specs, errors, warnings
  end

  local ok, result = pcall(chunk)
  if not ok then
    table.insert(errors, string.format("%s: %s", filepath, result))
    return specs, errors, warnings
  end

  if type(result) == "table" then
    -- Detect array of specs vs single spec
    local is_array = false
    if type(result[1]) == "table" then
      is_array = true
    elseif result[2] ~= nil then
      is_array = true
    elseif result[1] ~= nil then
      -- Single element. Check if it has any non-integer keys
      local has_named_keys = false
      for k, _ in pairs(result) do
        if type(k) == "string" then
          has_named_keys = true
          break
        end
      end
      if not has_named_keys then
        is_array = true
      end
    end

    if is_array then
      for _, s in ipairs(result) do
        table.insert(specs, s)
      end
    elseif result[1] ~= nil then
      -- Single spec
      table.insert(specs, result)
    end
    -- If table is empty or has no [1], we just skip it (nil return case)
  elseif result ~= nil then
    table.insert(warnings, string.format("%s: returned %s, expected table", filepath, type(result)))
  end

  return specs, errors, warnings
end

---Scan directory recursively, files first then subdirectories
---@param path string
---@param base_path string
---@return table specs, table errors, table warnings
function Loader._scan_recursive(path, base_path)
  local all_specs = {}
  local all_errors = {}
  local all_warnings = {}

  local entries = {}
  for name, type in vim.fs.dir(path) do
    if not name:match("^_") then
      table.insert(entries, { name = name, type = type })
    end
  end

  -- Sort entries alphabetically
  table.sort(entries, function(a, b)
    return a.name < b.name
  end)

  local files = {}
  local subdirs = {}

  for _, entry in ipairs(entries) do
    if entry.type == "file" and entry.name:match("%.lua$") then
      table.insert(files, entry.name)
    elseif entry.type == "directory" then
      table.insert(subdirs, entry.name)
    end
  end

  -- Process files first
  for _, filename in ipairs(files) do
    local filepath = vim.fs.joinpath(path, filename)
    local rel_path = filepath:sub(#base_path + 2):gsub("%.lua$", "")
    local modname = rel_path:gsub("[/\\]", ".")

    local specs, errors, warnings = Loader.load_file(filepath, modname)
    vim.list_extend(all_specs, specs)
    vim.list_extend(all_errors, errors)
    vim.list_extend(all_warnings, warnings)
  end

  -- Then subdirectories
  for _, dirname in ipairs(subdirs) do
    local subdir_path = vim.fs.joinpath(path, dirname)
    local specs, errors, warnings = Loader._scan_recursive(subdir_path, base_path)
    vim.list_extend(all_specs, specs)
    vim.list_extend(all_errors, errors)
    vim.list_extend(all_warnings, warnings)
  end

  return all_specs, all_errors, all_warnings
end

---Scan all spec files in the directory
---@param plugins_dir string
---@return table specs, table errors, table warnings
function Loader.scan_all(plugins_dir)
  local resolved = Loader.resolve_path(plugins_dir)
  if vim.fn.isdirectory(resolved) == 0 then
    -- Check if it exists at all
    if vim.fn.filereadable(resolved) == 1 then
      error(string.format("packard.setup: plugins_dir '%s' exists but is a file, not a directory", resolved))
    end
    error(string.format("packard.setup: plugins_dir '%s' does not exist", resolved))
  end

  return Loader._scan_recursive(resolved, resolved)
end

return Loader
