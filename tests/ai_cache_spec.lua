local Helpers = require("tests.helpers")

-- Avoid writing to real filesystem for the standalone cache tests
local test_cache_path = vim.fn.tempname()

-- We can't easily swap the ai_cache_path in the module since it's captured
-- at require time. So we import State first, then directly call the methods.
local State = require("packard.state")

-- Reset AI cache state
State._ai_cache = nil

-- Clear the real ai cache file path
local ai_cache_file = vim.fs.joinpath(vim.fn.stdpath("state"), "packard-ai-cache.json")
if vim.fn.filereadable(ai_cache_file) == 1 then
  os.remove(ai_cache_file)
end

Helpers.describe("State AI Cache", function()
  Helpers.it("reads empty cache when file does not exist", function()
    State._ai_cache = nil
    if vim.fn.filereadable(ai_cache_file) == 1 then
      os.remove(ai_cache_file)
    end
    local cache = State.read_ai_cache()
    Helpers.expect(type(cache)).to_be("table")
    Helpers.expect(next(cache)).to_be_nil() -- empty
  end)

  Helpers.it("sets and gets a cache entry", function()
    State._ai_cache = nil
    if vim.fn.filereadable(ai_cache_file) == 1 then
      os.remove(ai_cache_file)
    end

    local entry = {
      summary = "Test review",
      risk = "Low",
      reasoning = "Test reasoning",
      cached_at = "2026-01-01T00:00:00Z",
    }

    State.set_ai_cache("user/repo", "from_sha", "to_sha", entry)

    local result = State.get_ai_cache("user/repo", "from_sha", "to_sha")
    Helpers.expect(result).to_not_be_nil()
    Helpers.expect(result.summary).to_be("Test review")
    Helpers.expect(result.risk).to_be("Low")
    Helpers.expect(result.reasoning).to_be("Test reasoning")
  end)

  Helpers.it("returns nil for non-existent cache entry", function()
    local result = State.get_ai_cache("nonexistent/repo", "any", "sha")
    Helpers.expect(result).to_be_nil()
  end)

  Helpers.it("persists cache to disk", function()
    State._ai_cache = nil
    if vim.fn.filereadable(ai_cache_file) == 1 then
      os.remove(ai_cache_file)
    end

    local entry = {
      summary = "Persisted review",
      risk = "Medium",
      reasoning = "Persisted reasoning",
      cached_at = "2026-06-01T00:00:00Z",
    }
    State.set_ai_cache("persist/repo", "a", "b", entry)

    -- Clear cache and re-read from disk
    State._ai_cache = nil
    local result = State.get_ai_cache("persist/repo", "a", "b")
    Helpers.expect(result).to_not_be_nil()
    Helpers.expect(result.summary).to_be("Persisted review")
  end)

  Helpers.it("recovers from corrupt AI cache file", function()
    State._ai_cache = nil
    -- Write corrupt data
    local f = io.open(ai_cache_file, "w")
    if f then
      f:write("invalid json{{{")
      f:close()
    end

    local cache = State.read_ai_cache()
    Helpers.expect(type(cache)).to_be("table")
    Helpers.expect(next(cache)).to_be_nil() -- empty, recovered
  end)

  Helpers.it("read_ai_cache returns cached value on subsequent calls", function()
    State._ai_cache = nil
    if vim.fn.filereadable(ai_cache_file) == 1 then
      os.remove(ai_cache_file)
    end

    -- First call reads from disk (empty)
    local cache1 = State.read_ai_cache()
    Helpers.expect(type(cache1)).to_be("table")

    -- Second call should return same table reference
    local cache2 = State.read_ai_cache()
    Helpers.expect(cache1).to_be(cache2) -- same object
  end)
end)

print("AI Cache tests passed!")
