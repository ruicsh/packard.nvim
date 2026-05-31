return function(State)
  ---Queue a pending update
  ---@param owner_repo string
  ---@param sha string
  ---@param timestamp string|nil ISO 8601, defaults to now
  ---@param tag string|nil
  function State.queue_pending(owner_repo, sha, timestamp, tag)
    local s = State.read()
    s.queue[owner_repo] = {
      commit = sha,
      tag = tag,
      discovered_at = timestamp or os.date("!%Y-%m-%dT%H:%M:%SZ") --[[@as string]],
    }
    State.write()
  end

  ---Remove from queue
  ---@param owner_repo string
  function State.dequeue(owner_repo)
    local s = State.read()
    s.queue[owner_repo] = nil
    State.write()
  end

  ---Add to blacklist
  ---@param owner_repo string
  ---@param sha string
  function State.blacklist(owner_repo, sha)
    local s = State.read()
    s.blacklist[owner_repo] = s.blacklist[owner_repo] or {}

    -- Check if already blacklisted
    for _, existing_sha in ipairs(s.blacklist[owner_repo]) do
      if existing_sha == sha then
        return
      end
    end

    table.insert(s.blacklist[owner_repo], sha)
    State.write()
  end

  ---Check if commit is blacklisted
  ---@param owner_repo string
  ---@param sha string
  ---@return boolean
  function State.is_blacklisted(owner_repo, sha)
    local s = State.read()
    local list = s.blacklist[owner_repo]
    if not list then
      return false
    end
    for _, blacklisted_sha in ipairs(list) do
      if blacklisted_sha == sha then
        return true
      end
    end
    return false
  end

  ---Purge metadata for an orphaned plugin
  ---@param owner_repo string
  function State.purge_stale_metadata(owner_repo)
    local s = State.read()
    local changed = false

    if s.queue[owner_repo] then
      s.queue[owner_repo] = nil
      changed = true
    end

    if s.blacklist[owner_repo] then
      s.blacklist[owner_repo] = nil
      changed = true
    end

    if changed then
      State.write()
    end
  end
end
