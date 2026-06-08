local Build = require("packard.build")
local UI = require("packard.ui")
local Utils = require("packard.utils")

local M = {}

---@private
---Register the :Packard user command and its subcommands.
function M.register_commands(ctx)
  vim.api.nvim_create_user_command("Packard", function(opts)
    local sub = opts.fargs[1]
    if not sub or sub == "" then
      UI.open(ctx.plugins, "installed", ctx._is_offline)
    elseif sub == "check" then
      ctx.check()
    elseif sub == "review" then
      UI.open(ctx.plugins, "pending", ctx._is_offline)
    elseif sub == "summary" then
      UI.open(ctx.plugins, "summary", ctx._is_offline)
    elseif sub == "clean" then
      UI.open(ctx.plugins, "clean", ctx._is_offline)
    elseif sub == "build" then
      -- :Packard build <name> — rebuild a specific plugin
      -- :Packard build — rebuild all plugins with build steps
      local target = opts.fargs[2]
      if target then
        -- Find the plugin by name or owner_repo
        local found
        for _, p in ipairs(ctx.plugins) do
          if p.name == target or p.owner_repo == target then
            found = p
            break
          end
        end
        if found then
          vim.notify(string.format("packard: building '%s'...", found.owner_repo), vim.log.levels.INFO)
          local ok = Build.run(found, { force = true })
          if ok then
            vim.notify(string.format("packard: build succeeded for '%s'", found.owner_repo), vim.log.levels.INFO)
          else
            vim.notify(
              string.format("packard: build failed for '%s' (see errors above)", found.owner_repo),
              vim.log.levels.WARN
            )
          end
        else
          vim.notify(string.format("packard: plugin '%s' not found", target), vim.log.levels.WARN)
        end
      else
        -- Rebuild all plugins with build steps
        local count = 0
        local failures = 0
        for _, p in ipairs(ctx.plugins) do
          if (p.build ~= nil and p.build ~= false) or Build._get_build_file(Utils.get_plugin_path(p)) then
            count = count + 1
            if not Build.run(p, { force = true }) then
              failures = failures + 1
            end
          end
        end
        if count == 0 then
          vim.notify("packard: no plugins with build steps", vim.log.levels.INFO)
        else
          vim.notify(
            string.format(
              "packard: rebuilt %d plugin(s)%s",
              count,
              failures > 0 and string.format(" (%d failed)", failures) or ""
            ),
            failures > 0 and vim.log.levels.WARN or vim.log.levels.INFO
          )
        end
      end
    elseif sub == "help" then
      UI.open(ctx.plugins, "help", ctx._is_offline)
    else
      vim.notify("packard: unknown subcommand '" .. sub .. "'", vim.log.levels.WARN)
    end
  end, {
    nargs = "*",
    complete = function(_, line)
      local l = vim.split(line, "%s+")
      local n = #l
      if n == 2 then
        local candidates = { "check", "review", "summary", "clean", "build", "help" }
        local res = {}
        for _, c in ipairs(candidates) do
          if c:sub(1, #l[2]) == l[2] then
            table.insert(res, c)
          end
        end
        return res
      elseif n == 3 and l[2] == "build" then
        -- Complete plugin names for :Packard build <name>
        local res = {}
        for _, p in ipairs(ctx.plugins) do
          if p.name:sub(1, #l[3]) == l[3] or p.owner_repo:sub(1, #l[3]) == l[3] then
            table.insert(res, p.name)
          end
        end
        return res
      end
    end,
  })
end

return M
