local Helpers = require("tests.helpers")

-- Mock file system for State and Lockfile
local mock_files = {}
local original_io_open = io.open
--[[@diagnostic disable-next-line: duplicate-set-field]]
io.open = function(path, mode)
  if mode == "r" then
    if mock_files[path] then
      return {
        read = function()
          return mock_files[path]
        end,
        close = function() end,
      }
    end
    return nil
  elseif mode == "w" or mode == "w+" then
    return {
      write = function(self, content)
        mock_files[path] = content
      end,
      close = function() end,
    }
  end
  return original_io_open(path, mode)
end

local original_filereadable = vim.fn.filereadable
vim.fn.filereadable = function(path)
  return mock_files[path] and 1 or 0
end

local original_mkdir = vim.fn.mkdir
vim.fn.mkdir = function()
  return 1
end

-- Mock git and network
local original_system = vim.system
--[[@diagnostic disable-next-line: duplicate-set-field]]
vim.system = function(cmd, opts)
  local cmd_str = table.concat(cmd, " ")
  local res = { code = 0, stdout = "", stderr = "" }
  if cmd_str:match("ls%-remote") then
    if cmd_str:match("--symref") then
      res.stdout = "ref: refs/heads/main\tHEAD\nsha123\tHEAD"
    else
      res.stdout = "sha123\tHEAD"
    end
  elseif cmd_str:match("rev%-parse") then
    res.stdout = "sha123\n"
  elseif cmd_str:match("fetch") then
    res.code = 0
  end
  return {
    wait = function()
      return res
    end,
  }
end

local original_isdirectory = vim.fn.isdirectory
--[[@diagnostic disable-next-line: duplicate-set-field]]
vim.fn.isdirectory = function(path)
  if path:match("core/opt/repo") then
    return 1
  end
  return 0
end

-- Mock Neovim built-ins
local original_pack = vim.pack
vim.pack = {
  add = function() end,
  get = function()
    return {}
  end,
  update = function(opts)
    -- Simulate what Neovim does: update the lockfile on disk, then fire
    -- PackChanged so the autocmd picks up the before/after comparison.
    local names = type(opts) == "table" and opts or {}
    local lock_path = vim.fs.joinpath(vim.fn.stdpath("config"), "nvim-pack-lock.json")
    for _, name in ipairs(names) do
      -- Write new lockfile data before firing the event
      if mock_files[lock_path] then
        local lockdata = vim.fn.json_decode(mock_files[lock_path])
        if lockdata.plugins and lockdata.plugins[name] then
          lockdata.plugins[name].rev = "sha123"
        elseif lockdata[name] then
          lockdata[name].ref = "sha123"
        end
        mock_files[lock_path] = vim.fn.json_encode(lockdata)
      end
      vim.api.nvim_exec_autocmds("PackChanged", {
        pattern = name,
        data = {
          active = true,
          kind = "update",
          spec = { name = name },
          path = vim.fn.stdpath("data") .. "/site/pack/core/opt/" .. name,
        },
      })
    end
  end,
}

local packard = require("packard")

Helpers.describe("End-to-end flow", function()
  Helpers.it("completes a full update cycle", function()
    -- 1. Setup
    packard.setup({
      plugins = { "user/repo" },
      defaults = { minimum_release_age = 0 }, -- Eligible immediately
      self_management = false,
    })

    -- 2. Check for updates
    -- Mock lockfile to have an old commit
    local lock_path = vim.fs.joinpath(vim.fn.stdpath("config"), "nvim-pack-lock.json")
    mock_files[lock_path] = vim.fn.json_encode({ repo = { ref = "old-sha" } })

    packard.check()

    -- 3. Verify it's in the queue
    local State = require("packard.state")
    local state = State.read()
    if not state.queue["user/repo"] then
      print("Queue content: " .. vim.inspect(state.queue))
    end
    Helpers.expect(state.queue["user/repo"] ~= nil).to_be_truthy()
    if state.queue["user/repo"] and state.queue["user/repo"].commit ~= "sha123" then
      print("Commit in queue: '" .. state.queue["user/repo"].commit .. "'")
    end
    Helpers.expect(state.queue["user/repo"].commit).to_be("sha123")

    -- 4. Open UI and approve
    local UI = require("packard.ui")
    UI.open(packard.plugins, "pending")

    -- Mock vim.fn.confirm to return 1 (Yes)
    local original_confirm = vim.fn.confirm
    vim.fn.confirm = function()
      return 1
    end

    UI._do_render()
    local target_line = 0
    for line, owner_repo in pairs(UI.line_map) do
      if owner_repo == "user/repo" then
        target_line = line
        break
      end
    end

    Helpers.expect(target_line > 0).to_be_truthy()
    vim.api.nvim_win_set_cursor(UI.win, { target_line, 0 })

    -- No Lockfile.read mock needed: the real implementation reads from
    -- mock_files via io.open, and the vim.pack.update mock above writes
    -- the new lockfile before firing PackChanged.  This exercises the
    -- autocmd's actual before/after comparison.

    UI.handle_approve()

    -- 5. Verify it's dequeued and logged (autocmd logs, handle_approve deduplicates)
    state = State.read()
    Helpers.expect(state.queue["user/repo"]).to_be_nil()
    Helpers.expect(state.update_log["user/repo"] ~= nil).to_be_truthy()
    Helpers.expect(#state.update_log["user/repo"]).to_be(1)
    Helpers.expect(state.update_log["user/repo"][1].from).to_be("old-sha")
    Helpers.expect(state.update_log["user/repo"][1].to).to_be("sha123")

    -- Restore
    vim.fn.confirm = original_confirm
    UI.close()
  end)

  Helpers.it("recovers gracefully when vim.pack.add fails", function()
    -- Mock vim.pack.add to throw a git auth error
    local add_called = false
    vim.pack.add = function()
      add_called = true
      error("fatal: could not read Username for 'https://github.com': Device not configured")
    end
    -- Mock vim.pack.get to return nothing (nothing got installed)
    vim.pack.get = function()
      return {}
    end

    -- Setup must not crash
    local setup_ok, setup_err = pcall(packard.setup, {
      plugins = { "user/repo" },
      self_management = false,
    })

    if not setup_ok then
      print("Setup failed: " .. tostring(setup_err))
    end
    Helpers.expect(setup_ok).to_be_truthy()
    Helpers.expect(add_called).to_be(true)

    -- Should have detected offline status from error message
    --[[@diagnostic disable-next-line: invisible]]
    Helpers.expect(packard._is_offline).to_be_truthy()
  end)

  Helpers.it("installs remaining plugins when one fails", function()
    -- Reset offline flag
    --[[@diagnostic disable-next-line: invisible]]
    packard._is_offline = false

    -- With batch install, vim.pack.add is called once with all specs.
    -- Neovim installs them in parallel; if one fails it throws, but the
    -- others may still be on disk. We simulate this by having the mock
    -- throw and having vim.pack.get return only the successful ones.
    vim.pack.add = function(specs)
      -- Check if any spec in the batch is "bad"
      for _, spec in ipairs(specs) do
        if spec.name == "repo" then
          error("fatal: could not read Username for 'https://github.com': Device not configured")
        end
      end
    end
    -- Mock vim.pack.get to return only the successfully installed plugins
    vim.pack.get = function()
      return {
        { spec = { name = "repo1" } },
        { spec = { name = "repo2" } },
      }
    end

    packard.setup({
      plugins = { "good1/repo1", "bad/repo", "good2/repo2" },
      self_management = false,
    })

    --[[@diagnostic disable-next-line: invisible]]
    Helpers.expect(packard._is_offline).to_be_truthy()
  end)

  Helpers.it("reports per-plugin error messages from batch install", function()
    -- Reset state
    --[[@diagnostic disable-next-line: invisible]]
    packard._is_offline = false

    -- Mock vim.pack.add to throw with Neovim's structured error format
    vim.pack.add = function(specs)
      error(
        "vim.pack:\n\n"
          .. "`repo`:\n"
          .. "fatal: could not read Username for 'https://github.com': Device not configured\n\n"
          .. "`repo2`:\n"
          .. "fatal: unable to access 'https://github.com/user/repo2.git': Could not resolve host"
      )
    end
    vim.pack.get = function()
      return {
        { spec = { name = "repo1" } },
      }
    end

    -- Capture vim.notify calls
    local notifications = {}
    local original_notify = vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, level)
      table.insert(notifications, { msg = msg, level = level })
    end

    packard.setup({
      plugins = { "good/repo1", "bad/repo", "bad2/repo2" },
      self_management = false,
    })

    vim.notify = original_notify

    -- Filter only ERROR-level notifications (debug instrumentation adds INFO/WARN)
    local error_notifications = {}
    for _, n in ipairs(notifications) do
      if n.level == vim.log.levels.ERROR then
        table.insert(error_notifications, n)
      end
    end
    Helpers.expect(#error_notifications).to_be(1)
    local n = error_notifications[1]
    Helpers.expect(n.level).to_be(vim.log.levels.ERROR)

    -- Should contain the specific error message for repo (auth error)
    Helpers.expect(n.msg:match("repo:") ~= nil).to_be_truthy()
    Helpers.expect(n.msg:match("Device not configured") ~= nil).to_be_truthy()
    -- Should contain the specific error message for repo2 (network error)
    Helpers.expect(n.msg:match("repo2:") ~= nil).to_be_truthy()
    Helpers.expect(n.msg:match("Could not resolve host") ~= nil).to_be_truthy()
  end)

  Helpers.it("force-approve bypasses cooldown", function()
    local State = require("packard.state")
    local state_path = vim.fs.joinpath(vim.fn.stdpath("state"), "packard-state.json")
    local lock_path = vim.fs.joinpath(vim.fn.stdpath("config"), "nvim-pack-lock.json")

    -- Pre-populate state with a queue entry just discovered (in cooldown)
    local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
    mock_files[state_path] = vim.fn.json_encode({
      queue = {
        ["user/repo"] = {
          commit = "sha123",
          discovered_at = now,
          tag = nil,
        },
      },
      blacklist = {},
      update_log = {},
    })
    State.invalidate()

    -- Lockfile with old commit so handle_approve detects the transition
    mock_files[lock_path] = vim.fn.json_encode({ repo = { ref = "old-sha" } })

    -- Reset vim.pack overrides from prior tests to the original no-op stubs
    vim.pack.add = function() end
    vim.pack.get = function() return {} end

    -- Setup with a high min_age so the entry stays in cooldown
    packard.setup({
      plugins = { { "user/repo", minimum_release_age = 30 } },
      self_management = false,
    })

    local Lockfile = require("packard.lockfile")
    Lockfile.invalidate()

    local UI = require("packard.ui")
    UI.open(packard.plugins, "pending")

    -- Mock confirm to answer Yes
    local original_confirm = vim.fn.confirm
    vim.fn.confirm = function(_msg, _buttons, _default)
      return 1
    end

    UI._do_render()
    local target_line = 0
    for line, owner_repo in pairs(UI.line_map) do
      if owner_repo == "user/repo" then
        target_line = line
        break
      end
    end
    Helpers.expect(target_line > 0).to_be_truthy()
    vim.api.nvim_win_set_cursor(UI.win, { target_line, 0 })

    -- 1. Normal approve (no force) should NOT work on cooldown entry
    UI.handle_approve()
    local s = State.read()
    if not s.queue["user/repo"] then
      print("Queue should still contain the entry after non-force approve, got: " .. vim.inspect(s))
    end
    Helpers.expect(s.queue["user/repo"] ~= nil).to_be_truthy()

    -- 2. Force approve SHOULD work on cooldown entry
    UI.handle_approve(true)

    -- 3. Verify dequeued and logged
    s = State.read()
    Helpers.expect(s.queue["user/repo"]).to_be_nil()
    Helpers.expect(s.update_log["user/repo"] ~= nil).to_be_truthy()
    Helpers.expect(#s.update_log["user/repo"]).to_be(1)
    Helpers.expect(s.update_log["user/repo"][1].from).to_be("old-sha")
    Helpers.expect(s.update_log["user/repo"][1].to).to_be("sha123")

    -- Restore
    vim.fn.confirm = original_confirm
    UI.close()
  end)

  Helpers.it("populates lockfile after clean install so commits are not unknown", function()
    local Lockfile = require("packard.lockfile")
    local lock_path = vim.fs.joinpath(vim.fn.stdpath("config"), "nvim-pack-lock.json")

    -- Clear any leftover state from prior tests
    Lockfile.invalidate()
    mock_files[lock_path] = nil

    -- Mock vim.pack.add to simulate what Neovim does on real install:
    -- write the lockfile, then fire PackChanged so the autocmd refreshes.
    vim.pack.add = function()
      mock_files[lock_path] = vim.fn.json_encode({
        plugins = {
          repo = {
            src = "https://github.com/user/repo.git",
            rev = "abc1234deadbeef000000000000000000000000",
          },
        },
      })
      vim.api.nvim_exec_autocmds("PackChanged", {
        pattern = "repo",
        data = {
          active = false,
          kind = "install",
          spec = { name = "repo" },
          path = vim.fn.stdpath("data") .. "/site/pack/core/opt/repo",
        },
      })
    end
    vim.pack.get = function()
      return {
        { spec = { name = "repo" } },
      }
    end

    packard.setup({
      plugins = { "user/repo" },
      self_management = false,
    })

    -- The lockfile should now be readable with the correct SHA
    local sha = Lockfile.get_installed_commit("repo")
    Helpers.expect(sha).to_be("abc1234deadbeef000000000000000000000000")
  end)
end)

-- Restore global mocks
io.open = original_io_open
vim.fn.filereadable = original_filereadable
vim.fn.mkdir = original_mkdir
vim.system = original_system
vim.fn.isdirectory = original_isdirectory
vim.pack = original_pack
