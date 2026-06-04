---@class packard.ui.expansions
---Inline expansion renderers for the dashboard.
---Handles AI review results and git commit log expansions that appear below
---a plugin row when the user presses `r` or `<CR>`.

return function(UI)
  ---Get the AI review risk level for a pending plugin from `UI.ai_results`.
  ---@param owner_repo string
  ---@return string
  function UI.get_pending_risk(owner_repo)
    local result = UI.ai_results[owner_repo]
    if result and result.state == "result" and result.data and result.data.risk then
      return result.data.risk
    end
    return "-"
  end

  ---Word-wrap text to fit within a maximum display width.
  ---Splits on whitespace and accumulates lines to avoid exceeding max_len.
  ---@param text string Text to wrap
  ---@param max_len integer Maximum display width in characters
  ---@return string[] Wrapped lines
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

  ---Render AI review result inline below a plugin row.
  ---Shows a spinner while loading, error text on failure, or structured
  ---risk/summary/reasoning on success.
  ---@param lines string[] Buffer lines to append to
  ---@param owner_repo string Plugin identifier for looking up the result
  function UI._render_ai_expansion(lines, owner_repo)
    local result = UI.ai_results[owner_repo]
    local win_width = vim.api.nvim_win_get_width(UI.win)
    local width = win_width - 4

    local function add_line(content)
      local display_width = vim.fn.strdisplaywidth(content)
      if display_width > width then
        content = vim.fn.strcharpart(content, 0, width - 3) .. "..."
      end
      table.insert(lines, "    " .. content)
    end

    add_line("")
    add_line("AI Review")

    if not result or result.state == "loading" then
      local spinner = UI.spinner_frames[UI.spinner_idx]
      add_line(spinner .. " AI review in progress...")
    elseif result.state == "error" then
      add_line("Error: " .. tostring(result.data or ""))
    elseif result.state == "result" then
      local data = result.data
      add_line("Risk:      " .. data.risk)

      -- Wrap summary
      local wrap_width = width - 11
      local summary_lines = UI._wrap_text(data.summary, wrap_width)
      for i, l in ipairs(summary_lines) do
        local prefix = i == 1 and "Summary:   " or "           "
        add_line(prefix .. l)
      end

      local reasoning_lines = UI._wrap_text(data.reasoning, wrap_width)
      for i, l in ipairs(reasoning_lines) do
        local prefix = i == 1 and "Reasoning: " or "           "
        add_line(prefix .. l)
      end

      add_line("")
      add_line("[R] Re-run")
    end

    add_line("")
  end

  ---Render git commit log entries inline below a plugin row.
  ---Caches log output in `UI._log_cache` to avoid re-fetching.
  ---@param lines string[] Buffer lines to append to
  ---@param owner_repo string Plugin identifier for looking up cached log
  function UI._render_log_expansion(lines, owner_repo)
    local log_entries = UI._log_cache[owner_repo]
    if not log_entries then
      return
    end

    if not UI.win or not vim.api.nvim_win_is_valid(UI.win) then
      return
    end

    local win_width = vim.api.nvim_win_get_width(UI.win)
    local width = win_width - 4

    table.insert(lines, "    ")
    table.insert(lines, "    Commit Log")

    -- Compute max age width for right-alignment in columnar display
    local max_age_width = 0
    for _, entry in ipairs(log_entries) do
      if entry.age_width and entry.age_width > max_age_width then
        max_age_width = entry.age_width
      end
    end

    for _, entry in ipairs(log_entries) do
      if entry.hash and entry.age then
        -- Columnar: hash | age (right-aligned) | message
        local age_padded = string.rep(" ", max_age_width - entry.age_width) .. entry.age
        local line_str = "    " .. entry.hash .. "  " .. age_padded .. "  " .. (entry.msg or "")
        local display_width = vim.fn.strdisplaywidth(line_str)
        if display_width > width then
          local max_chars = math.max(0, width - 3)
          line_str = vim.fn.strcharpart(line_str, 0, max_chars) .. "..."
        end
        table.insert(lines, line_str)
      else
        -- Fallback entry (e.g., "No new commits") — just the message
        local msg = entry.msg or ""
        local display_width = vim.fn.strdisplaywidth(msg)
        if display_width > width then
          local max_chars = math.max(0, width - 3)
          msg = vim.fn.strcharpart(msg, 0, max_chars) .. "..."
        end
        table.insert(lines, "    " .. msg)
      end
    end

    table.insert(lines, "    ")
  end
end
