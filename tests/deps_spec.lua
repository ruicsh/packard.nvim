local Deps = require("packard.deps")
local Utils = require("packard.utils")

-- Mock vim.api.nvim_get_option_value for build_available_set
local original_get_option = vim.api.nvim_get_option_value
local mock_rtp = ""

--[[@diagnostic disable-next-line: duplicate-set-field]]
vim.api.nvim_get_option_value = function(name, opts)
  if name == "runtimepath" then
    return mock_rtp
  end
  return original_get_option(name, opts)
end

-- Mock Utils.get_plugin_path
local original_get_path = Utils.get_plugin_path
local mock_plugin_path = ""
--[[@diagnostic disable-next-line: duplicate-set-field]]
Utils.get_plugin_path = function(_)
  return mock_plugin_path
end

-- Mock vim.pack.add
local add_calls = {}
--[[@diagnostic disable-next-line: duplicate-set-field]]
vim.pack = {
  add = function(specs, opts)
    table.insert(add_calls, { specs = specs, opts = opts })
    return true
  end,
}

local function test_available_set()
  print("Testing build_available_set...")
  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir .. "/lua/plenary", "p")
  vim.fn.mkdir(temp_dir .. "/lua/other.lua", "p") -- directory named .lua (edge case)
  local f = io.open(temp_dir .. "/lua/single_module.lua", "w")
  if f then
    f:write("return {}")
    f:close()
  end

  mock_rtp = temp_dir
  local set = Deps.build_available_set()
  assert(set["plenary"] == true)
  assert(set["single_module"] == true)
  assert(set["other.lua"] == true)
end

local function test_scan_requires()
  print("Testing scan_requires...")
  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir .. "/plugin", "p")
  vim.fn.mkdir(temp_dir .. "/lua/test_plugin", "p")

  local f1 = io.open(temp_dir .. "/plugin/init.lua", "w")
  if f1 then
    f1:write('local p = require("plenary.async")\n')
    f1:write('require "nui.popup"\n')
    f1:close()
  end

  local f2 = io.open(temp_dir .. "/lua/test_plugin/init.lua", "w")
  if f2 then
    f2:write('local dev = require("nvim-web-devicons")\n')
    f2:write('local internal = require(".internal")\n') -- should be ignored
    f2:close()
  end

  local found = Deps.scan_requires(temp_dir)
  assert(found["plenary.async"] == true)
  assert(found["nui.popup"] == true)
  assert(found["nvim-web-devicons"] == true)
  assert(found[".internal"] == nil)
end

local function test_verify_and_install()
  print("Testing verify_and_install...")
  add_calls = {}
  mock_rtp = "/tmp/fake-rtp" -- nothing available

  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir .. "/plugin", "p")
  local f = io.open(temp_dir .. "/plugin/main.lua", "w")
  if f then
    f:write('require("blink.lib")\n')
    f:close()
  end

  mock_plugin_path = temp_dir

  local plugins = {
    { name = "test-plugin", owner_repo = "user/test-plugin" },
  }

  local installed = Deps.verify_and_install(plugins)
  assert(#installed == 1)
  assert(installed[1].owner_repo == "saghen/blink.lib")
  assert(#add_calls == 1)
  assert(add_calls[1].specs[1].src == "https://github.com/saghen/blink.lib.git")
  assert(add_calls[1].specs[1].name == "blink.lib")
end

test_available_set()
test_scan_requires()
test_verify_and_install()

-- Restore mocks if possible or just exit
print("Deps tests passed!")
