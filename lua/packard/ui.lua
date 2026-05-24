local UI = {}
local State = require("packard.state")
local Cooldown = require("packard.cooldown")
local Lockfile = require("packard.lockfile")
local URL = require("packard.url")
local ns = vim.api.nvim_create_namespace("packard")

UI.win = nil
UI.buf = nil
UI.tab = "installed" -- "installed", "pending", "summary"
UI.plugins = {} -- Store plugins passed from init
UI.line_map = {} -- Map line number to owner_repo
UI.is_offline = false
UI.config = nil -- Store config from init
UI.ai_results = {} -- Map owner_repo to { state = "loading"|"result"|"error", data = ... }
UI.expanded_row = nil -- owner_repo of expanded row
UI.progress = { current = 0, total = 0, message = "" }
UI._render_scheduled = false
UI.spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
UI.spinner_idx = 1
UI.spinner_timer = nil
UI._highlight_config = nil

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
    UI.setup_highlights(UI.config and UI.config.highlights)
    UI.render()
    return
  end

  -- T-4.1.2: Buffer management
  UI.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = UI.buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = UI.buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = UI.buf })
  vim.api.nvim_set_option_value("filetype", "packard", { buf = UI.buf })

  -- T-4.1.1: Floating window creation
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
    border = "single",
    title = " Packard ",
    title_pos = "center",
  })

  -- T-4.1.3: Window options

  -- T-4.1.6: Keymaps
  UI.setup_keymaps()

  -- Auto-collapse AI expansion on cursor move
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = UI.buf,
    callback = function()
      if not UI.expanded_row or UI.tab ~= "pending" then
        return
      end
      local line = vim.api.nvim_win_get_cursor(UI.win)[1]
      local owner_repo = UI.line_map[line]
      -- If the current line doesn't map to the expanded row AND it's not part of the expansion lines
      -- (expansion lines don't have a mapping in line_map)
      if owner_repo and owner_repo ~= UI.expanded_row then
        UI.expanded_row = nil
        UI.render()
      end
    end,
  })

  -- O-010: Highlights
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

function UI.setup_highlights(config)
  if config then
    UI._highlight_config = config
  end

  local highlights = UI._highlight_config
    or {
      PackardHeader = { link = "Normal" },
      PackardH2 = { link = "Normal" },
      PackardButton = { link = "CursorLine" },
      PackardButtonActive = { link = "Visual" },
      PackardPluginName = { link = "Normal" },
      PackardCommit = { link = "Normal" },
      PackardStatusOk = { link = "Normal" },
      PackardStatusWarn = { link = "Normal" },
      PackardStatusError = { link = "Normal" },
      PackardEligible = { link = "Normal" },
      PackardCooldown = { link = "Normal" },
      PackardKeyHint = { link = "@punctuation.special" },
      PackardDivider = { link = "Normal" },
      PackardProgressDone = { link = "Normal" },
      PackardProgressTodo = { link = "Normal" },
      PackardAIRiskLow = { link = "Normal" },
      PackardAIRiskMedium = { link = "Normal" },
      PackardAIRiskHigh = { link = "Normal" },
      PackardAIBorder = { link = "Normal" },
    }

  for name, opts in pairs(highlights) do
    opts.default = true
    vim.api.nvim_set_hl(0, name, opts)
  end

  -- Re-apply on colorscheme change
  local ok, autocmds = pcall(vim.api.nvim_get_autocmds, { group = "packard_ui_highlights", event = "ColorScheme" })
  if not ok or not autocmds[1] then
    vim.api.nvim_create_autocmd("ColorScheme", {
      group = vim.api.nvim_create_augroup("packard_ui_highlights", { clear = true }),
      callback = function()
        UI.setup_highlights()
      end,
    })
  end
end

function UI.setup_keymaps()
  local maps = {
    ["i"] = function()
      UI.tab = "installed"
      UI.expanded_row = nil
      UI.render()
    end,
    ["p"] = function()
      UI.tab = "pending"
      UI.expanded_row = nil
      UI.render()
    end,
    ["s"] = function()
      UI.tab = "summary"
      UI.expanded_row = nil
      UI.render()
    end,
    ["q"] = function()
      UI.close()
    end,
    ["<Esc>"] = function()
      UI.close()
    end,
    ["?"] = function()
      UI.tab = "help"
      UI.render()
    end,
    -- Standard navigation handled by buffer defaults
    ["<CR>"] = function()
      UI.handle_approve()
    end,
    ["r"] = function()
      UI.handle_reject()
    end,
    ["gx"] = function()
      UI.handle_compare()
    end,
    ["a"] = function()
      UI.handle_ai_review()
    end,
    ["A"] = function()
      UI.handle_ai_review({ force = true })
    end,
  }

  for key, action in pairs(maps) do
    if type(action) == "function" then
      vim.keymap.set("n", key, action, { buffer = UI.buf, silent = true })
    end
  end
end

function UI.close()
  if UI.win and vim.api.nvim_win_is_valid(UI.win) then
    vim.api.nvim_win_close(UI.win, true)
  end
  UI.win = nil
  UI.buf = nil
  UI._stop_spinner()
end

-- T-4.1.5: Render
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
    { id = "pending", label = "Pending", key = "p" },
    { id = "summary", label = "Summary", key = "s" },
    { id = "help", label = "Help", key = "?" },
  }

  local header_parts = {}
  local current_col = 2 -- account for leading "  "
  UI._tab_extmarks = {}

  for _, t in ipairs(tabs) do
    local is_active = UI.tab == t.id
    local label = t.label
    local key = t.key
    -- 2. add the shortcut to each tab after the label
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
  elseif UI.tab == "pending" then
    UI.render_pending(lines)
  elseif UI.tab == "summary" then
    UI.render_summary(lines)
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

  UI.apply_highlights()

  vim.api.nvim_win_set_config(
    UI.win,
    { title = string.format(" Packard · %s ", UI.tab:sub(1, 1):upper() .. UI.tab:sub(2)) }
  )
end

function UI.apply_highlights()
  local buf = UI.buf
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  -- Apply header tab highlights
  if UI._tab_extmarks then
    for _, em in ipairs(UI._tab_extmarks) do
      vim.api.nvim_buf_set_extmark(buf, ns, 1, em.start_col, {
        end_col = em.end_col,
        hl_group = em.hl_group,
      })
      -- Highlight the shortcut key within the pill
      vim.api.nvim_buf_set_extmark(buf, ns, 1, em.key_start, {
        end_col = em.key_end,
        hl_group = "PackardKeyHint",
      })
    end
  end

  -- Apply progress bar highlights
  if UI._progress_info then
    local start_col = 2
    local done_bytes = UI._progress_info.done_len * 3
    local todo_bytes = UI._progress_info.todo_len * 3

    vim.api.nvim_buf_set_extmark(buf, ns, UI._progress_info.line_idx, start_col, {
      end_col = start_col + done_bytes,
      hl_group = "PackardProgressDone",
    })
    vim.api.nvim_buf_set_extmark(buf, ns, UI._progress_info.line_idx, start_col + done_bytes, {
      end_col = start_col + done_bytes + todo_bytes,
      hl_group = "PackardProgressTodo",
    })
  end

  for i, line in ipairs(lines) do
    if line:match("^  %a") then -- Section headers (Installed (8), etc.)
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 2, {
        hl_group = "PackardH2",
      })
    elseif line:match("^    [●⚠⏳]") then -- Plugin rows
      -- 1. Icon
      local icon_match = line:match("^    ([●⚠⏳][^ ]*)")
      if icon_match then
        local icon_len = #icon_match
        vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 4, {
          end_col = 4 + icon_len,
          hl_group = line:match("⚠") and "PackardStatusError" or "PackardStatusOk",
        })

        -- 2. Plugin Name
        local name_start = 4 + icon_len + 1
        local name_end = line:find("  ", name_start)
        if name_end then
          vim.api.nvim_buf_set_extmark(buf, ns, i - 1, name_start, {
            end_col = name_end,
            hl_group = "PackardPluginName",
          })

          -- 3. Commit (find next word)
          local commit_start = line:find("%w", name_end)
          if commit_start then
            local commit_end = line:find(" ", commit_start)
            vim.api.nvim_buf_set_extmark(buf, ns, i - 1, commit_start, {
              end_col = commit_end,
              hl_group = "PackardCommit",
            })

            -- 4. Risk (if in pending tab)
            if UI.tab == "pending" then
              local risk_start = line:find("%S", commit_end)
              if risk_start then
                local risk_end = line:find(" ", risk_start)
                local risk = line:sub(risk_start, risk_end and risk_end - 1 or #line)
                local hl = "PackardAIRiskLow"
                if risk == "medium" then
                  hl = "PackardAIRiskMedium"
                elseif risk == "high" then
                  hl = "PackardAIRiskHigh"
                end
                vim.api.nvim_buf_set_extmark(buf, ns, i - 1, risk_start - 1, {
                  end_col = risk_end and risk_end - 1 or #line,
                  hl_group = hl,
                })

                -- 5. Cooldown/Eligible status
                if risk_end then
                  local status_start = line:find("%S", risk_end)
                  if status_start then
                    local status_end = line:find("  ", status_start)
                    vim.api.nvim_buf_set_extmark(buf, ns, i - 1, status_start - 1, {
                      end_col = status_end or #line,
                      hl_group = line:match("Eligible") and "PackardEligible" or "PackardCooldown",
                    })
                  end
                end
              end
            end
          end
        end
      end
    elseif line:match("^    [╭╰│]") then
      -- AI Expansion
      local line_len = #line
      local west_col = 4
      local west_end = 7
      local east_col = line_len - 3
      local east_end = line_len

      -- 1. Structural Highlights (West/East Corners/Bars)
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, west_col, { end_col = west_end, hl_group = "PackardAIBorder" })
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, east_col, { end_col = east_end, hl_group = "PackardAIBorder" })

      if line:match("╭") then
        -- North: Horizontal lines + Title isolation
        local title_text = " AI Review "
        local title_pos = line:find(title_text, 1, true)
        if title_pos then
          local left_start = west_end
          local left_end = title_pos - 1
          local right_start = title_pos - 1 + #title_text
          local right_end = east_col
          if left_end > left_start then
            vim.api.nvim_buf_set_extmark(
              buf,
              ns,
              i - 1,
              left_start,
              { end_col = left_end, hl_group = "PackardAIBorder" }
            )
          end
          if right_end > right_start then
            vim.api.nvim_buf_set_extmark(
              buf,
              ns,
              i - 1,
              right_start,
              { end_col = right_end, hl_group = "PackardAIBorder" }
            )
          end
        end
      elseif line:match("╰") then
        -- South: Full horizontal line
        vim.api.nvim_buf_set_extmark(buf, ns, i - 1, west_end, { end_col = east_col, hl_group = "PackardAIBorder" })
      else
        -- Vertical (│): Content highlights
        local labels = { "Summary:", "Risk:", "Reasoning:", "Error:" }
        for _, label in ipairs(labels) do
          local label_pos = line:find(label, 8, true)
          if label_pos == 9 then -- 1-indexed find: 9 is 0-indexed 8
            vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 8, {
              end_col = 8 + #label,
              hl_group = "PackardH2",
            })
          end
        end

        if line:match("Risk:") then
          local risk_label_end = line:find("Risk:", 8, true)
          if risk_label_end == 9 then
            local risk = line:match("Risk:%s+(%w+)")
            if risk then
              local r_start = line:find(risk, 8 + #"Risk:", true)
              if r_start then
                local hl = (risk == "high" and "PackardAIRiskHigh")
                  or (risk == "medium" and "PackardAIRiskMedium")
                  or "PackardAIRiskLow"
                vim.api.nvim_buf_set_extmark(buf, ns, i - 1, r_start - 1, {
                  end_col = r_start - 1 + #risk,
                  hl_group = hl,
                })
              end
            end
          end
        elseif line:match("AI review in progress") then
          vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 8, { end_col = 11, hl_group = "PackardStatusWarn" })
        elseif line:find("[a] Re-run", 8, true) then
          local pos = line:find("[a] Re-run", 8, true)
          vim.api.nvim_buf_set_extmark(buf, ns, i - 1, pos - 1, {
            end_col = pos - 1 + #"[a] Re-run",
            hl_group = "PackardButton",
          })
        end
      end
    end
  end
end

function UI.render_installed(lines)
  local grouped = {
    installed = {},
    anomalies = {},
  }

  for _, plugin in ipairs(UI.plugins) do
    local path = require("packard.utils").get_plugin_path(plugin.name)
    if vim.fn.isdirectory(path) == 0 then
      table.insert(grouped.anomalies, plugin)
    else
      table.insert(grouped.installed, plugin)
    end
  end

  local function render_section(title, plugins, icon)
    if #plugins == 0 then
      return
    end
    table.insert(lines, string.format("  %s (%d)", title:upper(), #plugins))
    for _, plugin in ipairs(plugins) do
      local commit = Lockfile.get_installed_commit(plugin.name) or "unknown"
      local branch = plugin.branch or "(default)"
      local cooldown = tostring(plugin.minimum_release_age) .. "d"

      table.insert(
        lines,
        string.format("    %s %-30s %-10s %-15s %-10s", icon, plugin.owner_repo, commit:sub(1, 7), branch, cooldown)
      )
      UI.line_map[#lines] = plugin.owner_repo
    end
    table.insert(lines, "")
  end

  render_section("Installed", grouped.installed, "●")
  render_section("Anomalies", grouped.anomalies, "⚠︎")
end

---Get the AI review risk level for a pending plugin from UI.ai_results
---@param owner_repo string
---@return string
local function get_pending_risk(owner_repo)
  local result = UI.ai_results[owner_repo]
  if result and result.state == "result" and result.data and result.data.risk then
    return result.data.risk
  end
  return "-"
end

function UI.render_pending(lines)
  local status = Cooldown.get_status(UI.plugins)

  -- Pre-populate risk from AI cache for pending plugins that have been reviewed before
  for owner_repo, entry in pairs(status.eligible) do
    if not UI.ai_results[owner_repo] then
      local plugin_name = owner_repo:match("/([^/]+)$")
      local from = Lockfile.get_installed_commit(plugin_name)
      if from then
        local cached = State.get_ai_cache(owner_repo, from, entry.commit)
        if cached then
          UI.ai_results[owner_repo] = { state = "result", data = cached }
        end
      end
    end
  end
  for owner_repo, entry in pairs(status.cooldown) do
    if not UI.ai_results[owner_repo] then
      local plugin_name = owner_repo:match("/([^/]+)$")
      local from = Lockfile.get_installed_commit(plugin_name)
      if from then
        local cached = State.get_ai_cache(owner_repo, from, entry.commit)
        if cached then
          UI.ai_results[owner_repo] = { state = "result", data = cached }
        end
      end
    end
  end

  local function render_section(title, items, icon)
    local keys = vim.tbl_keys(items)
    if #keys == 0 then
      return
    end
    table.sort(keys)

    table.insert(lines, string.format("  %s (%d)", title:upper(), #keys))
    for _, owner_repo in ipairs(keys) do
      local entry = items[owner_repo]
      local plugin_name = owner_repo:match("/([^/]+)$")
      local installed = Lockfile.get_installed_commit(plugin_name) or "???"

      local cooldown_text = entry.remaining_days and string.format("%d days remaining", entry.remaining_days)
        or "Eligible now"

      table.insert(
        lines,
        string.format(
          "    %s %-26s %-8s %-8s %-22s %-10s",
          icon,
          owner_repo,
          entry.commit:sub(1, 7),
          get_pending_risk(owner_repo),
          cooldown_text,
          installed:sub(1, 7)
        )
      )
      UI.line_map[#lines] = owner_repo

      -- Render AI expansion if this row is expanded
      if UI.expanded_row == owner_repo then
        UI._render_ai_expansion(lines, owner_repo)
      end
    end
    table.insert(lines, "")
  end

  render_section("Eligible for Review", status.eligible, "●")
  render_section("In Cooldown", status.cooldown, "⏳")
end

function UI._render_ai_expansion(lines, owner_repo)
  local result = UI.ai_results[owner_repo]
  local win_width = vim.api.nvim_win_get_width(UI.win)
  local width = win_width - 8
  local inner_width = width - 4 -- Account for "│ " and " │"

  local function add_line(content)
    local display_width = vim.fn.strdisplaywidth(content)
    local padding = inner_width - display_width
    if padding < 0 then
      padding = 0
    end
    table.insert(lines, "    │ " .. content .. string.rep(" ", padding) .. " │")
  end

  local title = " AI Review "
  local total_border_cols = width - 2
  local title_cols = vim.fn.strdisplaywidth(title)
  local left_cols = 1
  local right_cols = total_border_cols - title_cols - left_cols
  if right_cols < 0 then
    right_cols = 0
  end
  local border_content = string.rep("─", left_cols) .. title .. string.rep("─", right_cols)
  table.insert(lines, "    ╭" .. border_content .. "╮")

  if not result or result.state == "loading" then
    local spinner = UI.spinner_frames[UI.spinner_idx]
    add_line(spinner .. " AI review in progress...")
  elseif result.state == "error" then
    add_line("Error: " .. result.data:sub(1, inner_width - 7))
  elseif result.state == "result" then
    local data = result.data
    -- Wrap summary
    local wrap_width = inner_width - 11
    local summary_lines = UI._wrap_text(data.summary, wrap_width)
    for i, l in ipairs(summary_lines) do
      local prefix = i == 1 and "Summary:   " or "           "
      add_line(prefix .. l)
    end

    add_line("Risk:      " .. data.risk)

    local reasoning_lines = UI._wrap_text(data.reasoning, wrap_width)
    for i, l in ipairs(reasoning_lines) do
      local prefix = i == 1 and "Reasoning: " or "           "
      add_line(prefix .. l)
    end

    add_line("[a] Re-run")
  end

  table.insert(lines, "    ╰" .. string.rep("─", total_border_cols) .. "╯")
end

function UI._wrap_text(text, max_len)
  local words = vim.split(text, "%s+")
  local res = {}
  local curr = ""
  for _, w in ipairs(words) do
    local curr_w = vim.fn.strdisplaywidth(curr)
    local next_w = vim.fn.strdisplaywidth(w)
    if curr_w + next_w + 1 > max_len then
      table.insert(res, curr)
      curr = w
    else
      curr = curr == "" and w or curr .. " " .. w
    end
  end
  table.insert(res, curr)
  return res
end

function UI.render_summary(lines)
  local s = State.read()
  if not next(s.update_log) then
    table.insert(lines, "  No updates applied yet.")
    return
  end

  table.insert(lines, string.format("  %-30s %-10s %-10s %-15s %-15s", "Plugin", "From", "To", "Date", "Age"))
  table.insert(
    lines,
    string.format(
      "  %-30s %-10s %-10s %-15s %-15s",
      string.rep("─", 30),
      string.rep("─", 10),
      string.rep("─", 10),
      string.rep("─", 15),
      string.rep("─", 15)
    )
  )

  -- Group by plugin, but let's just list them sorted by timestamp
  local all_updates = {}
  for owner_repo, updates in pairs(s.update_log) do
    for _, update in ipairs(updates) do
      table.insert(all_updates, {
        owner_repo = owner_repo,
        from = update.from,
        to = update.to,
        timestamp = update.timestamp,
      })
    end
  end

  table.sort(all_updates, function(a, b)
    return a.timestamp > b.timestamp
  end)

  for _, u in ipairs(all_updates) do
    local date = u.timestamp:sub(1, 10)
    local age = UI._format_age(u.timestamp)
    table.insert(
      lines,
      string.format("  %-30s %-10s %-10s %-15s %-15s", u.owner_repo, u.from:sub(1, 7), u.to:sub(1, 7), date, age)
    )
  end
end

function UI._format_age(timestamp)
  -- Parse ISO 8601 UTC timestamp
  -- Format: 2026-05-24 T 12:00:00Z
  local y, m, d, h, min, s = timestamp:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)Z")
  if not y then
    return ""
  end

  local t = os.time({
    year = tonumber(y) or 0,
    month = tonumber(m) or 1,
    day = tonumber(d) or 1,
    hour = tonumber(h) or 0,
    min = tonumber(min) or 0,
    sec = tonumber(s) or 0,
    isdst = false, -- UTC
  })

  local now_utc = os.time(os.date("!*t") --[[@as osdateparam]])
  local diff = now_utc - t
  local days = math.floor(diff / 86400)

  if days == 0 then
    return "today"
  end
  if days == 1 then
    return "yesterday"
  end
  return days .. " days ago"
end

function UI.handle_approve()
  if UI.tab ~= "pending" then
    return
  end
  local line = vim.api.nvim_win_get_cursor(UI.win)[1]
  local owner_repo = UI.line_map[line]
  if not owner_repo then
    return
  end

  local status = Cooldown.get_status(UI.plugins)
  local entry = status.eligible[owner_repo]
  if not entry then
    print("packard: this commit is still in cooldown")
    return
  end

  local plugin_name = owner_repo:match("/([^/]+)$")
  --[[@diagnostic disable-next-line: redundant-parameter]]
  local confirmed = vim.fn.confirm(string.format("Approve %s -> %s?", owner_repo, entry.commit:sub(1, 7)), "&Yes\n&No")
  if confirmed ~= 1 then
    return
  end

  print("packard: updating " .. owner_repo .. "...")

  local update_ok = true
  if vim.pack and vim.pack.update then
    local ok, err = pcall(vim.pack.update, { plugin_name }, { force = true })
    if not ok then
      print("packard: update failed: " .. tostring(err))
      update_ok = false
    end
  end

  -- The `PackChanged` auto command in `init.lua` will handle:
  -- 1. Logging the update
  -- 2. Queuing from state
  -- 3. Refreshing the dashboard
  if update_ok then
    print("packard: approved " .. owner_repo)
  else
    print("packard: update command failed for " .. owner_repo)
  end
end

function UI.handle_reject()
  if UI.tab ~= "pending" then
    return
  end
  local line = vim.api.nvim_win_get_cursor(UI.win)[1]
  local owner_repo = UI.line_map[line]
  if not owner_repo then
    return
  end

  local s = State.read()
  local entry = s.queue[owner_repo]
  if not entry then
    return
  end

  --[[@diagnostic disable: redundant-parameter]]
  local confirmed =
    vim.fn.confirm(string.format("Reject %s %s permanently?", owner_repo, entry.commit:sub(1, 7)), "&Yes\n&No")
  --[[@diagnostic enable: redundant-parameter]]
  if confirmed ~= 1 then
    return
  end

  State.blacklist(owner_repo, entry.commit)
  State.dequeue(owner_repo)
  UI.render()
  print("packard: rejected and blacklisted " .. entry.commit:sub(1, 7))
end

function UI.handle_compare()
  if UI.tab ~= "pending" then
    return
  end
  local line = vim.api.nvim_win_get_cursor(UI.win)[1]
  local owner_repo = UI.line_map[line]
  if not owner_repo then
    return
  end

  local s = State.read()
  local entry = s.queue[owner_repo]
  if not entry then
    return
  end

  local plugin_name = owner_repo:match("/([^/]+)$")
  local from = Lockfile.get_installed_commit(plugin_name)
  if not from then
    print(
      "packard: cannot open compare URL — installed commit not found (no lockfile entry for " .. plugin_name .. ")"
    )
    return
  end
  local to = entry.commit

  -- Find the plugin to get its URL
  local plugin
  for _, p in ipairs(UI.plugins) do
    if p.owner_repo == owner_repo then
      plugin = p
      break
    end
  end

  if not plugin then
    return
  end

  local url = URL.build_compare_url(plugin.url, from, to)
  if url then
    if vim.ui and vim.ui.open then
      vim.ui.open(url)
    else
      vim.fn.jobstart({ "open", url })
    end
  else
    print("packard: could not generate compare URL for " .. plugin.url)
  end
end

function UI.handle_ai_review(opts)
  opts = opts or {}
  if UI.tab ~= "pending" then
    return
  end
  local line = vim.api.nvim_win_get_cursor(UI.win)[1]
  local owner_repo = UI.line_map[line]
  if not owner_repo then
    return
  end

  -- Toggle if same row and not forcing
  if UI.expanded_row == owner_repo and not opts.force then
    UI.expanded_row = nil
    UI.render()
    return
  end

  UI.expanded_row = owner_repo

  -- Check if we need to fetch
  local result = UI.ai_results[owner_repo]
  if not result or opts.force or result.state == "error" then
    local s = State.read()
    local entry = s.queue[owner_repo]
    if not entry then
      return
    end

    local plugin_name = owner_repo:match("/([^/]+)$")
    local from = Lockfile.get_installed_commit(plugin_name)
    if not from then
      UI.ai_results[owner_repo] = { state = "error", data = "Installed commit not found" }
      UI.render()
      return
    end

    -- Find plugin object
    local plugin
    for _, p in ipairs(UI.plugins) do
      if p.owner_repo == owner_repo then
        plugin = p
        break
      end
    end

    if not plugin then
      return
    end

    UI.ai_results[owner_repo] = { state = "loading" }
    UI._start_spinner()
    UI.render()

    local AI = require("packard.ai")
    local ai_opts = vim.deepcopy(UI.config.ai_review)
    if opts.ignore_warn then
      ai_opts.ignore_warn = true
    end

    AI.review(plugin, from, entry.commit, ai_opts, function(err, res)
      if not UI.win or not vim.api.nvim_win_is_valid(UI.win) then
        return
      end

      if err == "WARN_LARGE_DIFF" then
        local confirmed = vim.fn.confirm(
          --[[@diagnostic disable-next-line: redundant-parameter, need-check-nil, undefined-field]]
          string.format("Diff is large (%.1f KB). Send to AI anyway?", res.byte_size / 1024),
          --[[@diagnostic disable-next-line: redundant-parameter]]
          "&Yes\n&No"
        )
        if confirmed == 1 then
          UI.handle_ai_review({ force = true, ignore_warn = true })
        else
          UI.ai_results[owner_repo] = { state = "error", data = "Large diff review cancelled" }
          UI.render()
        end
        return
      end

      if err then
        UI.ai_results[owner_repo] = { state = "error", data = err }
      else
        UI.ai_results[owner_repo] = { state = "result", data = res }
      end

      -- Only render if we are still on the same tab and row
      if UI.tab == "pending" and UI.expanded_row == owner_repo then
        UI.render()
      end
    end)
  else
    UI.render()
  end
end

function UI.render_help(lines)
  table.insert(lines, "  KEYBINDINGS:")
  table.insert(lines, "")
  table.insert(lines, "    i          Switch to Installed tab")
  table.insert(lines, "    p          Switch to Pending tab")
  table.insert(lines, "    s          Switch to Summary tab")
  table.insert(lines, "    ?          Show this help")
  table.insert(lines, "")
  table.insert(lines, "    j/k        Navigate list")
  table.insert(lines, "    <CR>       Approve pending update")
  table.insert(lines, "    r          Reject pending update (blacklist)")
  table.insert(lines, "    gx         Compare changes in browser")
  table.insert(lines, "    a          Toggle AI Review (inline)")
  table.insert(lines, "    A          Force re-run AI Review")
  table.insert(lines, "")
  table.insert(lines, "    q/<Esc>    Close dashboard")
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
    UI.spinner_timer:stop()
    UI.spinner_timer:close()
    UI.spinner_timer = nil
  end
end

return UI
