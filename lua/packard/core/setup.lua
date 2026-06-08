---@private
---Core orchestration: plugin spec merging and the main setup() entrypoint
---that wires everything together.

local Cooldown = require("packard.cooldown")
local Loader = require("packard.loader")
local Parser = require("packard.parser")
local UI = require("packard.ui")
local Utils = require("packard.utils")

local M = {}

---Initialize packard.nvim
---@param opts table
---@param ctx table The packard M table (provides .config, .plugins, ._bootstrap, ._setup_eager_load, ._register_commands)
function M.setup(opts, ctx)
  -- NFR-003: Neovim version guard
  --[[@diagnostic disable-next-line: undefined-field]]
  if vim.version.lt(vim.version(), { 0, 12, 0 }) then
    error("packard requires Neovim >= 0.12")
  end

  if type(opts) ~= "table" then
    error(string.format("packard.setup: expected a table, got %s", type(opts)))
  end

  local plugins = {}
  local file_specs = {}

  if opts.specs_dir then
    if type(opts.specs_dir) ~= "string" then
      error("packard.setup: 'specs_dir' must be a string")
    end
    local errors, warnings
    file_specs, errors, warnings = Loader.scan_all(opts.specs_dir)

    if #errors > 0 then
      vim.notify(
        string.format("packard: %d spec file(s) failed to load:\n%s", #errors, table.concat(errors, "\n")),
        vim.log.levels.WARN
      )
    end
    if #warnings > 0 then
      vim.notify(
        string.format(
          "packard: %d spec file(s) returned non-table values and were skipped:\n%s",
          #warnings,
          table.concat(warnings, "\n")
        ),
        vim.log.levels.WARN
      )
    end
  end

  if opts.plugins then
    if type(opts.plugins) ~= "table" then
      error("packard.setup: 'plugins' must be a table")
    end
    -- Merge: file specs first, then inline
    vim.list_extend(plugins, file_specs)
    vim.list_extend(plugins, opts.plugins)
  else
    plugins = file_specs
  end

  if #plugins == 0 and not opts.specs_dir and not opts.plugins then
    error("packard.setup: at least one of 'plugins' or 'specs_dir' must be provided")
  end

  local defaults = opts.defaults or {}
  if type(defaults) ~= "table" then
    error("packard.setup: 'defaults' must be a table")
  end

  if defaults.minimum_release_age ~= nil then
    if type(defaults.minimum_release_age) ~= "number" or defaults.minimum_release_age < 0 then
      error("packard.setup: 'defaults.minimum_release_age' must be a non-negative number")
    end
  end

  ctx.config = {
    defaults = defaults,
    plugins = opts.plugins,
    specs_dir = opts.specs_dir,
    ai_review = opts.ai_review,
    highlights = opts.highlights,
    debug = opts.debug,
  }

  -- T-1.3.2: Include packard itself if not disabled
  -- Last occurrence wins (so inline wins over file specs).
  local final_specs = {}
  local seen = {}

  for i = 1, #plugins do
    local p = plugins[i]
    if type(p) == "string" then
      p = { p }
    end
    -- Resolve the dedup key: [1] for remote, dir path for local
    local source = p[1]
    if not source and p.dir then
      if type(p.dir) ~= "string" then
        error(string.format("packard: 'dir' must be a string, got %s", type(p.dir)))
      end
      source = Utils.norm(p.dir)
    end
    if not source and type(p) == "table" then
      error("packard: plugin spec must have a 'owner/repo' string or 'dir' field")
    end
    if source then
      -- Resolve enabled: boolean (lazy.nvim-compat) or fun():boolean
      local enabled = p.enabled
      if type(enabled) == "function" then
        local ok, result = pcall(enabled)
        if ok then
          enabled = result
        else
          vim.notify(
            string.format("packard: error evaluating enabled() for '%s': %s", source, tostring(result)),
            vim.log.levels.WARN
          )
          enabled = true -- errors are non-fatal; plugin remains enabled
        end
      end
      if enabled == false then
        -- Drop disabled spec; also remove existing entry if present
        if seen[source] then
          -- Remove from final_specs
          local idx
          for j = 1, #final_specs do
            local sj = final_specs[j][1] or (final_specs[j].dir and Utils.norm(final_specs[j].dir))
            if sj == source then
              idx = j
              break
            end
          end
          if idx then
            table.remove(final_specs, idx)
          end
          seen[source] = nil
        end
      elseif not seen[source] then
        table.insert(final_specs, p)
        seen[source] = p
      else
        -- Duplicate found: override with later spec
        local existing = seen[source]
        Parser.merge_specs(existing, p, source)
      end
    end
  end

  if opts.self_management ~= false then
    local found = false
    for _, p in ipairs(final_specs) do
      local source = type(p) == "string" and p or p[1]
      if source and source:match("ruicsh/packard.nvim") then
        found = true
        break
      end
    end
    if not found then
      table.insert(final_specs, 1, "ruicsh/packard.nvim")
    end
  end

  ctx.plugins = Parser.parse_all(final_specs, defaults)
  if #ctx.plugins == 0 then
    vim.notify("packard: no plugins declared. Add plugins to packard.setup().", vim.log.levels.WARN)
    return ctx
  end

  -- Evaluate cond: evaluate once per plugin (matching lazy.nvim's fix_cond() behavior)
  for _, plugin in ipairs(ctx.plugins) do
    local cond = plugin.cond
    if cond == nil then
      cond = defaults.cond
    end
    if type(cond) == "function" then
      local ok, result = pcall(cond, plugin)
      if ok then
        if result == false then
          plugin._cond = true
        elseif type(result) == "string" then
          vim.notify(string.format("packard: %s for '%s'", result, plugin.owner_repo), vim.log.levels.INFO)
        end
      else
        vim.notify(
          string.format("packard: cond() error for '%s': %s", plugin.owner_repo, tostring(result)),
          vim.log.levels.WARN
        )
      end
    elseif cond == false then
      plugin._cond = true
    end
  end

  -- Share config with UI
  UI.config = ctx.config

  -- Set debug-mode flags before execution
  Loader._debug = opts.debug or false
  Utils._debug = opts.debug or false

  ctx._bootstrap()
  ctx._setup_eager_load()
  -- ADR-011: colorscheme autoload — must run after eager load so any
  -- already-loaded colorscheme plugins are known to getcompletion.
  require("packard.colorscheme").register(ctx.plugins)
  ctx._register_commands()

  -- T-7.1: Startup notification
  if opts.notifications ~= false then
    vim.schedule(function()
      local status = Cooldown.get_status(ctx.plugins)
      local count = 0
      for _ in pairs(status.eligible) do
        count = count + 1
      end
      if count > 0 then
        vim.notify(
          string.format("packard: %d plugins eligible for review. Run :Packard review", count),
          vim.log.levels.INFO
        )
      end
    end)
  end

  return ctx
end

return M
