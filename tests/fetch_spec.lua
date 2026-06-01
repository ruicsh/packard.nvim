local Helpers = require("tests.helpers")
-- Mock dependencies before requiring Fetch
local original_isdirectory = vim.fn.isdirectory
local original_system = vim.system

local mock_dirs = {}
rawset(vim.fn, "isdirectory", function(path)
  return mock_dirs[path] or 0
end)

local mock_commands = {}
rawset(vim, "system", function(cmd)
  local cmd_str = table.concat(cmd, " ")
  local result = mock_commands[cmd_str] or { code = 0, stdout = "", stderr = "" }

  return {
    wait = function()
      return result
    end,
    kill = function() end,
  }
end)

local Fetch = require("packard.fetch")
local Utils = require("packard.utils")

Helpers.describe("Fetch.check_all", function()
  Helpers.it("returns empty for empty list", function()
    local results = Fetch.check_all({})
    Helpers.expect(#results).to_be(0)
  end)

  Helpers.it("errors when network is unreachable", function()
    mock_commands["git ls-remote --exit-code https://github.com/user/repo HEAD"] = { code = 1 }
    local ok, err = pcall(Fetch.check_all, {
      {
        name = "repo",
        url = "https://github.com/user/repo",
        owner_repo = "user/repo",
        minimum_release_age = 0,
        lazy = true,
        spec = {},
      },
    })
    Helpers.expect(ok).to_be(false)
    Helpers.expect(tostring(err):match("network unreachable") ~= nil).to_be_truthy()
  end)

  Helpers.it("handles missing plugin on disk", function()
    -- Mock network success
    mock_commands["git ls-remote --exit-code https://github.com/user/repo HEAD"] = { code = 0 }

    local results = Fetch.check_all({
      {
        name = "repo",
        url = "https://github.com/user/repo",
        owner_repo = "user/repo",
        minimum_release_age = 0,
        lazy = true,
        spec = {},
      },
    })

    Helpers.expect(#results).to_be(1)
    Helpers.expect(results[1].success).to_be(false)
    Helpers.expect(results[1].error).to_be("not installed")
  end)

  Helpers.it("reports success and new SHA", function()
    local url = "https://github.com/user/repo"
    local path = Utils.get_plugin_path("repo")
    mock_dirs[path] = 1

    mock_commands["git ls-remote --exit-code " .. url .. " HEAD"] = { code = 0 }
    mock_commands["git ls-remote --symref " .. url .. " HEAD"] = {
      code = 0,
      stdout = "ref: refs/heads/main\tHEAD\nsha1\tHEAD",
    }
    mock_commands["git fetch origin main"] = { code = 0 }
    mock_commands["git rev-parse origin/main"] = { code = 0, stdout = "new-sha-123\n" }

    local results = Fetch.check_all({
      { name = "repo", url = url, owner_repo = "user/repo", minimum_release_age = 0, lazy = true, spec = {} },
    })

    Helpers.expect(#results).to_be(1)
    Helpers.expect(results[1].success).to_be(true)
    Helpers.expect(results[1].new_sha).to_be("new-sha-123")
  end)

  Helpers.it("detects force-push when installed commit is not in history", function()
    local url = "https://github.com/user/repo"
    local path = Utils.get_plugin_path("repo")
    mock_dirs[path] = 1

    mock_commands["git ls-remote --exit-code " .. url .. " HEAD"] = { code = 0 }
    mock_commands["git ls-remote --symref " .. url .. " HEAD"] = {
      code = 0,
      stdout = "ref: refs/heads/main\tHEAD\nsha1\tHEAD",
    }
    mock_commands["git fetch origin main"] = { code = 0 }
    mock_commands["git rev-parse origin/main"] = { code = 0, stdout = "new-sha-123\n" }
    -- merge-base returns non-zero: installed commit is NOT an ancestor (= force-push)
    mock_commands["git merge-base --is-ancestor installed-sha FETCH_HEAD"] = { code = 1 }

    -- Mock Lockfile to return a known installed SHA for comparison
    local Lockfile = require("packard.lockfile")
    local original_get_installed = Lockfile.get_installed_commit
    --[[@diagnostic disable-next-line: duplicate-set-field]]
    Lockfile.get_installed_commit = function()
      return "installed-sha"
    end

    local results = Fetch.check_all({
      { name = "repo", url = url, owner_repo = "user/repo", minimum_release_age = 0, lazy = true, spec = {} },
    })

    Helpers.expect(#results).to_be(1)
    Helpers.expect(results[1].success).to_be(true)
    Helpers.expect(results[1].anomaly).to_be(true)
    Helpers.expect(results[1].force_push).to_be(true)
    Helpers.expect(results[1].error:match("force%-push")).to_be_truthy()

    Lockfile.get_installed_commit = original_get_installed
  end)

  Helpers.it("does not flag anomaly when installed commit is in history", function()
    local url = "https://github.com/user/repo"
    local path = Utils.get_plugin_path("repo")
    mock_dirs[path] = 1

    mock_commands["git ls-remote --exit-code " .. url .. " HEAD"] = { code = 0 }
    mock_commands["git ls-remote --symref " .. url .. " HEAD"] = {
      code = 0,
      stdout = "ref: refs/heads/main\tHEAD\nsha1\tHEAD",
    }
    mock_commands["git fetch origin main"] = { code = 0 }
    mock_commands["git rev-parse origin/main"] = { code = 0, stdout = "new-sha-123\n" }
    -- merge-base returns 0: installed commit IS an ancestor (normal fast-forward)
    mock_commands["git merge-base --is-ancestor installed-sha FETCH_HEAD"] = { code = 0 }

    local Lockfile = require("packard.lockfile")
    local original_get_installed = Lockfile.get_installed_commit
    --[[@diagnostic disable-next-line: duplicate-set-field]]
    Lockfile.get_installed_commit = function()
      return "installed-sha"
    end

    local results = Fetch.check_all({
      { name = "repo", url = url, owner_repo = "user/repo", minimum_release_age = 0, lazy = true, spec = {} },
    })

    Helpers.expect(#results).to_be(1)
    Helpers.expect(results[1].success).to_be(true)
    Helpers.expect(results[1].anomaly).to_be(false)
    Helpers.expect(results[1].force_push).to_be_nil()

    Lockfile.get_installed_commit = original_get_installed
  end)

  Helpers.it("reports anomaly (not force-push) when merge-base check fails with git error", function()
    local url = "https://github.com/user/repo"
    local path = Utils.get_plugin_path("repo")
    mock_dirs[path] = 1

    mock_commands["git ls-remote --exit-code " .. url .. " HEAD"] = { code = 0 }
    mock_commands["git ls-remote --symref " .. url .. " HEAD"] = {
      code = 0,
      stdout = "ref: refs/heads/main\tHEAD\nsha1\tHEAD",
    }
    mock_commands["git fetch origin main"] = { code = 0 }
    mock_commands["git rev-parse origin/main"] = { code = 0, stdout = "new-sha-123\n" }
    -- merge-base returns code 128: git error (bad object, stale repo, etc.), NOT a force-push
    mock_commands["git merge-base --is-ancestor installed-sha FETCH_HEAD"] =
      { code = 128, stderr = "fatal: bad object" }

    local Lockfile = require("packard.lockfile")
    local original_get_installed = Lockfile.get_installed_commit
    --[[@diagnostic disable-next-line: duplicate-set-field]]
    Lockfile.get_installed_commit = function()
      return "installed-sha"
    end

    local results = Fetch.check_all({
      { name = "repo", url = url, owner_repo = "user/repo", minimum_release_age = 0, lazy = true, spec = {} },
    })

    Helpers.expect(#results).to_be(1)
    Helpers.expect(results[1].success).to_be(true)
    Helpers.expect(results[1].anomaly).to_be(true)
    Helpers.expect(results[1].force_push).to_be_nil()
    Helpers.expect(results[1].error:match("force%-push check failed")).to_be_truthy()

    Lockfile.get_installed_commit = original_get_installed
  end)
end)

-- Restore
vim.fn.isdirectory = original_isdirectory
vim.system = original_system
