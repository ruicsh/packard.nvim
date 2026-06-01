local Cooldown = require("packard.cooldown")
local Lockfile = require("packard.lockfile")
local Orphans = require("packard.orphans")
local State = require("packard.state")
local Utils = require("packard.utils")

return function(UI)
  function UI.render_installed(lines)
    local grouped = {
      installed = {},
      anomalies = {},
    }

    local function get_branch_display(plugin)
      local branch_display = plugin.branch or "(default)"
      if plugin.commit then
        branch_display = "pin:" .. plugin.commit:sub(1, 7)
      elseif plugin.tag then
        branch_display = "tag:" .. plugin.tag
      elseif plugin.version then
        branch_display = "ver:" .. plugin.version
      end
      return branch_display
    end

    -- Default column widths; expand dynamically if content is wider
    local max_name_len = 30
    local max_branch_len = 15
    for _, plugin in ipairs(UI.plugins) do
      local path = Utils.get_plugin_path(plugin)
      if vim.fn.isdirectory(path) == 0 then
        table.insert(grouped.anomalies, plugin)
      else
        table.insert(grouped.installed, plugin)
      end

      local name_display = plugin.owner_repo
      if plugin.is_dependency then
        name_display = name_display .. " [dep]"
      end
      if plugin._cond then
        name_display = name_display .. " [cond]"
      end
      max_name_len = math.max(max_name_len, vim.fn.strdisplaywidth(name_display))
      max_branch_len = math.max(max_branch_len, vim.fn.strdisplaywidth(get_branch_display(plugin)))
    end

    local function render_section(title, plugins, icon)
      if #plugins == 0 then
        return
      end
      table.insert(lines, string.format("  %s (%d)", title, #plugins))
      local fmt = string.format("    %%s %%-%ds  %%-10s  %%-%ds  %%-10s", max_name_len, max_branch_len)
      for _, plugin in ipairs(plugins) do
        local commit = Lockfile.get_installed_commit(plugin.name) or "unknown"
        local branch_display = get_branch_display(plugin)

        local cooldown = tostring(plugin.minimum_release_age) .. "d"
        local name_display = plugin.owner_repo
        if plugin.is_dependency then
          name_display = name_display .. " [dep]"
        end
        if plugin._cond then
          name_display = name_display .. " [cond]"
        end
        if plugin._has_build then
          name_display = name_display .. " [build]"
        end

        table.insert(lines, string.format(fmt, icon, name_display, commit:sub(1, 7), branch_display, cooldown))
        UI.line_map[#lines] = plugin.owner_repo

        if UI.expanded_row == plugin.owner_repo and UI.expanded_type == "log" then
          UI._render_log_expansion(lines, plugin.owner_repo)
        end
      end
      table.insert(lines, "")
    end

    render_section("Installed", grouped.installed, "●")
    render_section("Anomalies", grouped.anomalies, "⚠︎")
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

    -- Default column widths; expand dynamically if content is wider
    local max_name_len = 26
    local all_pending = vim.tbl_extend("force", status.eligible, status.cooldown)
    for owner_repo, _ in pairs(all_pending) do
      local name_display = owner_repo
      for _, p in ipairs(UI.plugins) do
        if p.owner_repo == owner_repo then
          if p.is_dependency then
            name_display = name_display .. " [dep]"
          end
          if p._cond then
            name_display = name_display .. " [cond]"
          end
          break
        end
      end
      max_name_len = math.max(max_name_len, vim.fn.strdisplaywidth(name_display))
    end

    local function render_section(title, items, icon)
      local keys = vim.tbl_keys(items)
      if #keys == 0 then
        return
      end
      table.sort(keys)

      table.insert(lines, string.format("  %s (%d)", title, #keys))
      local fmt = string.format("    %%s %%-%ds  %%-10s  %%-8s  %%-22s  %%-10s", max_name_len)
      for _, owner_repo in ipairs(keys) do
        local entry = items[owner_repo]
        local plugin_name = owner_repo:match("/([^/]+)$")
        local installed = Lockfile.get_installed_commit(plugin_name) or "???"

        -- Find plugin to check is_dependency
        local plugin
        for _, p in ipairs(UI.plugins) do
          if p.owner_repo == owner_repo then
            plugin = p
            break
          end
        end

        local name_display = owner_repo
        if plugin and plugin.is_dependency then
          name_display = name_display .. " [dep]"
        end
        if plugin and plugin._cond then
          name_display = name_display .. " [cond]"
        end

        local cooldown_text = entry.remaining_days and string.format("%d days remaining", entry.remaining_days)
          or "Eligible now"

        local target_display = entry.tag or entry.commit:sub(1, 7)

        table.insert(
          lines,
          string.format(
            fmt,
            icon,
            name_display,
            target_display,
            UI.get_pending_risk(owner_repo),
            cooldown_text,
            installed:sub(1, 7)
          )
        )
        UI.line_map[#lines] = owner_repo

        -- Render expansion if this row is expanded
        if UI.expanded_row == owner_repo then
          if UI.expanded_type == "ai" then
            UI._render_ai_expansion(lines, owner_repo)
          elseif UI.expanded_type == "log" then
            UI._render_log_expansion(lines, owner_repo)
          end
        end
      end
      table.insert(lines, "")
    end

    render_section("Eligible for Review", status.eligible, "●")
    render_section("In Cooldown", status.cooldown, "⏳")
  end

  function UI.render_summary(lines)
    local s = State.read()
    if not next(s.update_log) then
      table.insert(lines, "  No updates applied yet.")
      return
    end

    -- Default column width; expands dynamically if content is wider
    local max_name_len = 30
    -- Group by plugin, but let's just list them sorted by timestamp
    local all_updates = {}
    for owner_repo, updates in pairs(s.update_log) do
      max_name_len = math.max(max_name_len, vim.fn.strdisplaywidth(owner_repo))
      for _, update in ipairs(updates) do
        table.insert(all_updates, {
          owner_repo = owner_repo,
          from = update.from,
          to = update.to,
          timestamp = update.timestamp,
        })
      end
    end

    local fmt = string.format("  %%-%ds  %%-10s  %%-10s  %%-15s  %%-15s", max_name_len)
    table.insert(lines, string.format(fmt, "Plugin", "From", "To", "Date", "Age"))
    table.insert(
      lines,
      string.format(
        fmt,
        string.rep("─", max_name_len),
        string.rep("─", 10),
        string.rep("─", 10),
        string.rep("─", 15),
        string.rep("─", 15)
      )
    )

    table.sort(all_updates, function(a, b)
      return a.timestamp > b.timestamp
    end)

    for _, u in ipairs(all_updates) do
      local date = u.timestamp:sub(1, 10)
      local age = UI._format_age(u.timestamp)
      table.insert(lines, string.format(fmt, u.owner_repo, u.from:sub(1, 7), u.to:sub(1, 7), date, age))
    end
  end

  function UI.render_clean(lines)
    local s = State.read()
    local results = Orphans.find_orphans(UI.plugins, s)

    if #results.dirs == 0 and #results.state == 0 then
      table.insert(lines, "  No orphans found. Your spec is in sync with your system.")
      return
    end

    local function render_section(title, items, is_state)
      if #items == 0 then
        return
      end
      table.insert(lines, string.format("  %s (%d)", title, #items))
      for _, item in ipairs(items) do
        local is_selected = UI.selected_orphans[item]
        local icon = is_selected and "☒" or "☐"
        table.insert(lines, string.format("    %s %s", icon, item))
        UI.line_map[#lines] = item
      end
      table.insert(lines, "")
    end

    render_section("Orphaned Directories", results.dirs, false)
    render_section("Stale State Metadata", results.state, true)

    if next(UI.selected_orphans) then
      table.insert(lines, "  Press X to clean selected orphans.")
    end
  end

  function UI.render_help(lines)
    table.insert(lines, "  KEYBINDINGS:")
    table.insert(lines, "")
    table.insert(lines, "    I          Switch to Installed tab")
    table.insert(lines, "    P          Switch to Pending tab")
    table.insert(lines, "    S          Switch to Summary tab")
    table.insert(lines, "    C          Switch to Clean tab")
    table.insert(lines, "    U          Check for updates (Update tab)")
    table.insert(lines, "    ?          Show this help")
    table.insert(lines, "")
    table.insert(lines, "    j/k        Navigate list")
    table.insert(lines, "    <CR>       Show commit log (installed->pending / recent)")
    table.insert(lines, "    <Space>/x  Toggle selection (Clean tab)")
    table.insert(lines, "    A          Approve pending update")
    table.insert(lines, "    X          Reject pending update / Clean selected orphans")
    table.insert(lines, "    gx         Compare changes in browser")
    table.insert(lines, "    r          Toggle AI Review (inline)")
    table.insert(lines, "    R          Force re-run AI Review")
    table.insert(lines, "    B          Rebuild plugin under cursor")
    table.insert(lines, "")
    table.insert(lines, "    q/<Esc>    Close dashboard")
  end

  function UI.render_update(lines)
    if UI.check_state == "idle" then
      table.insert(lines, "  Update Check")
      table.insert(lines, "")
      table.insert(lines, "  Press U to check for updates.")
      table.insert(lines, "")
      table.insert(lines, "  This will fetch the latest commits from all remotes")
      table.insert(lines, "  and queue new commits for review.")
    elseif UI.check_state == "running" then
      table.insert(lines, "  Checking for updates...")
      table.insert(lines, "")
      table.insert(lines, "  Fetching latest commits from all remotes.")
      table.insert(lines, "  Results will appear here when complete.")
    elseif UI.check_state == "error" then
      table.insert(lines, "  Update Check Failed")
      table.insert(lines, "")
      table.insert(lines, "  " .. (UI.check_error_msg or "Unknown error"))
      table.insert(lines, "")
      table.insert(lines, "  Press U to retry.")
    elseif UI.check_state == "done" then
      table.insert(lines, "  Update Check Complete")
      table.insert(lines, "")
      if UI.check_new_count == 0 then
        table.insert(lines, "  All plugins are up to date.")
      else
        table.insert(lines, string.format("  %d new commit(s) queued:", UI.check_new_count))
        table.insert(lines, string.format("    - %d eligible (cooldown expired)", UI.check_eligible))
        table.insert(lines, string.format("    - %d in cooldown", UI.check_cooldown))
        table.insert(lines, "")
        table.insert(lines, "  Press P to switch to the Pending tab to review.")
      end
      table.insert(lines, "")
      table.insert(lines, "  Press U to check again.")
    end
  end
end
