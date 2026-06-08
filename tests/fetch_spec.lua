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

-- Helper to create a minimal Lockfile mock
local Lockfile = require("packard.lockfile")

local function with_lockfile_mock(installed_sha, fn)
  local original = Lockfile.get_installed_commit
  --[[@diagnostic disable-next-line: duplicate-set-field]]
  Lockfile.get_installed_commit = function()
    return installed_sha
  end
  local ok, err = pcall(fn)
  Lockfile.get_installed_commit = original
  if not ok then
    error(err)
  end
end

Helpers.describe("Fetch.check_all", function()
  ----------------------------------------------------------------------------
  -- Basic tests
  ----------------------------------------------------------------------------
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
        spec = {},
      },
    })

    Helpers.expect(#results).to_be(1)
    Helpers.expect(results[1].success).to_be(false)
    Helpers.expect(results[1].error).to_be("not installed")
  end)

  ----------------------------------------------------------------------------
  -- Branch-tracked: success and SHA
  ----------------------------------------------------------------------------
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
      { name = "repo", url = url, owner_repo = "user/repo", minimum_release_age = 0, spec = {} },
    })

    Helpers.expect(#results).to_be(1)
    Helpers.expect(results[1].success).to_be(true)
    Helpers.expect(results[1].new_sha).to_be("new-sha-123")
  end)

  ----------------------------------------------------------------------------
  -- Branch-tracked: force-push / anomaly
  ----------------------------------------------------------------------------
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

    with_lockfile_mock("installed-sha", function()
      local results = Fetch.check_all({
        { name = "repo", url = url, owner_repo = "user/repo", minimum_release_age = 0, spec = {} },
      })

      Helpers.expect(#results).to_be(1)
      Helpers.expect(results[1].success).to_be(true)
      Helpers.expect(results[1].anomaly).to_be(true)
      Helpers.expect(results[1].force_push).to_be(true)
      Helpers.expect(results[1].error:match("force%-push")).to_be_truthy()
    end)
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

    with_lockfile_mock("installed-sha", function()
      local results = Fetch.check_all({
        { name = "repo", url = url, owner_repo = "user/repo", minimum_release_age = 0, spec = {} },
      })

      Helpers.expect(#results).to_be(1)
      Helpers.expect(results[1].success).to_be(true)
      Helpers.expect(results[1].anomaly).to_be(false)
      Helpers.expect(results[1].force_push).to_be_nil()
    end)
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

    with_lockfile_mock("installed-sha", function()
      local results = Fetch.check_all({
        { name = "repo", url = url, owner_repo = "user/repo", minimum_release_age = 0, spec = {} },
      })

      Helpers.expect(#results).to_be(1)
      Helpers.expect(results[1].success).to_be(true)
      Helpers.expect(results[1].anomaly).to_be(true)
      Helpers.expect(results[1].force_push).to_be_nil()
      Helpers.expect(results[1].error:match("force%-push check failed")).to_be_truthy()
    end)
  end)

  ----------------------------------------------------------------------------
  -- Branch-tracked: fetch errors
  ----------------------------------------------------------------------------
  Helpers.it("reports upstream unreachable for branch-tracked plugin (exit 128)", function()
    local url = "https://github.com/user/repo"
    local path = Utils.get_plugin_path("repo")
    mock_dirs[path] = 1

    mock_commands["git ls-remote --exit-code " .. url .. " HEAD"] = { code = 0 }
    mock_commands["git ls-remote --symref " .. url .. " HEAD"] = {
      code = 0,
      stdout = "ref: refs/heads/main\tHEAD\nsha1\tHEAD",
    }
    mock_commands["git fetch origin main"] = { code = 128, stderr = "fatal: could not read Username" }

    local results = Fetch.check_all({
      { name = "repo", url = url, owner_repo = "user/repo", minimum_release_age = 0, spec = {} },
    })

    Helpers.expect(#results).to_be(1)
    Helpers.expect(results[1].success).to_be(false)
    Helpers.expect(results[1].anomaly).to_be(true)
    Helpers.expect(results[1].error).to_be("upstream unreachable or repo gone")
  end)

  Helpers.it("reports non-128 fetch failure for branch-tracked plugin", function()
    local url = "https://github.com/user/repo"
    local path = Utils.get_plugin_path("repo")
    mock_dirs[path] = 1

    mock_commands["git ls-remote --exit-code " .. url .. " HEAD"] = { code = 0 }
    mock_commands["git ls-remote --symref " .. url .. " HEAD"] = {
      code = 0,
      stdout = "ref: refs/heads/main\tHEAD\nsha1\tHEAD",
    }
    mock_commands["git fetch origin main"] = { code = 1, stderr = "error: some unknown git error" }

    local results = Fetch.check_all({
      { name = "repo", url = url, owner_repo = "user/repo", minimum_release_age = 0, spec = {} },
    })

    Helpers.expect(#results).to_be(1)
    Helpers.expect(results[1].success).to_be(false)
    Helpers.expect(results[1].error:match("git fetch failed with code 1")).to_be_truthy()
  end)

  ----------------------------------------------------------------------------
  -- Branch-tracked: git rev-parse failed
  ----------------------------------------------------------------------------
  Helpers.it("reports git rev-parse failed", function()
    local url = "https://github.com/user/repo"
    local path = Utils.get_plugin_path("repo")
    mock_dirs[path] = 1

    mock_commands["git ls-remote --exit-code " .. url .. " HEAD"] = { code = 0 }
    mock_commands["git ls-remote --symref " .. url .. " HEAD"] = {
      code = 0,
      stdout = "ref: refs/heads/main\tHEAD\nsha1\tHEAD",
    }
    mock_commands["git fetch origin main"] = { code = 0 }
    -- Both origin/main and FETCH_HEAD rev-parse fail
    mock_commands["git rev-parse origin/main"] = { code = 128, stderr = "fatal: ambiguous argument" }
    mock_commands["git rev-parse FETCH_HEAD"] = { code = 128, stderr = "fatal: ambiguous argument" }

    local results = Fetch.check_all({
      { name = "repo", url = url, owner_repo = "user/repo", minimum_release_age = 0, spec = {} },
    })

    Helpers.expect(#results).to_be(1)
    Helpers.expect(results[1].success).to_be(false)
    Helpers.expect(results[1].error).to_be("git rev-parse failed")
  end)

  ----------------------------------------------------------------------------
  -- Version-tracked: success and tag
  ----------------------------------------------------------------------------
  Helpers.it("reports success and new tag for version-tracked plugin", function()
    local url = "https://github.com/user/repo"
    local path = Utils.get_plugin_path("repo")
    mock_dirs[path] = 1

    mock_commands["git ls-remote --exit-code " .. url .. " HEAD"] = { code = 0 }
    mock_commands["git ls-remote --symref --tags " .. url] = {
      code = 0,
      stdout = table.concat({
        "ref: refs/heads/main\tHEAD",
        "0000000000000000000000000000000000000000\tHEAD",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\trefs/tags/v1.0.0",
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\trefs/tags/v2.0.0",
      }, "\n"),
    }
    mock_commands["git fetch --tags origin"] = { code = 0 }
    mock_commands["git merge-base --is-ancestor installed-sha FETCH_HEAD"] = { code = 0 }

    with_lockfile_mock("installed-sha", function()
      local results = Fetch.check_all({
        {
          name = "repo",
          url = url,
          owner_repo = "user/repo",
          version = ">=1.0.0",
          minimum_release_age = 0,
          spec = {},
        },
      })

      Helpers.expect(#results).to_be(1)
      Helpers.expect(results[1].success).to_be(true)
      Helpers.expect(results[1].new_tag).to_be("v2.0.0")
      Helpers.expect(results[1].tag_sha).to_be("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
      Helpers.expect(results[1].anomaly).to_be(false)
    end)
  end)

  ----------------------------------------------------------------------------
  -- Version-tracked: force-push / anomaly
  ----------------------------------------------------------------------------
  Helpers.it("detects force-push for version-tracked plugin", function()
    local url = "https://github.com/user/repo"
    local path = Utils.get_plugin_path("repo")
    mock_dirs[path] = 1

    mock_commands["git ls-remote --exit-code " .. url .. " HEAD"] = { code = 0 }
    mock_commands["git ls-remote --symref --tags " .. url] = {
      code = 0,
      stdout = table.concat({
        "ref: refs/heads/main\tHEAD",
        "0000000000000000000000000000000000000000\tHEAD",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\trefs/tags/v1.0.0",
      }, "\n"),
    }
    mock_commands["git fetch --tags origin"] = { code = 0 }
    mock_commands["git merge-base --is-ancestor installed-sha FETCH_HEAD"] = { code = 1 }

    with_lockfile_mock("installed-sha", function()
      local results = Fetch.check_all({
        {
          name = "repo",
          url = url,
          owner_repo = "user/repo",
          version = ">=1.0.0",
          minimum_release_age = 0,
          spec = {},
        },
      })

      Helpers.expect(#results).to_be(1)
      Helpers.expect(results[1].success).to_be(true)
      Helpers.expect(results[1].new_tag).to_be("v1.0.0")
      Helpers.expect(results[1].anomaly).to_be(true)
      Helpers.expect(results[1].force_push).to_be(true)
      Helpers.expect(results[1].error:match("force%-push")).to_be_truthy()
    end)
  end)

  Helpers.it("does not flag anomaly for version-tracked plugin when installed commit is in history", function()
    local url = "https://github.com/user/repo"
    local path = Utils.get_plugin_path("repo")
    mock_dirs[path] = 1

    mock_commands["git ls-remote --exit-code " .. url .. " HEAD"] = { code = 0 }
    mock_commands["git ls-remote --symref --tags " .. url] = {
      code = 0,
      stdout = table.concat({
        "ref: refs/heads/main\tHEAD",
        "0000000000000000000000000000000000000000\tHEAD",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\trefs/tags/v1.0.0",
      }, "\n"),
    }
    mock_commands["git fetch --tags origin"] = { code = 0 }
    mock_commands["git merge-base --is-ancestor installed-sha FETCH_HEAD"] = { code = 0 }

    with_lockfile_mock("installed-sha", function()
      local results = Fetch.check_all({
        {
          name = "repo",
          url = url,
          owner_repo = "user/repo",
          version = ">=1.0.0",
          minimum_release_age = 0,
          spec = {},
        },
      })

      Helpers.expect(#results).to_be(1)
      Helpers.expect(results[1].success).to_be(true)
      Helpers.expect(results[1].anomaly).to_be(false)
      Helpers.expect(results[1].force_push).to_be_nil()
    end)
  end)

  Helpers.it("reports anomaly when merge-base check fails for version-tracked plugin", function()
    local url = "https://github.com/user/repo"
    local path = Utils.get_plugin_path("repo")
    mock_dirs[path] = 1

    mock_commands["git ls-remote --exit-code " .. url .. " HEAD"] = { code = 0 }
    mock_commands["git ls-remote --symref --tags " .. url] = {
      code = 0,
      stdout = table.concat({
        "ref: refs/heads/main\tHEAD",
        "0000000000000000000000000000000000000000\tHEAD",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\trefs/tags/v1.0.0",
      }, "\n"),
    }
    mock_commands["git fetch --tags origin"] = { code = 0 }
    mock_commands["git merge-base --is-ancestor installed-sha FETCH_HEAD"] =
      { code = 128, stderr = "fatal: bad object" }

    with_lockfile_mock("installed-sha", function()
      local results = Fetch.check_all({
        {
          name = "repo",
          url = url,
          owner_repo = "user/repo",
          version = ">=1.0.0",
          minimum_release_age = 0,
          spec = {},
        },
      })

      Helpers.expect(#results).to_be(1)
      Helpers.expect(results[1].success).to_be(true)
      Helpers.expect(results[1].anomaly).to_be(true)
      Helpers.expect(results[1].force_push).to_be_nil()
      Helpers.expect(results[1].error:match("force%-push check failed")).to_be_truthy()
    end)
  end)

  ----------------------------------------------------------------------------
  -- Version-tracked: fetch errors
  ----------------------------------------------------------------------------
  Helpers.it("reports upstream unreachable for version-tracked plugin (exit 128)", function()
    local url = "https://github.com/user/repo"
    local path = Utils.get_plugin_path("repo")
    mock_dirs[path] = 1

    mock_commands["git ls-remote --exit-code " .. url .. " HEAD"] = { code = 0 }
    mock_commands["git fetch --tags origin"] = { code = 128, stderr = "fatal: could not read Username" }

    local results = Fetch.check_all({
      {
        name = "repo",
        url = url,
        owner_repo = "user/repo",
        version = ">=1.0.0",
        minimum_release_age = 0,
        spec = {},
      },
    })

    Helpers.expect(#results).to_be(1)
    Helpers.expect(results[1].success).to_be(false)
    Helpers.expect(results[1].anomaly).to_be(true)
    Helpers.expect(results[1].error).to_be("upstream unreachable or repo gone")
  end)

  Helpers.it("reports non-128 fetch failure for version-tracked plugin", function()
    local url = "https://github.com/user/repo"
    local path = Utils.get_plugin_path("repo")
    mock_dirs[path] = 1

    mock_commands["git ls-remote --exit-code " .. url .. " HEAD"] = { code = 0 }
    mock_commands["git fetch --tags origin"] = { code = 1, stderr = "error: some unknown git error" }

    local results = Fetch.check_all({
      {
        name = "repo",
        url = url,
        owner_repo = "user/repo",
        version = ">=1.0.0",
        minimum_release_age = 0,
        spec = {},
      },
    })

    Helpers.expect(#results).to_be(1)
    Helpers.expect(results[1].success).to_be(false)
    Helpers.expect(results[1].error:match("git fetch %-%-tags failed with code 1")).to_be_truthy()
  end)

  ----------------------------------------------------------------------------
  -- Version-tracked: no matching version found
  ----------------------------------------------------------------------------
  Helpers.it("reports no matching version for version-tracked plugin", function()
    local url = "https://github.com/user/repo"
    local path = Utils.get_plugin_path("repo")
    mock_dirs[path] = 1

    mock_commands["git ls-remote --exit-code " .. url .. " HEAD"] = { code = 0 }
    mock_commands["git ls-remote --symref --tags " .. url] = {
      code = 0,
      stdout = table.concat({
        "ref: refs/heads/main\tHEAD",
        "0000000000000000000000000000000000000000\tHEAD",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\trefs/tags/v1.0.0",
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\trefs/tags/v1.1.0",
      }, "\n"),
    }
    mock_commands["git fetch --tags origin"] = { code = 0 }

    local results = Fetch.check_all({
      {
        name = "repo",
        url = url,
        owner_repo = "user/repo",
        version = ">=2.0.0",
        minimum_release_age = 0,
        spec = {},
      },
    })

    Helpers.expect(#results).to_be(1)
    Helpers.expect(results[1].success).to_be(false)
    Helpers.expect(results[1].error).to_be("no matching version found")
  end)

  ----------------------------------------------------------------------------
  -- Version-tracked: git ls-remote --tags fails
  ----------------------------------------------------------------------------
  Helpers.it("reports git ls-remote --tags failed", function()
    local url = "https://github.com/user/repo"
    local path = Utils.get_plugin_path("repo")
    mock_dirs[path] = 1

    mock_commands["git ls-remote --exit-code " .. url .. " HEAD"] = { code = 0 }
    mock_commands["git ls-remote --symref --tags " .. url] = { code = 128, stderr = "fatal: could not read Username" }
    mock_commands["git fetch --tags origin"] = { code = 0 }

    local results = Fetch.check_all({
      {
        name = "repo",
        url = url,
        owner_repo = "user/repo",
        version = ">=1.0.0",
        minimum_release_age = 0,
        spec = {},
      },
    })

    Helpers.expect(#results).to_be(1)
    Helpers.expect(results[1].success).to_be(false)
    Helpers.expect(results[1].error).to_be("git ls-remote --tags failed")
  end)

  ----------------------------------------------------------------------------
  -- Version-tracked: internal error (no tag job)
  ----------------------------------------------------------------------------
  Helpers.it("reports internal error when tag job is missing for version-tracked plugin", function()
    local url = "https://github.com/user/repo"
    local path = Utils.get_plugin_path("repo")
    mock_dirs[path] = 1

    mock_commands["git ls-remote --exit-code " .. url .. " HEAD"] = { code = 0 }
    mock_commands["git fetch --tags origin"] = { code = 0 }

    -- Replace vim.system to return nil specifically for ls-remote --tags calls,
    -- preventing tag_jobs[i] from being set in the pre-jobs phase.
    -- This exercises the defensive check `if plugin.version and tag_jobs[i] then`.
    local saved_system = vim.system
    rawset(vim, "system", function(cmd, opts)
      local cmd_str = table.concat(cmd, " ")
      -- Return nil for any ls-remote --tags call so tag_jobs[i] stays nil
      if cmd_str:match("ls%-remote.*%-%-tags") then
        return nil
      end
      -- Use the original mock for everything else
      local result = mock_commands[cmd_str] or { code = 0, stdout = "", stderr = "" }
      return {
        wait = function()
          return result
        end,
        kill = function() end,
      }
    end)

    local ok, results_or_err = pcall(Fetch.check_all, {
      {
        name = "repo",
        url = url,
        owner_repo = "user/repo",
        version = ">=1.0.0",
        minimum_release_age = 0,
        spec = {},
      },
    })

    -- Restore original mock
    rawset(vim, "system", saved_system)

    Helpers.expect(ok).to_be(true)
    local results = results_or_err
    Helpers.expect(#results).to_be(1)
    Helpers.expect(results[1].success).to_be(false)
    Helpers.expect(results[1].anomaly).to_be(true)
    Helpers.expect(results[1].error:match("no tag job")).to_be_truthy()
  end)

  ----------------------------------------------------------------------------
  -- Mixed batch
  ----------------------------------------------------------------------------
  Helpers.it("handles mixed batch of plugins", function()
    -- Setup: 4 plugins
    -- 1. local-plugin (local, always up-to-date)
    -- 2. remote-plugin (branch-tracked, normal)
    -- 3. ver-plugin (version-tracked, finds match)
    -- 4. missing-plugin (not installed on disk)
    local local_name = "local-plugin"
    local remote_url = "https://github.com/user/remote"
    local remote_name = "remote-plugin"
    local ver_url = "https://github.com/user/ver"
    local ver_name = "ver-plugin"
    local missing_url = "https://github.com/user/missing"
    local missing_name = "missing-plugin"

    local remote_path = Utils.get_plugin_path(remote_name)
    local ver_path = Utils.get_plugin_path(ver_name)
    mock_dirs[remote_path] = 1
    mock_dirs[ver_path] = 1
    -- missing-plugin: NOT in mock_dirs, so isdirectory returns 0

    -- Network probe uses first remote plugin's URL: remote-plugin
    mock_commands["git ls-remote --exit-code " .. remote_url .. " HEAD"] = { code = 0 }

    -- Branch resolution for remote-plugin (no version, no branch)
    mock_commands["git ls-remote --symref " .. remote_url .. " HEAD"] = {
      code = 0,
      stdout = "ref: refs/heads/main\tHEAD\nsha1\tHEAD",
    }

    -- Tag resolution for ver-plugin (version set, no branch)
    mock_commands["git ls-remote --symref --tags " .. ver_url] = {
      code = 0,
      stdout = table.concat({
        "ref: refs/heads/main\tHEAD",
        "0000000000000000000000000000000000000000\tHEAD",
        "cccccccccccccccccccccccccccccccccccccccc\trefs/tags/v3.0.0",
      }, "\n"),
    }

    -- Branch resolution for missing-plugin (no version, no branch)
    mock_commands["git ls-remote --symref " .. missing_url .. " HEAD"] = {
      code = 0,
      stdout = "ref: refs/heads/main\tHEAD\nsha1\tHEAD",
    }

    -- Fetch commands
    mock_commands["git fetch origin main"] = { code = 0 }
    mock_commands["git fetch --tags origin"] = { code = 0 }

    -- rev-parse for remote-plugin
    mock_commands["git rev-parse origin/main"] = { code = 0, stdout = "remote-sha-456\n" }

    -- merge-base for remote-plugin (normal, no force-push)
    mock_commands["git merge-base --is-ancestor installed-sha FETCH_HEAD"] = { code = 0 }

    with_lockfile_mock("installed-sha", function()
      local results = Fetch.check_all({
        {
          name = local_name,
          dir = "/fake/local/path",
          is_local = true,
          owner_repo = "local/local-plugin",
          minimum_release_age = 0,
          spec = {},
        },
        {
          name = remote_name,
          url = remote_url,
          owner_repo = "user/remote",
          minimum_release_age = 0,
          spec = {},
        },
        {
          name = ver_name,
          url = ver_url,
          owner_repo = "user/ver",
          version = ">=1.0.0",
          minimum_release_age = 0,
          spec = {},
        },
        {
          name = missing_name,
          url = missing_url,
          owner_repo = "user/missing",
          minimum_release_age = 0,
          spec = {},
        },
      })

      Helpers.expect(#results).to_be(4)

      -- Plugin 1: local
      Helpers.expect(results[1].success).to_be(true)
      Helpers.expect(results[1].owner_repo).to_be("local/local-plugin")
      Helpers.expect(results[1].anomaly).to_be(false)

      -- Plugin 2: remote branch-tracked
      Helpers.expect(results[2].success).to_be(true)
      Helpers.expect(results[2].owner_repo).to_be("user/remote")
      Helpers.expect(results[2].new_sha).to_be("remote-sha-456")
      Helpers.expect(results[2].anomaly).to_be(false)

      -- Plugin 3: version-tracked
      Helpers.expect(results[3].success).to_be(true)
      Helpers.expect(results[3].owner_repo).to_be("user/ver")
      Helpers.expect(results[3].new_tag).to_be("v3.0.0")
      Helpers.expect(results[3].tag_sha).to_be("cccccccccccccccccccccccccccccccccccccccc")
      Helpers.expect(results[3].anomaly).to_be(false)

      -- Plugin 4: missing
      Helpers.expect(results[4].success).to_be(false)
      Helpers.expect(results[4].owner_repo).to_be("user/missing")
      Helpers.expect(results[4].error).to_be("not installed")
      Helpers.expect(results[4].anomaly).to_be(false)
    end)
  end)
end)

-- Restore
vim.fn.isdirectory = original_isdirectory
vim.system = original_system
