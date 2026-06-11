local Cooldown = require("packard.cooldown")
local Lockfile = require("packard.lockfile")
local Orphans = require("packard.orphans")
local State = require("packard.state")
local Utils = require("packard.utils")

---@class packard.ui.renderers
---Tab content renderers for the dashboard.
---Each function appends lines to the provided `lines` table and populates
---`UI.line_map` to map buffer lines to `owner_repo`.

return function(UI)
  ---Render the Installed tab: lists all plugins grouped by installed/anomaly,
  ---with commit SHA, branch display, cooldown, and status icons.
  ---Dependencies show `[dep]`, cond plugins show `[cond]`.
  ---@param lines string[] Buffer lines to append to
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
        if plugin.pin then
          name_display = name_display .. " [pinned]"
        end

        table.insert(lines, string.format(fmt, icon, name_display, commit:sub(1, 7), branch_display, cooldown))
        UI.line_map[#lines] = plugin.owner_repo

        if UI.expanded_row == plugin.owner_repo and UI.expanded_type == "log" then
          UI._render_log_expansion(lines, plugin.owner_repo)
        end
      end
      table.insert(lines, "")
    end

    render_section("Installed", grouped.installed, "")
    render_section("Anomalies", grouped.anomalies, "")
  end

  ---Render the Pending tab: eligible and in-cooldown plugins with pending
  ---commits. Pre-populates AI cache results. Shows risk level, cooldown
  ---status, and inline expansions (log or AI review).
  ---@param lines string[] Buffer lines to append to
  function UI.render_pending(lines)
    local status = Cooldown.get_status(UI.plugins)
    if not next(status.eligible) and not next(status.cooldown) then
      table.insert(lines, "  No pending updates.")
      return
    end

    -- Pre-populate risk from AI cache for pending plugins that have been reviewed before
    local function populate_ai_cache(entries)
      for owner_repo, entry in pairs(entries) do
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
    end
    populate_ai_cache(status.eligible)
    populate_ai_cache(status.cooldown)

    -- Build a lookup table so we don't O(n*m) scan UI.plugins for each pending entry
    local plugin_by_repo = {}
    for _, p in ipairs(UI.plugins) do
      plugin_by_repo[p.owner_repo] = p
    end

    -- Helper: compute abbreviated age from discovered_at timestamp.
    -- discovered_at is ISO 8601 UTC (ends in Z).  os.time({...}) interprets
    -- fields as LOCAL time, so we adjust by the timezone offset to get an
    -- accurate UTC→UTC diff regardless of the local timezone.
    local function compute_age(discovered_at)
      if not discovered_at or type(discovered_at) ~= "string" then
        return ""
      end
      local y, mo, d, h, mi, s = discovered_at:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)Z")
      if not y then
        return ""
      end
      local tz_offset = os.time() - os.time(os.date("!*t"))
      local local_ts = os.time({
        year = tonumber(y) or 0,
        month = tonumber(mo) or 1,
        day = tonumber(d) or 1,
        hour = tonumber(h) or 0,
        min = tonumber(mi) or 0,
        sec = tonumber(s) or 0,
        isdst = false,
      })
      local utc_ts = local_ts + tz_offset
      local diff = os.time() - utc_ts
      if diff < 0 then
        return ""
      end
      return UI._format_age_abbreviated(diff)
    end

    -- Helper: build display name with dependency/conditional annotations
    local function display_name(owner_repo, plugin)
      if not plugin then
        return owner_repo
      end
      local name = owner_repo
      if plugin.is_dependency then
        name = name .. " [dep]"
      end
      if plugin._cond then
        name = name .. " [cond]"
      end
      return name
    end

    -- Default column widths; expand dynamically if content is wider
    local max_name_len = 26
    local max_age_len = 7
    local all_pending = vim.tbl_extend("force", status.eligible, status.cooldown)
    for owner_repo, entry in pairs(all_pending) do
      local p = plugin_by_repo[owner_repo]
      local name_display = display_name(owner_repo, p)
      max_name_len = math.max(max_name_len, vim.fn.strdisplaywidth(name_display))
      local age = compute_age(entry.discovered_at)
      max_age_len = math.max(max_age_len, vim.fn.strdisplaywidth(age))
    end

    local function render_section(title, items, icon)
      local keys = vim.tbl_keys(items)
      if #keys == 0 then
        return
      end
      table.sort(keys)

      table.insert(lines, string.format("  %s (%d)", title, #keys))
      local fmt = string.format("    %%s %%-%ds  %%-10s  %%-8s  %%-22s  %%-%ds  %%-10s", max_name_len, max_age_len)
      for _, owner_repo in ipairs(keys) do
        local entry = items[owner_repo]
        local plugin_name = owner_repo:match("/([^/]+)$")
        local installed = Lockfile.get_installed_commit(plugin_name) or "???"

        -- Lookup plugin from the hash table built above
        local plugin = plugin_by_repo[owner_repo]
        local name_display = display_name(owner_repo, plugin)

        local cooldown_text = entry.remaining_days and string.format("%d days remaining", entry.remaining_days)
          or "Eligible now"

        local target_display = entry.tag or entry.commit:sub(1, 7)
        local age_text = compute_age(entry.discovered_at)

        table.insert(
          lines,
          string.format(
            fmt,
            icon,
            name_display,
            target_display,
            UI.get_pending_risk(owner_repo),
            cooldown_text,
            age_text,
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

    render_section("Eligible for Review", status.eligible, "")
    render_section("In Cooldown", status.cooldown, "")
  end

  ---Render the Summary tab: update history grouped by plugin, newest first.
  ---Capped at 10 entries per plugin. Shows from/to commit, date, and age.
  ---@param lines string[] Buffer lines to append to
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

  ---Render the Clean tab: orphaned directories and stale state metadata.
  ---Supports toggle selection via `UI.selected_orphans`.
  ---@param lines string[] Buffer lines to append to
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
        local icon = ""
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

  ---Render the Help tab: sectioned layout with all keybinding descriptions.
  ---@param lines string[] Buffer lines to append to
  function UI.render_help(lines)
    -- Intro
    table.insert(lines, "  packard — security-first Neovim plugin manager")
    table.insert(lines, "  Cooldown-driven updates with mandatory human review")
    table.insert(lines, "")

    -- Helper to add a keybinding row (key column padded to 12 chars)
    local function add_key(key, desc)
      table.insert(lines, string.format("    %-12s %s", key, desc))
    end

    -- Navigation
    table.insert(lines, "  Navigation")
    table.insert(lines, "")
    add_key("j / k", "Move cursor up/down")
    add_key("I", "Installed tab")
    add_key("P", "Pending tab")
    add_key("S", "Summary tab")
    add_key("C", "Clean tab")
    table.insert(lines, "")

    -- Actions
    table.insert(lines, "  Actions")
    table.insert(lines, "")
    add_key("U", "Check for updates")
    add_key("a", "Approve pending update")
    add_key("A", "Force approve (override cooldown)")
    add_key("X", "Reject / Clean orphans")
    add_key("B", "Rebuild plugin")
    add_key("<Space> / x", "Toggle selection")
    table.insert(lines, "")

    -- Review
    table.insert(lines, "  Review")
    table.insert(lines, "")
    add_key("<CR>", "View commit log")
    add_key("gx", "Compare in browser")
    add_key("r", "Toggle AI review")
    add_key("R", "Force re-run AI review")
    table.insert(lines, "")

    -- Window
    table.insert(lines, "  Window")
    table.insert(lines, "")
    add_key("?", "Show this help")
    add_key("q / <Esc>", "Close dashboard")
    table.insert(lines, "")
  end

  ---Render the Update tab: shows idle, running (progress), done (results),
  ---or error state for the update check workflow.
  ---@param lines string[] Buffer lines to append to
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
