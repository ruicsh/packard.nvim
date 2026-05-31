local Utils = {}

---Get the installation path for a plugin
---@param name string
---@return string
function Utils.get_plugin_path(name)
  return vim.fs.joinpath(vim.fn.stdpath("data"), "site", "pack", "core", "opt", name)
end

---Convert Vim-style control character notation (^X) to actual control characters
---For example, "^V" becomes "\x16" (Ctrl+V).
---Skips conversion when ^X appears right after "[" (negation context in [...]).
---Allowed: ^A..^Z, ^[ (ESC), ^] (GS), ^\ (FS), ^^ (RS), ^_ (US)
---@param str string
---@return string
function Utils.convert_control_chars(str)
  -- Convert ^X at start of string (can't be negation inside a character class)
  str = str:gsub("^%^([A-Z%[%]\\%^_])", function(c)
    return string.char(c:byte() - 64)
  end)
  -- Convert ^X not after "[" (negation context inside [...] character class)
  str = str:gsub("([^%[])%^([A-Z%[%]\\%^_])", function(prev, c)
    return prev .. string.char(c:byte() - 64)
  end)
  return str
end

return Utils
