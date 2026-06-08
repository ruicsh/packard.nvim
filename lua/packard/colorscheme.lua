-- lua/packard/colorscheme.lua
--
-- ADR-011: Colorscheme autoload via ColorSchemePre autocmd.
--
-- When the user runs `:colorscheme <name>`, this module intercepts the
-- ColorSchemePre event and auto-loads a cond-blocked plugin that ships
-- a matching colors/<name>.{lua,vim} file.  This allows users to declare
-- multiple colorscheme plugins with cond = false and have them loaded on
-- demand when switching schemes, without eager-loading them all at startup.

local Loader = require("packard.loader")
local Utils = require("packard.utils")

local Colorscheme = {}
local plugins_list = {}

---Register the ColorSchemePre autocmd.
---Should be called once during setup(), after bootstrap and eager load.
---@param plugins table NormalizedPlugin[] — the full plugin list
function Colorscheme.register(plugins)
  plugins_list = plugins

  vim.api.nvim_create_autocmd("ColorSchemePre", {
    group = vim.api.nvim_create_augroup("packard_colorscheme", { clear = true }),
    callback = function(args)
      local name = args.match
      if not name or name == "" then
        return
      end

      -- Short-circuit if already available (built-in or loaded via eager startup).
      -- getcompletion returns every resolvable colorscheme name at this point.
      for _, known in ipairs(vim.fn.getcompletion("", "color") or {}) do
        if known == name then
          return
        end
      end

      -- Find a plugin that provides colors/<name>.{lua,vim}.
      -- Only cond-blocked plugins need attention — all others were already
      -- loaded during setup_eager_load.
      for _, plugin in ipairs(plugins_list) do
        -- Skip plugins that are already loaded
        if not plugin._cond then
          goto continue
        end

        local path = Utils.get_plugin_path(plugin)
        if vim.fn.isdirectory(path) ~= 1 then
          goto continue
        end

        for _, ext in ipairs({ "lua", "vim" }) do
          local file = vim.fs.joinpath(path, "colors", name .. "." .. ext)
          if vim.fn.filereadable(file) == 1 then
            -- Found the matching plugin.  Unblock and load it in the same
            -- order as setup_eager_load: init → load_and_config → triggers.
            plugin._cond = nil

            if type(plugin.init) == "function" then
              local ok, err = pcall(plugin.init, plugin)
              if not ok then
                vim.notify(
                  string.format("packard: init function error for '%s': %s", plugin.name, err),
                  vim.log.levels.ERROR
                )
              end
            end

            Loader.load_and_config(plugin, plugins_list)
            Loader.register_triggers(plugin)
            return
          end
        end

        ::continue::
      end
    end,
  })
end

return Colorscheme
