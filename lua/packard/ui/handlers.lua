local Build = require("packard.build")
local Cooldown = require("packard.cooldown")
local Lockfile = require("packard.lockfile")
local Orphans = require("packard.orphans")
local State = require("packard.state")
local URL = require("packard.url")
local Utils = require("packard.utils")

---@class packard.ui.handlers
---Dashboard action handlers for user keypresses.
---Each handler reads the current cursor position from `UI.line_map`,
---performs the action, and triggers `UI.render()` on completion.

return function(UI)
  ---Approve a pending update. Reads the cursor row, looks up the pending
  ---entry, confirms with the user, calls `vim.pack.update()`, logs the
  ---update, dequeues, and refreshes the dashboard.
  ---Only active on the Pending tab.
  ---@param force? boolean When true, bypasses cooldown and allows approving
  ---  entries still in the cooldown period.
  function UI.handle_approve(force)
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
    if not entry and force then
      entry = status.cooldown[owner_repo]
    end
    if not entry then
      if force then
        print("packard: no pending update for this plugin")
      elseif status.cooldown[owner_repo] then
        print("packard: this commit is still in cooldown")
      else
        print("packard: no pending update for this plugin")
      end
      return
    end

    local plugin_name = owner_repo:match("/([^/]+)$")
    --[[@diagnostic disable: redundant-parameter]]
    local confirmed
    if force and status.cooldown[owner_repo] then
      local remaining = entry.remaining_days or 0
      confirmed = vim.fn.confirm(
        string.format(
          "Override cooldown (%d days remaining) — Approve %s -> %s?",
          remaining,
          owner_repo,
          entry.commit:sub(1, 7)
        ),
        "&Yes\n&No",
        2
      )
    else
      confirmed = vim.fn.confirm(string.format("Approve %s -> %s?", owner_repo, entry.commit:sub(1, 7)), "&Yes\n&No")
    end
    --[[@diagnostic enable: redundant-parameter]]
    if confirmed ~= 1 then
      return
    end

    -- Record the old commit before updating
    local old_commit = Lockfile.get_installed_commit(plugin_name)

    print("packard: updating " .. owner_repo .. "...")

    local update_ok = true
    if vim.pack and vim.pack.update then
      local ok, err = pcall(vim.pack.update, { plugin_name }, { force = true })
      if not ok then
        print("packard: update failed: " .. tostring(err))
        update_ok = false
      end
    end

    if not update_ok then
      print("packard: update command failed for " .. owner_repo)
      UI.render()
      return
    end

    -- Read lockfile to get the new commit
    Lockfile.invalidate()
    local new_commit = Lockfile.get_installed_commit(plugin_name)
    local lockfile_changed = old_commit and new_commit and old_commit ~= new_commit

    if not lockfile_changed then
      print("packard: lockfile unchanged for " .. owner_repo .. " — update may not have persisted")
      UI.render()
      return
    end

    -- Log the update only if the PackChanged autocmd hasn't already.
    -- The autocmd fires synchronously during vim.pack.update() and may
    -- have already logged this transition and dequeued the plugin.
    local s = State.read()
    local logs = s.update_log[owner_repo] or {}
    local already_logged = #logs > 0 and logs[1].from == old_commit and logs[1].to == new_commit
    if not already_logged then
      State.log_update(owner_repo, old_commit, new_commit)
    end

    -- Dequeue from pending (idempotent — autocmd may have already done this)
    State.dequeue(owner_repo)

    print("packard: approved " .. owner_repo)

    -- Self-update: prompt to restart so new code takes effect
    if owner_repo == "ruicsh/packard.nvim" then
      --[[@diagnostic disable: redundant-parameter, need-check-nil]]
      local restart = vim.fn.confirm(
        string.format(
          "packard updated: %s → %s. Restart Neovim to use the new version?",
          old_commit:sub(1, 7),
          new_commit:sub(1, 7)
        ),
        "&Restart\n&Later",
        2
      )
      --[[@diagnostic enable: redundant-parameter, need-check-nil]]
      if restart == 1 then
        vim.cmd("restart")
      end
    end

    -- Always refresh the dashboard
    UI.render()
  end

  ---Reject a pending update (permanently blacklist the commit SHA).
  ---On the Clean tab, delegates to `handle_clean_orphans()`.
  ---Shows a confirmation prompt before blacklisting.
  function UI.handle_reject()
    if UI.tab == "clean" then
      UI.handle_clean_orphans()
      return
    end
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

  ---Toggle selection of an orphan for cleanup in the Clean tab.
  ---Selected orphans are tracked in `UI.selected_orphans`.
  function UI.handle_toggle_selection()
    if UI.tab ~= "clean" then
      return
    end
    local line = vim.api.nvim_win_get_cursor(UI.win)[1]
    local item = UI.line_map[line]
    if not item then
      return
    end

    if UI.selected_orphans[item] then
      UI.selected_orphans[item] = nil
    else
      UI.selected_orphans[item] = true
    end
    UI.render()
  end

  ---Clean selected orphans: remove directories and purge stale metadata.
  ---Prompts for confirmation before deletion. Logs each action and refreshes
  ---the dashboard on completion.
  function UI.handle_clean_orphans()
    if not next(UI.selected_orphans) then
      print("packard: no orphans selected")
      return
    end

    local selected = vim.tbl_keys(UI.selected_orphans)
    table.sort(selected)
    --[[@diagnostic disable-next-line: redundant-parameter]]
    local confirmed = vim.fn.confirm(string.format("Delete %d selected orphans?", #selected), "&Yes\n&No")
    if confirmed ~= 1 then
      return
    end

    local s = State.read()
    local results = Orphans.find_orphans(UI.plugins, s)
    local processed_count = 0

    for _, item in ipairs(selected) do
      local cleaned = false
      -- Check if it's a directory orphan
      local is_dir = false
      for _, d in ipairs(results.dirs) do
        if d == item then
          is_dir = true
          break
        end
      end

      if is_dir then
        cleaned = true
        -- Plugin name is the item
        print("packard: cleaning directory " .. item .. "...")
        if vim.pack and vim.pack.del then
          local ok, err = pcall(vim.pack.del, { item })
          if not ok then
            print("packard: failed to delete " .. item .. ": " .. tostring(err))
          end
        else
          -- Fallback for older nvim or if vim.pack.del is missing
          local path = Utils.get_plugin_path(item)
          vim.fn.delete(path, "rf")
        end
      end

      -- Always try to purge state metadata if owner_repo matches
      local is_state = false
      for _, sr in ipairs(results.state) do
        if sr == item then
          is_state = true
          break
        end
      end

      if is_state then
        cleaned = true
        print("packard: purging metadata for " .. item .. "...")
        State.purge_stale_metadata(item)
      end

      -- If it's a directory orphan, it might have state entries too
      if is_dir and not is_state then
        -- Try to find owner_repo in state that matches this dir name
        for owner_repo, _ in pairs(s.queue or {}) do
          if owner_repo:match("/([^/]+)$") == item then
            State.purge_stale_metadata(owner_repo)
          end
        end
        for owner_repo, _ in pairs(s.blacklist or {}) do
          if owner_repo:match("/([^/]+)$") == item then
            State.purge_stale_metadata(owner_repo)
          end
        end
      end

      if cleaned then
        processed_count = processed_count + 1
      end
      UI.selected_orphans[item] = nil
    end

    Lockfile.invalidate()
    UI.render()

    local skipped = #selected - processed_count
    if skipped > 0 then
      print(string.format("packard: cleanup complete (%d processed, %d skipped)", processed_count, skipped))
    else
      print("packard: cleanup complete")
    end
  end

  ---Open a forge compare URL in the default browser for the plugin at the
  ---current cursor row. Supports GitHub, GitLab, and Bitbucket URLs.
  ---Only active on the Pending tab.
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
      vim.ui.open(url)
    else
      print("packard: could not generate compare URL for " .. plugin.url)
    end
  end

  ---Rebuild the plugin under the cursor by running its build step.
  ---Triggers `:Packard build` with the plugin's owner/repo.
  function UI.handle_build()
    local line = vim.api.nvim_win_get_cursor(UI.win)[1]
    local owner_repo = UI.line_map[line]
    if not owner_repo then
      return
    end

    -- Find the plugin
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

    print(string.format("packard: building '%s'...", plugin.owner_repo))
    local ok = Build.run(plugin, { force = true })
    if ok then
      print(string.format("packard: build succeeded for '%s'", plugin.owner_repo))
    else
      print(string.format("packard: build failed for '%s' (see errors above)", plugin.owner_repo))
    end

    -- Refresh the dashboard
    UI.render()
  end

  ---Toggle commit log expansion for the plugin at the current cursor row.
  ---On the Pending tab, shows the diff range (installed..pending).
  ---On the Installed tab, shows the most recent commits.
  function UI.handle_log()
    if UI.tab ~= "pending" and UI.tab ~= "installed" then
      return
    end
    local line = vim.api.nvim_win_get_cursor(UI.win)[1]
    local owner_repo = UI.line_map[line]
    if not owner_repo then
      return
    end

    if UI.expanded_row == owner_repo and UI.expanded_type == "log" then
      UI.expanded_row = nil
      UI.expanded_type = nil
      UI.render()
      return
    end

    -- Find the plugin
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

    local path = Utils.get_plugin_path(plugin)
    local cmd = {
      "git",
      "log",
      "--pretty=format:%h %ct %s",
      "--abbrev-commit",
      "--color=never",
      "--no-show-signature",
    }

    if UI.tab == "pending" then
      local s = State.read()
      local entry = s.queue[owner_repo]
      if not entry then
        return
      end
      local plugin_name = owner_repo:match("/([^/]+)$")
      local from = Lockfile.get_installed_commit(plugin_name)
      if not from then
        print("packard: cannot show log — no installed commit found for " .. plugin_name)
        return
      end
      local to = entry.commit
      table.insert(cmd, from .. ".." .. to)
    else
      table.insert(cmd, "-10") -- Show fewer lines when inline
    end

    -- Run git log
    --[[@diagnostic disable-next-line: redundant-parameter]]
    local obj = vim.system(cmd, { cwd = path }):wait(5000)
    if obj.code ~= 0 then
      print("packard: git log failed for " .. owner_repo)
      return
    end

    local log_entries = {}
    local now = os.time()
    for l in obj.stdout:gmatch("[^\r\n]+") do
      -- Format: hash unix_epoch_timestamp message
      local hash, ts_str, msg = l:match("^(%S+) (%d+) (.+)$")
      if hash and ts_str and msg then
        local ts = tonumber(ts_str)
        if ts then
          local diff = now - ts
          local age = UI._format_age_abbreviated(diff)
          table.insert(log_entries, {
            hash = hash,
            age = age,
            age_width = vim.fn.strdisplaywidth(age),
            msg = msg,
          })
        else
          table.insert(log_entries, { msg = l })
        end
      else
        table.insert(log_entries, { msg = l })
      end
    end

    if #log_entries == 0 then
      table.insert(log_entries, { msg = "No new commits" })
    end

    UI._log_cache[owner_repo] = log_entries
    UI.expanded_row = owner_repo
    UI.expanded_type = "log"
    UI._do_render()
  end

  ---Toggle or trigger AI review for the pending plugin at the cursor row.
  ---If `opts.force` is true, bypasses the cache and forces a re-run.
  ---Results are rendered inline below the row via `_render_ai_expansion`.
  ---@param opts? table Options table; pass `{ force = true }` to re-run.
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

    if UI.expanded_row == owner_repo and UI.expanded_type == "ai" and not opts.force then
      UI.expanded_row = nil
      UI.expanded_type = nil
      UI.render()
      return
    end

    UI.expanded_row = owner_repo
    UI.expanded_type = "ai"
    UI.render()

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
end
