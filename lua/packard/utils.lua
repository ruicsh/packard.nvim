local Utils = {}

Utils._debug = false
local function _debug_msg(fmt, ...)
  if not Utils._debug then
    return
  end
  --[[@diagnostic disable-next-line: redundant-parameter]]
  vim.api.nvim_echo({ { string.format(fmt, ...), "None" } }, true, {})
end

---Normalize a filesystem path: expand ~, resolve relative paths to absolute,
---convert backslashes, deduplicate slashes, strip trailing slash.
---Matches lazy.nvim's Util.norm behaviour (uses fnamemodify for absolute path).
---@param path string
---@return string
function Utils.norm(path)
  if path:sub(1, 1) == "~" then
    local home = vim.uv.os_homedir()
    if home:sub(-1) == "\\" or home:sub(-1) == "/" then
      home = home:sub(1, -2)
    end
    path = home .. path:sub(2)
  end
  -- fnamemodify(":p") resolves relative paths (., .., bare names) to absolute; matches lazy.nvim.
  path = vim.fn.fnamemodify(path, ":p")
  path = path:gsub("\\", "/"):gsub("/+", "/")
  return path:sub(-1) == "/" and path:sub(1, -2) or path
end

---Derive a plugin name from a filesystem path (last path component).
---Strips .git suffix if present, matching lazy.nvim's Spec.get_name.
---@param path string
---@return string
function Utils.path_name(path)
  path = path:gsub("/+$", "")
  local name = path:match("/([^/]+)$") or path
  name = name:sub(-4) == ".git" and name:sub(1, -5) or name
  return name
end

---Get the installation path for a plugin.
---Accepts either a plugin name string or a NormalizedPlugin table.
---When a table with a `dir` field is passed, returns `plugin.dir` directly.
---@param plugin_or_name string|table
---@return string
function Utils.get_plugin_path(plugin_or_name)
  if type(plugin_or_name) == "table" and plugin_or_name.dir then
    local result = plugin_or_name.dir
    _debug_msg("[packard] get_plugin_path: local plugin '%s' -> %s", plugin_or_name.name or "(unnamed)", result)
    return result
  end
  local name = type(plugin_or_name) == "table" and plugin_or_name.name or plugin_or_name
  local result = vim.fs.joinpath(vim.fn.stdpath("data"), "site", "pack", "core", "opt", name)
  _debug_msg("[packard] get_plugin_path: remote plugin '%s' -> %s", name, result)
  return result
end

---Convert Vim-style control character notation (^X) to actual control characters
---For example, "^V" becomes "\x16" (Ctrl+V).
---Skips conversion when ^X appears right after "[" (negation context in [...]).
---Allowed: ^A..^Z, ^[ (ESC), ^] (GS), ^\ (FS), ^^ (RS), ^_ (US)
---@param str string
---@return string
function Utils.convert_control_chars(str)
  str = str:gsub("^%^([A-Z%[%]\\%^_])", function(c)
    return string.char(c:byte() - 64)
  end)
  str = str:gsub("([^%[])%^([A-Z%[%]\\%^_])", function(prev, c)
    return prev .. string.char(c:byte() - 64)
  end)
  return str
end

return Utils
