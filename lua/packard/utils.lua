local Utils = {}

---Get the installation path for a plugin
---@param name string
---@return string
function Utils.get_plugin_path(name)
  return vim.fs.joinpath(vim.fn.stdpath("data"), "site", "pack", "core", "opt", name)
end

return Utils
