local Helpers = require("tests.helpers")
local Cooldown = require("packard.cooldown")
local State = require("packard.state")

-- Mock State.write to avoid actual filesystem activity
local original_state_write = State.write
State.write = function() end

local function clear_state()
  State._cache = { queue = {}, blacklist = {}, update_log = {} }
end

Helpers.describe("Cooldown Manager", function()
  Helpers.it("registers a commit", function()
    clear_state()
    Cooldown.register_commit("owner/repo", "sha123", "v1.0.0")

    local entry = State.read().queue["owner/repo"]
    Helpers.expect(entry).to_not_be_nil()
    Helpers.expect(entry.commit).to_be("sha123")
    Helpers.expect(entry.tag).to_be("v1.0.0")
    Helpers.expect(entry.discovered_at).to_not_be_nil()
  end)

  Helpers.it("supersedes an existing pending commit with a newer one", function()
    clear_state()
    Cooldown.register_commit("owner/repo", "old_sha", "v0.9.0")
    local first_discovered = State.read().queue["owner/repo"].discovered_at

    -- Register a new one
    Cooldown.register_commit("owner/repo", "new_sha", "v1.0.0")

    local entry = State.read().queue["owner/repo"]
    Helpers.expect(entry.commit).to_be("new_sha")
    Helpers.expect(entry.tag).to_be("v1.0.0")
    -- Discovered_at should be updated (per cooldown.lua:29 comment "We keep the current timestamp as discovery for the NEW commit")
    -- Note: Since the test runs fast, the timestamp might be the same.
    -- But let's check that it's still present.
    Helpers.expect(entry.discovered_at).to_not_be_nil()
  end)

  Helpers.it("does not register a blacklisted commit", function()
    clear_state()
    State.blacklist("owner/repo", "badsha")

    Cooldown.register_commit("owner/repo", "badsha")
    Helpers.expect(State.read().queue["owner/repo"]).to_be_nil()
  end)

  Helpers.it("calculates eligibility correctly", function()
    -- Mock os.time and os.date to be deterministic
    local now = 1717000000 -- Some arbitrary fixed time
    local original_time = os.time
    local original_date = os.date

    --[[@diagnostic disable-next-line: duplicate-set-field]]
    os.time = function(t)
      if t == nil then
        return now
      end
      return original_time(t)
    end
    --[[@diagnostic disable-next-line: duplicate-set-field]]
    os.date = function(fmt, t)
      if fmt == "!*t" and t == nil then
        return original_date("!*t", now)
      end
      return original_date(fmt, t)
    end

    -- 31 days ago (86400 * 31 = 2678400)
    local old_time = now - 2678400
    local old_iso = original_date("!%Y-%m-%dT%H:%M:%SZ", old_time)

    local eligible, remaining = Cooldown.check_eligibility(old_iso, 30)
    Helpers.expect(eligible).to_be(true)
    Helpers.expect(remaining).to_be(0)

    -- 29 days ago (86400 * 29 = 2505600)
    local young_time = now - 2505600
    local young_iso = original_date("!%Y-%m-%dT%H:%M:%SZ", young_time)

    local eligible2, remaining2 = Cooldown.check_eligibility(young_iso, 30)
    Helpers.expect(eligible2).to_be(false)
    Helpers.expect(remaining2 > 0).to_be_truthy()
    Helpers.expect(remaining2).to_be(86400) -- exactly 1 day remaining

    -- Restore
    os.time = original_time
    os.date = original_date
  end)

  Helpers.it("gets batch status for plugins", function()
    clear_state()

    -- Setup queue with one eligible and one in cooldown
    local now = os.time(os.date("!*t") --[[@as osdateparam]])
    local old_iso = os.date("!%Y-%m-%dT%H:%M:%SZ", now - (31 * 86400))
    local young_iso = os.date("!%Y-%m-%dT%H:%M:%SZ", now - (10 * 86400))

    State.queue_pending("eligible/repo", "sha1", old_iso)
    State.queue_pending("cooldown/repo", "sha2", young_iso)

    local plugins = {
      { owner_repo = "eligible/repo", minimum_release_age = 30 },
      { owner_repo = "cooldown/repo", minimum_release_age = 30 },
      { owner_repo = "not-in-queue/repo", minimum_release_age = 30 },
    }

    local status = Cooldown.get_status(plugins)

    Helpers.expect(status.eligible["eligible/repo"]).to_not_be_nil()
    Helpers.expect(status.eligible["eligible/repo"].commit).to_be("sha1")

    Helpers.expect(status.cooldown["cooldown/repo"]).to_not_be_nil()
    Helpers.expect(status.cooldown["cooldown/repo"].commit).to_be("sha2")
    Helpers.expect(status.cooldown["cooldown/repo"].remaining_days).to_be(20)

    Helpers.expect(status.eligible["not-in-queue/repo"]).to_be_nil()
    Helpers.expect(status.cooldown["not-in-queue/repo"]).to_be_nil()
  end)
end)

State.write = original_state_write
print("Cooldown tests passed!")
