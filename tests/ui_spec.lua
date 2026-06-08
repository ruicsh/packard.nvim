local Helpers = require("tests.helpers")

-- Mock modules
local State = require("packard.state")
local Cooldown = require("packard.cooldown")
local Lockfile = require("packard.lockfile")

local original_state_read = State.read
local original_cooldown_get_status = Cooldown.get_status
local original_lockfile_get_installed = Lockfile.get_installed_commit

--[[@diagnostic disable-next-line: duplicate-set-field]]
State.read = function()
  return { queue = {}, update_log = {}, blacklist = {} }
end
--[[@diagnostic disable-next-line: duplicate-set-field]]
Cooldown.get_status = function()
  return { eligible = {}, cooldown = {} }
end
--[[@diagnostic disable-next-line: duplicate-set-field]]
Lockfile.get_installed_commit = function()
  return "abc1234"
end

local UI = require("packard.ui")

Helpers.describe("UI Dashboard", function()
  Helpers.it("opens with default tab", function()
    UI.open({}, "installed")
    Helpers.expect(UI.tab).to_be("installed")
    Helpers.expect(vim.api.nvim_buf_is_valid(UI.buf)).to_be_truthy()

    -- Check if it rendered (headers should be there)
    -- We need to wait for vim.schedule
    vim.wait(100, function()
      return not UI._render_scheduled
    end)

    local lines = vim.api.nvim_buf_get_lines(UI.buf, 0, -1, false)
    local found = false
    for _, line in ipairs(lines) do
      if line:match("Installed") and line:match("Pending") then
        found = true
        break
      end
    end
    Helpers.expect(found).to_be_truthy()
    UI.close()
  end)

  Helpers.it("switches tabs", function()
    UI.open({}, "installed")

    UI.tab = "pending"
    UI._do_render() -- Bypass schedule for sync test
    local lines = vim.api.nvim_buf_get_lines(UI.buf, 0, -1, false)
    local found = false
    for _, line in ipairs(lines) do
      if line:match("Pending") then
        found = true
        break
      end
    end
    Helpers.expect(found).to_be_truthy()
    UI.close()
  end)

  Helpers.it("shows help tab", function()
    UI.open({}, "help")
    UI._do_render()
    local lines = vim.api.nvim_buf_get_lines(UI.buf, 0, -1, false)
    local found_intro = false
    local found_nav = false
    for _, line in ipairs(lines) do
      if line:match("packard") then
        found_intro = true
      elseif line:match("^  Navigation$") then
        found_nav = true
      end
    end
    Helpers.expect(found_intro).to_be_truthy()
    Helpers.expect(found_nav).to_be_truthy()
    UI.close()
  end)

  Helpers.it("opens update tab with idle state", function()
    UI.open({}, "update")
    UI._do_render()
    local lines = vim.api.nvim_buf_get_lines(UI.buf, 0, -1, false)
    local found_prompt = false
    for _, line in ipairs(lines) do
      if line:match("Press U to check") then
        found_prompt = true
        break
      end
    end
    Helpers.expect(found_prompt).to_be_truthy()
    UI.close()
  end)

  Helpers.it("renders update tab done state with results", function()
    UI.open({}, "update")
    UI.check_state = "done"
    UI.check_new_count = 3
    UI.check_eligible = 1
    UI.check_cooldown = 2
    UI._do_render()
    local lines = vim.api.nvim_buf_get_lines(UI.buf, 0, -1, false)
    local found_count = false
    local found_eligible = false
    for _, line in ipairs(lines) do
      if line:match("3 new commit") then
        found_count = true
      end
      if line:match("1 eligible") then
        found_eligible = true
      end
    end
    Helpers.expect(found_count).to_be_truthy()
    Helpers.expect(found_eligible).to_be_truthy()
    UI.check_state = "idle"
    UI.check_new_count = 0
    UI.check_eligible = 0
    UI.check_cooldown = 0
    UI.close()
  end)

  Helpers.it("renders update tab done state with no results", function()
    UI.open({}, "update")
    UI.check_state = "done"
    UI.check_new_count = 0
    UI.check_eligible = 0
    UI.check_cooldown = 0
    UI._do_render()
    local lines = vim.api.nvim_buf_get_lines(UI.buf, 0, -1, false)
    local found_up_to_date = false
    for _, line in ipairs(lines) do
      if line:match("All plugins are up to date") then
        found_up_to_date = true
        break
      end
    end
    Helpers.expect(found_up_to_date).to_be_truthy()
    UI.check_state = "idle"
    UI.check_new_count = 0
    UI.check_eligible = 0
    UI.check_cooldown = 0
    UI.close()
  end)

  Helpers.it("renders update tab error state", function()
    UI.open({}, "update")
    UI.check_state = "error"
    UI.check_error_msg = "network unreachable"
    UI._do_render()
    local lines = vim.api.nvim_buf_get_lines(UI.buf, 0, -1, false)
    local found_error = false
    for _, line in ipairs(lines) do
      if line:match("network unreachable") then
        found_error = true
        break
      end
    end
    Helpers.expect(found_error).to_be_truthy()
    UI.check_state = "idle"
    UI.check_new_count = 0
    UI.check_eligible = 0
    UI.check_cooldown = 0
    UI.check_error_msg = nil
    UI.close()
  end)

  Helpers.it("renders update tab running state", function()
    UI.open({}, "update")
    UI.check_state = "running"
    UI._do_render()
    local lines = vim.api.nvim_buf_get_lines(UI.buf, 0, -1, false)
    local found_running = false
    for _, line in ipairs(lines) do
      if line:match("Checking for updates") then
        found_running = true
        break
      end
    end
    Helpers.expect(found_running).to_be_truthy()
    UI.check_state = "idle"
    UI.check_new_count = 0
    UI.check_eligible = 0
    UI.check_cooldown = 0
    UI.check_error_msg = nil
    UI.close()
  end)

  Helpers.it("shows U keybinding in help tab", function()
    UI.open({}, "help")
    UI._do_render()
    local lines = vim.api.nvim_buf_get_lines(UI.buf, 0, -1, false)
    local found_u = false
    for _, line in ipairs(lines) do
      if line:match("^    U") and line:match("Check for updates") then
        found_u = true
        break
      end
    end
    Helpers.expect(found_u).to_be_truthy()
    UI.close()
  end)

  Helpers.it("renders AI expansion", function()
    UI.open({}, "pending")
    UI.ai_results = {
      ["owner/repo"] = {
        state = "result",
        data = {
          summary = "This is a summary of the AI review.",
          risk = "low",
          reasoning = "The reasoning behind the risk level.",
        },
      },
    }
    UI.expanded_row = "owner/repo"
    UI.expanded_type = "ai"

    -- Mock Cooldown.get_status to return our plugin
    local old_get_status = Cooldown.get_status
    --[[@diagnostic disable-next-line: duplicate-set-field]]
    Cooldown.get_status = function()
      return {
        eligible = {
          ["owner/repo"] = { commit = "abcdef1", remaining_days = 0 },
        },
        cooldown = {},
      }
    end

    UI._do_render()

    local lines = vim.api.nvim_buf_get_lines(UI.buf, 0, -1, false)
    local found_expansion = false
    local found_summary = false
    local found_spinner = false
    for _, line in ipairs(lines) do
      if line:match("AI Review") then
        found_expansion = true
      end
      if line:match("Summary:") and line:match("This is a summary") then
        found_summary = true
      end
    end

    Helpers.expect(found_expansion).to_be_truthy()
    Helpers.expect(found_summary).to_be_truthy()

    -- Test loading state (spinner)
    UI.ai_results["owner/repo"] = { state = "loading" }
    UI._do_render()
    lines = vim.api.nvim_buf_get_lines(UI.buf, 0, -1, false)
    for _, line in ipairs(lines) do
      if line:match("AI review in progress") then
        found_spinner = true
      end
    end
    Helpers.expect(found_spinner).to_be_truthy()
    -- Cleanup
    Cooldown.get_status = old_get_status
    UI.ai_results = {}
    UI.expanded_row = nil
    UI.close()
  end)

  Helpers.it("highlights selected plugin name", function()
    local plugins = { { name = "foo/bar", owner_repo = "foo/bar" }, { name = "baz/qux", owner_repo = "baz/qux" } }
    UI.open(plugins, "installed")
    UI._do_render()

    -- Find the line for "foo/bar"
    local line_idx = nil
    for i, owner_repo in pairs(UI.line_map) do
      if owner_repo == "foo/bar" then
        line_idx = i
        break
      end
    end
    Helpers.expect(line_idx).to_be_truthy()

    -- Simulate cursor on that line
    UI._cursor_repo = "foo/bar"
    UI.apply_highlights()

    local packard_ns = vim.api.nvim_create_namespace("packard")
    local extmarks = vim.api.nvim_buf_get_extmarks(UI.buf, packard_ns, 0, -1, { details = true })
    local found_selected = false
    for _, em in ipairs(extmarks) do
      local row = em[2]
      local details = em[4]
      if row == line_idx - 1 and details.hl_group == "PackardPluginNameSelected" then
        found_selected = true
        break
      end
    end
    Helpers.expect(found_selected).to_be_truthy()

    -- Also verify PackardRowSelected is present on the selected row
    local found_row_selected = false
    for _, em in ipairs(extmarks) do
      local row = em[2]
      local details = em[4]
      if row == line_idx - 1 and details.hl_group == "PackardRowSelected" then
        found_row_selected = true
        break
      end
    end
    Helpers.expect(found_row_selected).to_be_truthy()

    -- Move cursor away
    UI._cursor_repo = "baz/qux"
    UI.apply_highlights()

    extmarks = vim.api.nvim_buf_get_extmarks(UI.buf, packard_ns, 0, -1, { details = true })
    found_selected = false
    local found_normal = false
    found_row_selected = false
    for _, em in ipairs(extmarks) do
      local row = em[2]
      local details = em[4]
      if row == line_idx - 1 then
        if details.hl_group == "PackardPluginNameSelected" then
          found_selected = true
        elseif details.hl_group == "PackardPluginName" then
          found_normal = true
        elseif details.hl_group == "PackardRowSelected" then
          found_row_selected = true
        end
      end
    end
    Helpers.expect(found_selected).to_be(false)
    Helpers.expect(found_normal).to_be_truthy()
    -- Verify PackardRowSelected is removed when cursor moves away
    Helpers.expect(found_row_selected).to_be(false)

    UI.close()
  end)

  Helpers.it("aligns columns correctly with long branch names", function()
    local plugins = {
      {
        name = "short-name",
        owner_repo = "a/short",
        branch = "main",
        minimum_release_age = 30,
      },
      {
        name = "long-branch",
        owner_repo = "b/long",
        branch = "very-long-feature-branch-name",
        minimum_release_age = 30,
      },
    }

    local old_isdirectory = vim.fn.isdirectory
    --[[@diagnostic disable-next-line: duplicate-set-field]]
    vim.fn.isdirectory = function()
      return 1
    end

    UI.open(plugins, "installed")
    UI._do_render()

    local lines = vim.api.nvim_buf_get_lines(UI.buf, 0, -1, false)
    local short_line = ""
    local long_line = ""

    for _, line in ipairs(lines) do
      if line:match("a/short") then
        short_line = line
      end
      if line:match("b/long") then
        long_line = line
      end
    end

    -- The branch column should be aligned
    -- Format: icon name commit branch age
    -- "    ● a/short                         abc1234     main                            30d"
    -- "    ● b/long                          abc1234     very-long-feature-branch-name   30d"

    -- We can check if the '30d' (age) starts at the same column
    local short_age_pos = short_line:find("30d")
    local long_age_pos = long_line:find("30d")

    Helpers.expect(short_age_pos).to_be_truthy()
    Helpers.expect(long_age_pos).to_be_truthy()
    Helpers.expect(short_age_pos).to_be(long_age_pos)

    -- Cleanup
    vim.fn.isdirectory = old_isdirectory
    UI.close()
  end)

  Helpers.describe("handle_log", function()
    Helpers.it("shows log between installed and pending in Pending tab (inline)", function()
      local plugin =
        { name = "test-plugin", owner_repo = "test/test-plugin", url = "https://github.com/test/test-plugin" }
      UI.open({ plugin }, "pending")
      UI._cursor_repo = "test/test-plugin"

      -- Mock State.read for queue entry
      local old_state_read = State.read
      --[[@diagnostic disable-next-line: duplicate-set-field]]
      State.read = function()
        return { queue = { ["test/test-plugin"] = { commit = "pending_sha" } } }
      end

      -- Mock Lockfile
      local old_lockfile = Lockfile.get_installed_commit
      --[[@diagnostic disable-next-line: duplicate-set-field]]
      Lockfile.get_installed_commit = function()
        return "installed_sha"
      end

      -- Mock Cooldown.get_status
      local old_get_status = Cooldown.get_status
      --[[@diagnostic disable-next-line: duplicate-set-field]]
      Cooldown.get_status = function()
        return {
          eligible = { ["test/test-plugin"] = { commit = "pending_sha", discovered_at = "..." } },
          cooldown = {},
        }
      end

      UI._do_render()

      -- Find line index
      local line_idx
      for idx, repo in pairs(UI.line_map) do
        if repo == "test/test-plugin" then
          line_idx = idx
          break
        end
      end
      Helpers.expect(line_idx).to_be_truthy()
      vim.api.nvim_win_set_cursor(UI.win, { line_idx, 0 })

      -- Mock vim.system
      local original_system = vim.system
      local git_cmd_called = false
      --[[@diagnostic disable-next-line: duplicate-set-field]]
      vim.system = function(cmd, opts)
        if cmd[1] == "git" and cmd[2] == "log" then
          git_cmd_called = true
          Helpers.expect(cmd[#cmd]).to_be("installed_sha..pending_sha")
          return {
            wait = function()
              return { code = 0, stdout = "abc1234 Commit message (2 days ago)\n" }
            end,
          }
        end
        return original_system(cmd, opts)
      end

      -- Call handler
      UI.handle_log()

      Helpers.expect(git_cmd_called).to_be_truthy()
      Helpers.expect(UI.expanded_row).to_be("test/test-plugin")
      Helpers.expect(UI.expanded_type).to_be("log")

      -- Check if expansion is rendered in the buffer
      local lines = vim.api.nvim_buf_get_lines(UI.buf, 0, -1, false)
      local found_log = false
      for _, line in ipairs(lines) do
        if line:match("Commit Log") or line:match("abc1234 Commit message") then
          found_log = true
        end
      end
      Helpers.expect(found_log).to_be_truthy()

      -- Cleanup
      vim.system = original_system
      State.read = old_state_read
      Lockfile.get_installed_commit = old_lockfile
      Cooldown.get_status = old_get_status
      UI.close()
    end)

    Helpers.it("shows recent commits in Installed tab (inline)", function()
      local plugin =
        { name = "test-plugin", owner_repo = "test/test-plugin", url = "https://github.com/test/test-plugin" }
      UI.open({ plugin }, "installed")
      UI._cursor_repo = "test/test-plugin"

      -- Mock Lockfile
      local old_lockfile = Lockfile.get_installed_commit
      --[[@diagnostic disable-next-line: duplicate-set-field]]
      Lockfile.get_installed_commit = function()
        return "installed_sha"
      end

      UI._do_render()

      -- Find line index
      local line_idx
      for idx, repo in pairs(UI.line_map) do
        if repo == "test/test-plugin" then
          line_idx = idx
          break
        end
      end
      Helpers.expect(line_idx).to_be_truthy()
      vim.api.nvim_win_set_cursor(UI.win, { line_idx, 0 })

      -- Mock vim.system
      local original_system = vim.system
      local git_cmd_called = false
      --[[@diagnostic disable-next-line: duplicate-set-field]]
      vim.system = function(cmd, opts)
        if cmd[1] == "git" and cmd[2] == "log" then
          git_cmd_called = true
          Helpers.expect(cmd[#cmd]).to_be("-10")
          return {
            wait = function()
              return { code = 0, stdout = "abc1234 Commit message (2 days ago)\n" }
            end,
          }
        end
        return original_system(cmd, opts)
      end

      -- Call handler
      UI.handle_log()

      Helpers.expect(git_cmd_called).to_be_truthy()
      Helpers.expect(UI.expanded_row).to_be("test/test-plugin")
      Helpers.expect(UI.expanded_type).to_be("log")

      -- Cleanup
      vim.system = original_system
      Lockfile.get_installed_commit = old_lockfile
      UI.close()
    end)

    Helpers.it("shows 'No new commits' when log is empty (inline)", function()
      local plugin =
        { name = "test-plugin", owner_repo = "test/test-plugin", url = "https://github.com/test/test-plugin" }
      UI.open({ plugin }, "pending")
      UI._cursor_repo = "test/test-plugin"

      -- Mock State.read for queue entry
      local old_state_read = State.read
      --[[@diagnostic disable-next-line: duplicate-set-field]]
      State.read = function()
        return { queue = { ["test/test-plugin"] = { commit = "same_sha" } } }
      end
      -- Mock Lockfile
      local old_lockfile = Lockfile.get_installed_commit
      --[[@diagnostic disable-next-line: duplicate-set-field]]
      Lockfile.get_installed_commit = function()
        return "same_sha"
      end
      -- Mock Cooldown.get_status
      local old_get_status = Cooldown.get_status
      --[[@diagnostic disable-next-line: duplicate-set-field]]
      Cooldown.get_status = function()
        return {
          eligible = { ["test/test-plugin"] = { commit = "same_sha", discovered_at = "..." } },
          cooldown = {},
        }
      end

      UI._do_render()

      -- Find line index
      local line_idx
      for idx, repo in pairs(UI.line_map) do
        if repo == "test/test-plugin" then
          line_idx = idx
          break
        end
      end
      Helpers.expect(line_idx).to_be_truthy()
      vim.api.nvim_win_set_cursor(UI.win, { line_idx, 0 })

      -- Mock vim.system
      local original_system = vim.system
      --[[@diagnostic disable-next-line: duplicate-set-field]]
      vim.system = function(cmd, opts)
        if cmd[1] == "git" and cmd[2] == "log" then
          return {
            wait = function()
              return { code = 0, stdout = "" }
            end,
          }
        end
        return original_system(cmd, opts)
      end

      -- Call handler
      UI.handle_log()

      local lines = vim.api.nvim_buf_get_lines(UI.buf, 0, -1, false)
      local found_no_commits = false
      for _, line in ipairs(lines) do
        if line:match("No new commits") then
          found_no_commits = true
        end
      end
      Helpers.expect(found_no_commits).to_be_truthy()

      -- Cleanup
      vim.system = original_system
      State.read = old_state_read
      Lockfile.get_installed_commit = old_lockfile
      Cooldown.get_status = old_get_status
      UI.close()
    end)
  end)
end)

-- Mock Orphans module for clean handler tests
local Orphans = require("packard.orphans")
local original_orphans_find = Orphans.find_orphans
--[[@diagnostic disable-next-line: duplicate-set-field]]
Orphans.find_orphans = function(_plugins, _state)
  return {
    dirs = { "orphan-dir" },
    state = { "orphan/state" },
  }
end

local original_ui_handle_clean_orphans = UI.handle_clean_orphans

Helpers.describe("handle_clean_orphans", function()
  Helpers.it("cleans selected orphans", function()
    local plugins = {}
    UI.open(plugins, "clean")

    -- Mock State.purge_stale_metadata
    local purged = {}
    local original_purge = State.purge_stale_metadata
    --[[@diagnostic disable-next-line: duplicate-set-field]]
    State.purge_stale_metadata = function(owner_repo)
      table.insert(purged, owner_repo)
    end

    -- Mock vim.pack.del
    local deleted_dirs = {}
    local original_pack_del = vim.pack and vim.pack.del
    if not vim.pack then
      vim.pack = {}
    end
    --[[@diagnostic disable-next-line: duplicate-set-field]]
    vim.pack.del = function(names)
      for _, name in ipairs(names) do
        table.insert(deleted_dirs, name)
      end
      return true
    end

    -- Select orphans
    UI.selected_orphans["orphan-dir"] = true
    UI.selected_orphans["orphan/state"] = true

    -- Mock vim.fn.confirm to return Yes
    local original_confirm = vim.fn.confirm
    --[[@diagnostic disable-next-line: duplicate-set-field]]
    vim.fn.confirm = function(_msg, _choices)
      return 1 -- Yes
    end

    -- Mock State.read
    local old_state_read = State.read
    --[[@diagnostic disable-next-line: duplicate-set-field]]
    State.read = function()
      return { queue = {}, blacklist = {}, update_log = {} }
    end

    UI.handle_clean_orphans()

    -- Verify dir was cleaned
    Helpers.expect(#deleted_dirs >= 1).to_be_truthy()
    local found_dir = false
    for _, d in ipairs(deleted_dirs) do
      if d == "orphan-dir" then
        found_dir = true
        break
      end
    end
    Helpers.expect(found_dir).to_be_truthy()

    -- Verify state was purged
    local found_state = false
    for _, sr in ipairs(purged) do
      if sr == "orphan/state" then
        found_state = true
        break
      end
    end
    Helpers.expect(found_state).to_be_truthy()

    -- Cleanup
    State.purge_stale_metadata = original_purge
    State.read = old_state_read
    vim.fn.confirm = original_confirm
    UI.selected_orphans = {}
    UI.close()
  end)

  Helpers.it("shows warning when no orphans selected", function()
    UI.open({}, "clean")
    UI.selected_orphans = {}

    local print_calls = {}
    local original_print = print
    print = function(msg)
      table.insert(print_calls, msg)
    end

    -- Mock vim.fn.confirm
    local original_confirm = vim.fn.confirm
    --[[@diagnostic disable-next-line: duplicate-set-field]]
    vim.fn.confirm = function()
      return 1
    end

    UI.handle_clean_orphans()

    local found = false
    for _, msg in ipairs(print_calls) do
      if msg:find("no orphans") then
        found = true
        break
      end
    end
    Helpers.expect(found).to_be_truthy()

    print = original_print
    vim.fn.confirm = original_confirm
    UI.close()
  end)
end)

-- Restore
State.read = original_state_read
Cooldown.get_status = original_cooldown_get_status
Lockfile.get_installed_commit = original_lockfile_get_installed
Orphans.find_orphans = original_orphans_find
