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

-- Mock os.rename to stay within mock_files (State.write() uses the
-- temp → final atomic rename pattern, which fails on Windows when
-- the temp file only exists in mock_files, not on the real filesystem).
local original_rename = os.rename
os.rename = function(old, new)
  mock_files[new] = mock_files[old]
  mock_files[old] = nil
  return true
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
      res.stdout = "ref: refs/heads/main\tHEAD\nsha-new\tHEAD"
    else
      res.stdout = "sha-new\tHEAD"
    end
  elseif cmd_str:match("rev%-parse") then
    res.stdout = "sha-new\n"
  elseif cmd_str:match("fetch") then
    res.code = 0
  end
  return {
    wait = function()
      return res
    end,
  }
end

-- Mock isdirectory: packard.nvim and user/repo must appear installed
local original_isdirectory = vim.fn.isdirectory
--[[@diagnostic disable-next-line: duplicate-set-field]]
vim.fn.isdirectory = function(path)
  if path:match("packard%.nvim$") then
    return 1
  end
  if path:match("core/opt/repo") then
    return 1
  end
  return 0
end

-- Track whether vim.pack.update was called with packard's name
local update_called_with = nil

-- Mock vim.pack
local original_pack = vim.pack
vim.pack = {
  add = function() end,
  get = function()
    return {
      { spec = { name = "packard.nvim" } },
    }
  end,
  update = function(opts, extra_opts)
    update_called_with = opts
    -- Simulate what Neovim does: update the lockfile on disk, then fire
    -- PackChanged so the autocmd picks up the before/after comparison.
    local names = type(opts) == "table" and opts or {}
    local lock_path = vim.fs.joinpath(vim.fn.stdpath("config"), "nvim-pack-lock.json")
    for _, name in ipairs(names) do
      if mock_files[lock_path] then
        local lockdata = vim.fn.json_decode(mock_files[lock_path])
        if lockdata.plugins and lockdata.plugins[name] then
          lockdata.plugins[name].rev = "sha-new"
        elseif lockdata[name] then
          lockdata[name].ref = "sha-new"
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

Helpers.describe("Self-management update flow", function()
  Helpers.it("includes packard in plugin list and supports its update cycle", function()
    -- 1. Setup with self_management = true
    packard.setup({
      plugins = { "user/repo" },
      defaults = { minimum_release_age = 0 },
      self_management = true,
    })

    -- 2. Verify packard.nvim is in the normalized plugin list
    local found_packard = false
    for _, p in ipairs(packard.plugins) do
      if p.owner_repo == "ruicsh/packard.nvim" then
        found_packard = true
        Helpers.expect(p.name).to_be("packard.nvim")
        Helpers.expect(p.url).to_be("https://github.com/ruicsh/packard.nvim.git")
        Helpers.expect(p.is_local).to_be(false)
        break
      end
    end
    Helpers.expect(found_packard).to_be(true)
    -- packard should be first (injected at index 1)
    Helpers.expect(packard.plugins[1].owner_repo).to_be("ruicsh/packard.nvim")

    -- 3. Pre-populate lockfile with old commits so the check detects a new SHA
    local lock_path = vim.fs.joinpath(vim.fn.stdpath("config"), "nvim-pack-lock.json")
    mock_files[lock_path] = vim.fn.json_encode({
      plugins = {
        ["packard.nvim"] = { rev = "old-sha" },
        ["repo"] = { rev = "old-sha" },
      },
    })
    local Lockfile = require("packard.lockfile")
    Lockfile.invalidate()

    -- 4. Check for updates
    packard.check()

    -- 5. Verify packard is queued with the new SHA
    local State = require("packard.state")
    local state = State.read()
    if not state.queue["ruicsh/packard.nvim"] then
      print("Queue content: " .. vim.inspect(state.queue))
    end
    Helpers.expect(state.queue["ruicsh/packard.nvim"] ~= nil).to_be_truthy()
    if state.queue["ruicsh/packard.nvim"] and state.queue["ruicsh/packard.nvim"].commit ~= "sha-new" then
      print("Commit in queue: '" .. state.queue["ruicsh/packard.nvim"].commit .. "'")
    end
    Helpers.expect(state.queue["ruicsh/packard.nvim"].commit).to_be("sha-new")

    -- 6. Open UI and approve packard's pending update
    local UI = require("packard.ui")
    UI.open(packard.plugins, "pending")

    -- Mock vim.fn.confirm to return 1 (Yes) for approval, 2 (Later) for restart
    local confirm_calls = {}
    local original_confirm = vim.fn.confirm
    vim.fn.confirm = function(msg)
      table.insert(confirm_calls, msg)
      if msg:match("Restart Neovim") then
        return 2 -- Later
      end
      return 1 -- Yes
    end

    UI._do_render()
    local target_line = 0
    for line, owner_repo in pairs(UI.line_map) do
      if owner_repo == "ruicsh/packard.nvim" then
        target_line = line
        break
      end
    end

    Helpers.expect(target_line > 0).to_be_truthy()
    vim.api.nvim_win_set_cursor(UI.win, { target_line, 0 })

    -- Clear the tracker before approve
    update_called_with = nil

    UI.handle_approve()

    -- 7. Verify vim.pack.update was called with packard.nvim
    if update_called_with == nil then
      print("vim.pack.update was NOT called")
    end
    Helpers.expect(update_called_with ~= nil).to_be_truthy()
    local found_packard_in_update = false
    for _, name in ipairs(update_called_with or {}) do
      if name == "packard.nvim" then
        found_packard_in_update = true
        break
      end
    end
    Helpers.expect(found_packard_in_update).to_be(true)

    -- 8. Verify dequeued and logged
    state = State.read()
    Helpers.expect(state.queue["ruicsh/packard.nvim"]).to_be_nil()
    Helpers.expect(state.update_log["ruicsh/packard.nvim"] ~= nil).to_be_truthy()
    Helpers.expect(#state.update_log["ruicsh/packard.nvim"]).to_be(1)
    Helpers.expect(state.update_log["ruicsh/packard.nvim"][1].from).to_be("old-sha")
    Helpers.expect(state.update_log["ruicsh/packard.nvim"][1].to).to_be("sha-new")

    -- 9. Verify restart prompt was shown
    local saw_restart = false
    for _, msg in ipairs(confirm_calls) do
      if msg:match("Restart Neovim") then
        saw_restart = true
        break
      end
    end
    Helpers.expect(saw_restart).to_be(true)

    -- Restore
    vim.fn.confirm = original_confirm
    UI.close()
  end)
end)

-- Restore global mocks
os.rename = original_rename
io.open = original_io_open
vim.fn.filereadable = original_filereadable
vim.fn.mkdir = original_mkdir
vim.system = original_system
vim.fn.isdirectory = original_isdirectory
vim.pack = original_pack
