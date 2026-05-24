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
    to_be_truthy = function()
      if not actual then
        error(string.format("Expected truthy but got %s", vim.inspect(actual)))
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

return M
