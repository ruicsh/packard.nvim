local State = require("packard.state")

-- Helper to clear state for testing
local function clear_state()
  State._cache = nil
  local state_path = vim.fn.stdpath("state") .. "/packard-state.json"
  if vim.fn.filereadable(state_path) == 1 then
    os.remove(state_path)
  end
end

local function test_basic_ops()
  print("Testing basic state operations...")
  clear_state()

  -- Queue
  State.queue_pending("a/b", "sha123")
  local s = State.read()
  assert(s.queue["a/b"].commit == "sha123")
  assert(s.queue["a/b"].discovered_at:match("%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ"))

  -- Dequeue
  State.dequeue("a/b")
  assert(State.read().queue["a/b"] == nil)

  -- Blacklist
  assert(State.is_blacklisted("c/d", "badsha") == false)
  State.blacklist("c/d", "badsha")
  assert(State.is_blacklisted("c/d", "badsha") == true)

  -- Blacklist duplicate
  State.blacklist("c/d", "badsha")
  assert(#State.read().blacklist["c/d"] == 1)

  -- Log update and cap
  for i = 1, 12 do
    State.log_update("e/f", "from" .. i, "to" .. i)
  end
  local log = State.read().update_log["e/f"]
  assert(#log == 10)
  assert(log[1].to == "to12") -- Newest first
  assert(log[10].to == "to3") -- Oldest kept
end

local function test_persistence()
  print("Testing persistence...")
  clear_state()

  State.queue_pending("pers/ist", "sha_pers")

  -- Simulate restart by clearing cache
  State._cache = nil

  local s = State.read()
  assert(s.queue["pers/ist"].commit == "sha_pers")
end

local function test_corruption_recovery()
  print("Testing corruption recovery...")
  clear_state()

  local state_path = vim.fn.stdpath("state") .. "/packard-state.json"
  State._init()
  local f = io.open(state_path, "w")
  if f then
    f:write("invalid json {")
    f:close()
  end

  local s = State.read()
  assert(s.queue ~= nil)
  assert(type(s.queue) == "table")
end

local function test_exists()
  print("Testing State.exists()...")
  clear_state()

  -- Should return false when no file exists
  assert(State.exists() == false)

  -- After a write, should return true
  State.queue_pending("x/y", "some-sha")
  assert(State.exists() == true)

  -- Should not populate the cache (uncached check)
  clear_state()
  assert(State.exists() == false)
  assert(State._cache == nil, "exists() should not populate cache")
end

test_basic_ops()
test_persistence()
test_corruption_recovery()
test_exists()

print("State Manager tests passed!")
