local UI = {
  win = nil,
  buf = nil,
  tab = "installed",
  plugins = {},
  line_map = {},
  is_offline = false,
  config = nil,
  ai_results = {},
  expanded_row = nil,
  expanded_type = nil,
  _cursor_repo = nil,
  progress = { current = 0, total = 0, message = "" },
  selected_orphans = {},
  _render_scheduled = false,
  spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
  spinner_idx = 1,
  spinner_timer = nil,
  _highlight_config = nil,
  check_state = "idle",
  check_new_count = 0,
  check_eligible = 0,
  check_cooldown = 0,
  check_error_msg = nil,
  _log_cache = {},
  _progress_info = nil,
  _tab_extmarks = {},
}

-- Install functionality from sub-modules
require("packard.ui.utils")(UI)
require("packard.ui.highlights")(UI)
require("packard.ui.expansions")(UI)
require("packard.ui.renderers")(UI)
require("packard.ui.handlers")(UI)
require("packard.ui.keymaps")(UI)

-- ─── Lifecycle ───────────────────────────────────────────────────────────────

---Open the dashboard
---@param plugins table NormalizedPlugin[]
---@param initial_tab string|nil
---@param is_offline boolean|nil
function UI.open(plugins, initial_tab, is_offline)
  UI.plugins = plugins
  UI.tab = initial_tab or "installed"
  UI.is_offline = is_offline or false

  if UI.win and vim.api.nvim_win_is_valid(UI.win) then
    vim.api.nvim_set_current_win(UI.win)
    --[[@diagnostic disable-next-line: undefined-field]]
    UI.setup_highlights(UI.config and UI.config.highlights)
    UI.render()
    return
  end

  -- Buffer management
  UI.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = UI.buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = UI.buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = UI.buf })
  vim.api.nvim_set_option_value("filetype", "packard", { buf = UI.buf })

  -- Floating window creation
  local width = math.floor(vim.o.columns * 0.8)
  local height = math.floor(vim.o.lines * 0.8)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  UI.win = vim.api.nvim_open_win(UI.buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Packard ",
    title_pos = "center",
  })

  -- Window options
  vim.api.nvim_set_option_value("cursorline", false, { win = UI.win })

  -- Keymaps
  UI.setup_keymaps()

  -- Auto-collapse expansion on cursor move
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = UI.buf,
    callback = function()
      local line = vim.api.nvim_win_get_cursor(UI.win)[1]
      local owner_repo = UI.line_map[line]

      local changed = false
      if owner_repo ~= UI._cursor_repo then
        UI._cursor_repo = owner_repo
        changed = true

        -- If we moved to a different row, collapse expansion
        if UI.expanded_row and owner_repo ~= UI.expanded_row then
          UI.expanded_row = nil
          UI.expanded_type = nil
        end
      end

      if changed then
        UI.render()
      end
    end,
  })

  -- Highlights
  --[[@diagnostic disable-next-line: undefined-field]]
  UI.setup_highlights(UI.config and UI.config.highlights)

  -- Handle resize
  vim.api.nvim_create_autocmd("VimResized", {
    buffer = UI.buf,
    callback = function()
      if not UI.win or not vim.api.nvim_win_is_valid(UI.win) then
        return
      end
      local w = math.floor(vim.o.columns * 0.8)
      local h = math.floor(vim.o.lines * 0.8)
      local r = math.floor((vim.o.lines - h) / 2)
      local c = math.floor((vim.o.columns - w) / 2)

      vim.api.nvim_win_set_config(UI.win, {
        width = w,
        height = h,
        row = r,
        col = c,
      })
      UI.render()
    end,
  })

  UI.render()
end

function UI.close()
  if UI.win and vim.api.nvim_win_is_valid(UI.win) then
    vim.api.nvim_win_close(UI.win, true)
  end
  UI.win = nil
  UI.buf = nil
  UI.expanded_row = nil
  UI.expanded_type = nil
  UI._cursor_repo = nil
  UI.check_state = "idle"
  UI.check_new_count = 0
  UI.check_eligible = 0
  UI.check_cooldown = 0
  UI.check_error_msg = nil
  UI._stop_spinner()
  UI._log_cache = {}
end

-- Render debounced via vim.schedule
function UI.render()
  if UI._render_scheduled then
    return
  end
  UI._render_scheduled = true
  vim.schedule(function()
    UI._render_scheduled = false
    UI._do_render()
  end)
end

function UI._do_render()
  if not UI.buf or not vim.api.nvim_buf_is_valid(UI.buf) then
    return
  end

  vim.api.nvim_set_option_value("modifiable", true, { buf = UI.buf })
  UI.line_map = {}

  local lines = {}
  table.insert(lines, "") -- 1. empty line at top
  local tabs = {
    { id = "installed", label = "Installed", key = "i" },
    { id = "update", label = "Update", key = "U" },
    { id = "pending", label = "Pending", key = "p" },
    { id = "summary", label = "Summary", key = "s" },
    { id = "clean", label = "Clean", key = "c" },
    { id = "help", label = "Help", key = "?" },
  }

  local header_parts = {}
  local current_col = 2 -- account for leading "  "
  UI._tab_extmarks = {}

  for _, t in ipairs(tabs) do
    local is_active = UI.tab == t.id
    local label = t.label
    local key = t.key
    local display = string.format(" %s (%s) ", label, key)
    local start_col = current_col
    local end_col = start_col + #display

    table.insert(header_parts, display)
    table.insert(UI._tab_extmarks, {
      start_col = start_col,
      end_col = end_col,
      hl_group = is_active and "PackardButtonActive" or "PackardButton",
      key_start = start_col + #label + 3, -- offset for " " + label + " ("
      key_end = start_col + #label + 3 + #key,
    })

    current_col = end_col + 2 -- +2 for gap
  end

  table.insert(lines, "  " .. table.concat(header_parts, "  "))

  if UI.is_offline then
    table.insert(lines, "  (OFFLINE)")
  end

  table.insert(lines, "") -- line 3 (index 2)

  if UI.tab == "installed" then
    UI.render_installed(lines)
  elseif UI.tab == "update" then
    UI.render_update(lines)
  elseif UI.tab == "pending" then
    UI.render_pending(lines)
  elseif UI.tab == "summary" then
    UI.render_summary(lines)
  elseif UI.tab == "clean" then
    UI.render_clean(lines)
  elseif UI.tab == "help" then
    UI.render_help(lines)
  end

  if UI.progress and UI.progress.total > 0 then
    local width = vim.api.nvim_win_get_width(UI.win) - 10
    local current = UI.progress.current
    local total = UI.progress.total
    local done_len = math.floor((current / total) * width)
    local todo_len = width - done_len

    local bar = string.rep("━", done_len) .. string.rep("━", todo_len)
    table.insert(lines, string.format("  %s %d/%d %s", bar, current, total, UI.progress.message))
    UI._progress_info = {
      line_idx = #lines - 1,
      done_len = done_len,
      todo_len = todo_len,
    }
    table.insert(lines, "")
  else
    UI._progress_info = nil
  end

  vim.api.nvim_buf_set_lines(UI.buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = UI.buf })

  -- Update cursor repo before highlighting
  if UI.win and vim.api.nvim_win_is_valid(UI.win) then
    local cursor = vim.api.nvim_win_get_cursor(UI.win)
    local line = cursor[1]
    UI._cursor_repo = UI.line_map[line]
  end

  UI.apply_highlights(lines)

  vim.api.nvim_win_set_config(
    UI.win,
    { title = string.format(" Packard · %s ", UI.tab:sub(1, 1):upper() .. UI.tab:sub(2)) }
  )
end

function UI.set_progress(current, total, message)
  UI.progress = { current = current, total = total, message = message or "" }
  UI.render()
end

function UI._start_spinner()
  if UI.spinner_timer then
    return
  end
  UI.spinner_timer = vim.uv.new_timer()
  --[[@diagnostic disable-next-line: undefined-field]]
  UI.spinner_timer:start(
    100,
    100,
    vim.schedule_wrap(function()
      local loading = false
      for _, res in pairs(UI.ai_results) do
        if res.state == "loading" then
          loading = true
          break
        end
      end

      if not loading or not UI.win or not vim.api.nvim_win_is_valid(UI.win) then
        UI._stop_spinner()
        return
      end

      UI.spinner_idx = (UI.spinner_idx % #UI.spinner_frames) + 1
      UI.render()
    end)
  )
end

function UI._stop_spinner()
  if UI.spinner_timer then
    --[[@diagnostic disable-next-line: undefined-field]]
    UI.spinner_timer:stop()
    --[[@diagnostic disable-next-line: undefined-field]]
    UI.spinner_timer:close()
    UI.spinner_timer = nil
  end
end

return UI
