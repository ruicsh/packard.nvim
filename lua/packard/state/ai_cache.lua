local ai_cache_path = vim.fs.joinpath(vim.fn.stdpath("state"), "packard-ai-cache.json")

return function(State)
  ---@class AICacheEntry
  ---@field summary string
  ---@field risk string "Low"|"Medium"|"High"
  ---@field reasoning string
  ---@field cached_at string ISO 8601

  ---@type table<string, AICacheEntry>|nil
  State._ai_cache = nil

  ---Read AI cache from disk
  ---@return table<string, AICacheEntry>
  function State.read_ai_cache()
    if State._ai_cache then
      return State._ai_cache
    end

    if vim.fn.filereadable(ai_cache_path) == 0 then
      State._ai_cache = {}
      return State._ai_cache
    end

    local f = io.open(ai_cache_path, "r")
    if not f then
      State._ai_cache = {}
      return State._ai_cache
    end

    local content = f:read("*a")
    f:close()

    local ok, decoded = pcall(vim.json.decode, content)
    if not ok or type(decoded) ~= "table" then
      State._ai_cache = {}
      return State._ai_cache
    end

    State._ai_cache = decoded
    return State._ai_cache
  end

  ---Write AI cache to disk (atomic)
  function State.write_ai_cache()
    if not State._ai_cache then
      return
    end

    State._init()
    local temp_path = ai_cache_path .. ".tmp"
    local f = io.open(temp_path, "w")
    if not f then
      vim.notify("packard: could not open temp AI cache file: " .. temp_path, vim.log.levels.ERROR)
      return
    end
    local ok, write_err = pcall(f.write, f, vim.json.encode(State._ai_cache))
    f:close()
    if not ok then
      os.remove(temp_path)
      vim.notify("packard: AI cache write failed: " .. tostring(write_err), vim.log.levels.ERROR)
      return
    end
    os.rename(temp_path, ai_cache_path)
  end

  ---Get AI cache entry
  ---@param owner_repo string
  ---@param from_sha string
  ---@param to_sha string
  ---@return AICacheEntry|nil
  function State.get_ai_cache(owner_repo, from_sha, to_sha)
    local key = string.format("%s:%s:%s", owner_repo, from_sha, to_sha)
    return State.read_ai_cache()[key]
  end

  ---Set AI cache entry
  ---@param owner_repo string
  ---@param from_sha string
  ---@param to_sha string
  ---@param result AICacheEntry
  function State.set_ai_cache(owner_repo, from_sha, to_sha, result)
    local key = string.format("%s:%s:%s", owner_repo, from_sha, to_sha)
    State.read_ai_cache()[key] = result
    State.write_ai_cache()
  end
end
