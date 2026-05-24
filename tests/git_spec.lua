local Helpers = require("tests.helpers")

-- Mock vim.system
local original_system = vim.system
local mock_results = {}
--[[@diagnostic disable-next-line: duplicate-set-field]]
vim.system = function(cmd, opts)
  local cmd_str = table.concat(cmd, " ")
  local res = mock_results[cmd_str] or { code = 0, stdout = "", stderr = "" }
  return {
    wait = function()
      return res
    end,
  }
end

local Git = require("packard.git")

Helpers.describe("Git helper", function()
  Helpers.it("resolves default branch", function()
    local url = "https://github.com/user/repo"
    mock_results["git ls-remote --symref " .. url .. " HEAD"] = {
      code = 0,
      stdout = "ref: refs/heads/main\tHEAD\nd043ad5d985a73e512727189f71c990b503612d6\tHEAD\n",
    }

    local branch = Git.get_default_branch(url)
    Helpers.expect(branch).to_be("main")
  end)

  Helpers.it("returns nil when default branch resolve fails", function()
    local url = "https://github.com/user/badrepo"
    mock_results["git ls-remote --symref " .. url .. " HEAD"] = {
      code = 128,
      stdout = "",
      stderr = "fatal: repository not found",
    }

    local branch = Git.get_default_branch(url)
    Helpers.expect(branch).to_be_nil()
  end)

  Helpers.it("checks network availability", function()
    local url = "https://github.com/user/repo"
    mock_results["git ls-remote --exit-code " .. url .. " HEAD"] = { code = 0 }

    local ok = Git.check_network(url)
    Helpers.expect(ok).to_be(true)

    mock_results["git ls-remote --exit-code " .. url .. " HEAD"] = { code = 128 }
    ok = Git.check_network(url)
    Helpers.expect(ok).to_be(false)
  end)
end)

-- Restore
vim.system = original_system
