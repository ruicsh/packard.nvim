local M = {}

---Validate the `dir` field (must be a non-empty string if provided).
---@param spec table Raw plugin spec
function M.validate_dir(spec)
  if spec.dir ~= nil then
    if type(spec.dir) ~= "string" then
      error(string.format("packard: 'dir' must be a string, got %s", type(spec.dir)))
    end
    if spec.dir == "" then
      error("packard: 'dir' must not be empty")
    end
  end
end

---Validate and resolve pin fields (branch, tag, commit, version, minimum_release_age).
---@param spec table Raw plugin spec
---@param owner_repo string
---@param defaults table
---@return { branch: string|nil, tag: string|nil, commit: string|nil, version: string|nil, min_age: number }
function M.pin_fields(spec, owner_repo, defaults)
  local branch = spec.branch

  local tag = spec.tag
  if tag and type(tag) ~= "string" then
    error(string.format("packard: 'tag' for '%s' must be a string", owner_repo))
  end

  local commit = spec.commit
  if commit then
    if type(commit) ~= "string" then
      error(string.format("packard: 'commit' for '%s' must be a string", owner_repo))
    end
    if not commit:match("^%x+$") then
      error(string.format("packard: invalid commit SHA '%s' for '%s'", commit, owner_repo))
    end
  end

  -- Resolve version
  local version = spec.version
  if version == nil and not tag and not commit and not branch then
    version = defaults.version
  end
  if version == false then
    version = nil
  end

  if version then
    local Semver = require("packard.semver")
    if not Semver.to_range(version) then
      error(string.format("packard: invalid version constraint '%s' for '%s'", version, owner_repo))
    end
  end

  local min_age = spec.minimum_release_age or defaults.minimum_release_age or 30
  if type(min_age) ~= "number" or min_age < 0 then
    error(string.format("packard: 'minimum_release_age' for '%s' must be a number (days)", owner_repo))
  end

  return {
    branch = branch,
    tag = tag,
    commit = commit,
    version = version,
    min_age = min_age,
  }
end

---Validate runtime fields: config, init, main, build.
---Raises errors on invalid types.
---@param spec table Raw plugin spec
---@param owner_repo string
function M.runtime_fields(spec, owner_repo)
  if spec.config ~= nil and type(spec.config) ~= "function" and spec.config ~= true then
    error(string.format("packard: 'config' for '%s' must be a function or true", owner_repo))
  end
  if spec.init and type(spec.init) ~= "function" then
    error(string.format("packard: 'init' for '%s' must be a function", owner_repo))
  end
  if spec.main ~= nil and type(spec.main) ~= "string" then
    error(string.format("packard: 'main' for '%s' must be a string", owner_repo))
  end

  local build = spec.build
  if build ~= nil then
    if type(build) == "table" then
      for i, b in ipairs(build) do
        if type(b) ~= "string" and type(b) ~= "function" then
          error(
            string.format(
              "packard: 'build' for '%s' must be a string, function, or list of strings/functions (element %d is %s)",
              owner_repo,
              i,
              type(b)
            )
          )
        end
      end
    elseif type(build) ~= "string" and type(build) ~= "function" and build ~= false then
      error(
        string.format(
          "packard: 'build' for '%s' must be a string, function, false, or list of strings/functions",
          owner_repo
        )
      )
    end
  end
end

return M
