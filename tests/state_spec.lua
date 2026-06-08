local Helpers = require("tests.helpers")
local State = require("packard.state")

-- Helper to clear state for testing
local function clear_state()
  State._cache = nil
  State._ai_cache = nil
  local state_path = vim.fs.joinpath(vim.fn.stdpath("state"), "packard-state.json")
  if vim.fn.filereadable(state_path) == 1 then
    os.remove(state_path)
  end
end

Helpers.describe("State Manager", function()
  Helpers.it("performs basic operations (queue, dequeue, blacklist, log)", function()
    clear_state()

    -- Queue
    State.queue_pending("a/b", "sha123")
    local s = State.read()
    Helpers.expect(s.queue["a/b"].commit).to_be("sha123")
    Helpers.expect(s.queue["a/b"].discovered_at:match("%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ")).to_be_truthy()

    -- Dequeue
    State.dequeue("a/b")
    Helpers.expect(State.read().queue["a/b"]).to_be_nil()

    -- Blacklist
    Helpers.expect(State.is_blacklisted("c/d", "badsha")).to_be(false)
    State.blacklist("c/d", "badsha")
    Helpers.expect(State.is_blacklisted("c/d", "badsha")).to_be(true)

    -- Blacklist duplicate
    State.blacklist("c/d", "badsha")
    Helpers.expect(#State.read().blacklist["c/d"]).to_be(1)

    -- Log update and cap
    for i = 1, 12 do
      State.log_update("e/f", "from" .. i, "to" .. i)
    end
    local log = State.read().update_log["e/f"]
    Helpers.expect(#log).to_be(10)
    Helpers.expect(log[1].to).to_be("to12") -- Newest first
    Helpers.expect(log[10].to).to_be("to3") -- Oldest kept
  end)

  Helpers.it("persists state to disk", function()
    clear_state()
    State.queue_pending("pers/ist", "sha_pers")

    -- Simulate restart by clearing cache
    State._cache = nil

    local s = State.read()
    Helpers.expect(s.queue["pers/ist"].commit).to_be("sha_pers")
  end)

  Helpers.it("recovers from corrupt state file", function()
    clear_state()
    local state_path = vim.fs.joinpath(vim.fn.stdpath("state"), "packard-state.json")
    State._init()
    local f = io.open(state_path, "w")
    if f then
      f:write("invalid json {")
      f:close()
    end

    local s = State.read()
    Helpers.expect(type(s.queue)).to_be("table")
    Helpers.expect(s.queue).to_not_be_nil()
  end)

  Helpers.it("checks if state file exists without populating cache", function()
    clear_state()
    Helpers.expect(State.exists()).to_be(false)

    State.queue_pending("x/y", "some-sha")
    Helpers.expect(State.exists()).to_be(true)

    clear_state()
    Helpers.expect(State.exists()).to_be(false)
    Helpers.expect(State._cache).to_be_nil()
  end)

  Helpers.it("purges stale metadata", function()
    clear_state()
    State.queue_pending("orphan/repo", "sha1")
    State.blacklist("orphan/repo", "badsha")

    Helpers.expect(State.read().queue["orphan/repo"]).to_not_be_nil()
    Helpers.expect(State.read().blacklist["orphan/repo"]).to_not_be_nil()

    State.purge_stale_metadata("orphan/repo")

    Helpers.expect(State.read().queue["orphan/repo"]).to_be_nil()
    Helpers.expect(State.read().blacklist["orphan/repo"]).to_be_nil()
  end)

  Helpers.it("invalidates cache", function()
    clear_state()
    State.queue_pending("a/b", "sha1")
    State.read() -- populate cache
    Helpers.expect(State._cache).to_not_be_nil()

    State.invalidate()
    Helpers.expect(State._cache).to_be_nil()
    Helpers.expect(State._ai_cache).to_be_nil()
  end)
end)

print("State Manager tests passed!")
