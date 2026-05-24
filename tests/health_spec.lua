local Helpers = require("tests.helpers")

-- Mock vim.health
local health_output = {}
vim.health = {
  start = function(msg)
    table.insert(health_output, "START: " .. msg)
  end,
  ok = function(msg)
    table.insert(health_output, "OK: " .. msg)
  end,
  info = function(msg)
    table.insert(health_output, "INFO: " .. msg)
  end,
  warn = function(msg)
    table.insert(health_output, "WARN: " .. msg)
  end,
  error = function(msg)
    table.insert(health_output, "ERROR: " .. msg)
  end,
}

-- Mock dependencies
local packard = require("packard")
packard.config = { defaults = { minimum_release_age = 30 } }
packard.plugins = {
  { name = "repo", owner_repo = "user/repo", url = "https://github.com/user/repo" },
}

local Lockfile = require("packard.lockfile")
local original_lock_read = Lockfile.read
--[[@diagnostic disable-next-line: duplicate-set-field]]
Lockfile.read = function()
  return { repo = { commit = "abc1234" } }
end

local State = require("packard.state")
local original_state_read = State.read
--[[@diagnostic disable-next-line: duplicate-set-field]]
State.read = function()
  return { queue = {}, update_log = {}, blacklist = {} }
end

local Cooldown = require("packard.cooldown")
local original_cooldown_get = Cooldown.get_status
--[[@diagnostic disable-next-line: duplicate-set-field]]
Cooldown.get_status = function()
  return { eligible = {}, cooldown = {} }
end

local Git = require("packard.git")
local original_git_check = Git.check_network
--[[@diagnostic disable-next-line: duplicate-set-field]]
Git.check_network = function()
  return true
end

local Utils = require("packard.utils")
local original_isdirectory = vim.fn.isdirectory
--[[@diagnostic disable-next-line: duplicate-set-field]]
vim.fn.isdirectory = function()
  return 1
end

local Health = require("packard.health")

Helpers.describe("Health check", function()
  Helpers.it("reports OK for healthy system", function()
    health_output = {}
    Health.check()

    local found_ok = false
    for _, line in ipairs(health_output) do
      if line:match("OK: 1 plugins declared") or line:match("OK: nvim%-pack%-lock.json: 1 plugins tracked") then
        found_ok = true
      end
    end
    Helpers.expect(found_ok).to_be_truthy()
  end)

  Helpers.it("reports error if setup not called", function()
    health_output = {}
    local original_config = packard.config
    packard.config = nil

    Health.check()

    local found_err = false
    for _, line in ipairs(health_output) do
      if line:match("ERROR: packard.setup%(%) has not been called") then
        found_err = true
        break
      end
    end
    Helpers.expect(found_err).to_be_truthy()

    packard.config = original_config
  end)
end)

-- Restore
Lockfile.read = original_lock_read
State.read = original_state_read
Cooldown.get_status = original_cooldown_get
Git.check_network = original_git_check
vim.fn.isdirectory = original_isdirectory
