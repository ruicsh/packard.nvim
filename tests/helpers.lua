local M = {}

function M.describe(name, fn)
  print("\n" .. name)
  fn()
end

function M.it(name, fn)
  local ok, err = pcall(fn)
  if ok then
    print("  ✓ " .. name)
  else
    print("  ✗ " .. name)
    print("    " .. tostring(err))
    error(err)
  end
end

function M.expect(actual)
  return {
    to_be = function(expected)
      if actual ~= expected then
        error(string.format("Expected %s but got %s", vim.inspect(expected), vim.inspect(actual)))
      end
    end,
    to_contain = function(item)
      if type(actual) ~= "table" then
        error("actual is not a table")
      end
      local found = false
      for _, v in pairs(actual) do
        if v == item then
          found = true
          break
        end
      end
      if not found then
        error(string.format("Expected %s to contain %s", vim.inspect(actual), vim.inspect(item)))
      end
    end,
    to_be_nil = function()
      if actual ~= nil then
        error(string.format("Expected nil but got %s", vim.inspect(actual)))
      end
    end,
    to_not_be_nil = function()
      if actual == nil then
        error("Expected non-nil but got nil")
      end
    end,
    to_be_truthy = function()
      if not actual then
        error(string.format("Expected truthy but got %s", vim.inspect(actual)))
      end
    end,
    to_be_falsy = function()
      if actual then
        error(string.format("Expected falsy but got %s", vim.inspect(actual)))
      end
    end,
  }
end

function M.mock(mod, fn_name, stub)
  local original = mod[fn_name]
  mod[fn_name] = stub
  return function()
    mod[fn_name] = original
  end
end

---Create a temp directory with given files
---@param files table<string, string> filename -> content
---@return string path, function cleanup
function M.with_temp_dir(files)
  local temp_dir = vim.fn.tempname()
  --[[@diagnostic disable-next-line: redundant-parameter]]
  vim.fn.mkdir(temp_dir, "p")

  for name, content in pairs(files) do
    local path = vim.fs.joinpath(temp_dir, name)
    local dir = vim.fn.fnamemodify(path, ":h")
    if vim.fn.isdirectory(dir) == 0 then
      --[[@diagnostic disable-next-line: redundant-parameter]]
      vim.fn.mkdir(dir, "p")
    end
    local f = io.open(path, "w")
    if f then
      f:write(content)
      f:close()
    end
  end

  local cleanup = function()
    vim.fn.delete(temp_dir, "rf")
  end

  return temp_dir, cleanup
end

return M
