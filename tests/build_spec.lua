local Helpers = require("tests.helpers")
local Build = require("packard.build")
local packard = require("packard")

-- Mock Git and bootstrap to avoid network/fs calls during tests
local Git = require("packard.git")
Git.get_default_branch = function()
  return nil
end
Git.check_network = function()
  return true
end

local original_bootstrap = packard._bootstrap
packard._bootstrap = function() end

-- Track build function calls
local build_call_tracker = {}

Helpers.describe("Build module", function()
  Helpers.it("returns true when build is false (explicit skip)", function()
    local plugin = {
      owner_repo = "test/plugin",
      name = "plugin",
      build = false,
    }
    -- Create a temp dir to simulate installed plugin
    local temp_dir = vim.fn.tempname()
    --[[@diagnostic disable-next-line: redundant-parameter]]
    vim.fn.mkdir(temp_dir, "p")

    -- Mock Utils.get_plugin_path to return our temp dir
    local Utils = require("packard.utils")
    local orig_get_path = Utils.get_plugin_path
    Utils.get_plugin_path = function(name)
      return temp_dir
    end

    local ok = Build.run(plugin)
    Helpers.expect(ok).to_be(true)

    -- Cleanup
    Utils.get_plugin_path = orig_get_path
    vim.fn.delete(temp_dir, "rf")
  end)

  Helpers.it("skips build.lua when build is false (explicit skip even with file present)", function()
    -- Create a temp dir with a build.lua file
    local temp_dir, cleanup = Helpers.with_temp_dir({
      ["build.lua"] = [[
        io.open(vim.fn.stdpath("state") .. "/build_was_run_marker", "w"):close()
      ]],
    })

    -- Remove any leftover marker
    local marker_path = vim.fn.stdpath("state") .. "/build_was_run_marker"
    pcall(vim.fn.delete, marker_path)

    local plugin = {
      owner_repo = "test/plugin",
      name = "plugin",
      build = false,
    }
    local Utils = require("packard.utils")
    local orig_get_path = Utils.get_plugin_path
    Utils.get_plugin_path = function(name)
      return temp_dir
    end

    local ok = Build.run(plugin)
    Helpers.expect(ok).to_be(true)

    -- Verify build.lua was NOT executed
    local marker_exists = vim.fn.filereadable(marker_path) == 1
    Helpers.expect(marker_exists).to_be(false)

    Utils.get_plugin_path = orig_get_path
    cleanup()
    pcall(vim.fn.delete, marker_path)
  end)

  Helpers.it("returns true when no build field and no build.lua", function()
    local plugin = {
      owner_repo = "test/plugin",
      name = "plugin",
    }
    local temp_dir = vim.fn.tempname()
    --[[@diagnostic disable-next-line: redundant-parameter]]
    vim.fn.mkdir(temp_dir, "p")

    local Utils = require("packard.utils")
    local orig_get_path = Utils.get_plugin_path
    Utils.get_plugin_path = function(name)
      return temp_dir
    end

    local ok = Build.run(plugin)
    Helpers.expect(ok).to_be(true)

    Utils.get_plugin_path = orig_get_path
    vim.fn.delete(temp_dir, "rf")
  end)

  Helpers.it("calls build function with plugin table", function()
    build_call_tracker = {}
    local plugin = {
      owner_repo = "test/plugin",
      name = "plugin",
      build = function(p)
        build_call_tracker.called = true
        build_call_tracker.owner_repo = p.owner_repo
      end,
    }
    local temp_dir = vim.fn.tempname()
    --[[@diagnostic disable-next-line: redundant-parameter]]
    vim.fn.mkdir(temp_dir, "p")

    local Utils = require("packard.utils")
    local orig_get_path = Utils.get_plugin_path
    Utils.get_plugin_path = function(name)
      return temp_dir
    end

    local ok = Build.run(plugin)
    Helpers.expect(ok).to_be(true)
    Helpers.expect(build_call_tracker.called).to_be(true)
    Helpers.expect(build_call_tracker.owner_repo).to_be("test/plugin")

    Utils.get_plugin_path = orig_get_path
    vim.fn.delete(temp_dir, "rf")
  end)

  Helpers.it("reports error when build function throws", function()
    local plugin = {
      owner_repo = "test/plugin",
      name = "plugin",
      build = function()
        error("build failed intentionally")
      end,
    }
    local temp_dir = vim.fn.tempname()
    --[[@diagnostic disable-next-line: redundant-parameter]]
    vim.fn.mkdir(temp_dir, "p")

    local Utils = require("packard.utils")
    local orig_get_path = Utils.get_plugin_path
    Utils.get_plugin_path = function(name)
      return temp_dir
    end

    local ok = Build.run(plugin)
    Helpers.expect(ok).to_be(false)

    Utils.get_plugin_path = orig_get_path
  end)

  Helpers.it("handles list of build steps", function()
    build_call_tracker = {}
    local plugin = {
      owner_repo = "test/plugin",
      name = "plugin",
      build = {
        function(p)
          build_call_tracker.step1 = true
        end,
        function(p)
          build_call_tracker.step2 = true
        end,
      },
    }
    local temp_dir = vim.fn.tempname()
    --[[@diagnostic disable-next-line: redundant-parameter]]
    vim.fn.mkdir(temp_dir, "p")

    local Utils = require("packard.utils")
    local orig_get_path = Utils.get_plugin_path
    Utils.get_plugin_path = function(name)
      return temp_dir
    end

    local ok = Build.run(plugin)
    Helpers.expect(ok).to_be(true)
    Helpers.expect(build_call_tracker.step1).to_be(true)
    Helpers.expect(build_call_tracker.step2).to_be(true)

    Utils.get_plugin_path = orig_get_path
    vim.fn.delete(temp_dir, "rf")
  end)

  Helpers.it("continues remaining steps after one fails", function()
    build_call_tracker = {}
    local plugin = {
      owner_repo = "test/plugin",
      name = "plugin",
      build = {
        function()
          build_call_tracker.step1 = true
          error("step 1 failed")
        end,
        function()
          build_call_tracker.step2 = true
        end,
      },
    }
    local temp_dir = vim.fn.tempname()
    --[[@diagnostic disable-next-line: redundant-parameter]]
    vim.fn.mkdir(temp_dir, "p")

    local Utils = require("packard.utils")
    local orig_get_path = Utils.get_plugin_path
    Utils.get_plugin_path = function(name)
      return temp_dir
    end

    local ok = Build.run(plugin)
    Helpers.expect(ok).to_be(false) -- overall failure
    Helpers.expect(build_call_tracker.step1).to_be(true)
    Helpers.expect(build_call_tracker.step2).to_be(true) -- still runs

    Utils.get_plugin_path = orig_get_path
    vim.fn.delete(temp_dir, "rf")
  end)

  Helpers.it("auto-detects build.lua file", function()
    build_call_tracker = {}
    local temp_dir = vim.fn.tempname()
    --[[@diagnostic disable-next-line: redundant-parameter]]
    vim.fn.mkdir(temp_dir, "p")

    -- Create build.lua
    local f, err = io.open(temp_dir .. "/build.lua", "w")
    if not f then
      error("failed to write build.lua: " .. tostring(err))
    end
    f:write([[
_G.__build_tracker = { auto_detected = true }
]])
    f:close()

    local plugin = {
      owner_repo = "test/plugin",
      name = "plugin",
    }

    local Utils = require("packard.utils")
    local orig_get_path = Utils.get_plugin_path
    Utils.get_plugin_path = function(name)
      return temp_dir
    end

    local ok = Build.run(plugin)
    Helpers.expect(ok).to_be(true)
    Helpers.expect(_G.__build_tracker and _G.__build_tracker.auto_detected).to_be(true)

    -- Cleanup
    _G.__build_tracker = nil
    Utils.get_plugin_path = orig_get_path
    vim.fn.delete(temp_dir, "rf")
  end)

  Helpers.it("auto-detects build/init.lua file", function()
    local temp_dir = vim.fn.tempname()
    --[[@diagnostic disable-next-line: redundant-parameter]]
    vim.fn.mkdir(temp_dir .. "/build", "p")

    -- Create build/init.lua
    local f, err = io.open(temp_dir .. "/build/init.lua", "w")
    if not f then
      error("failed to write build/init.lua: " .. tostring(err))
    end
    f:write([[
_G.__build_tracker2 = { auto_detected_init = true }
]])
    f:close()

    local plugin = {
      owner_repo = "test/plugin",
      name = "plugin",
    }

    local Utils = require("packard.utils")
    local orig_get_path = Utils.get_plugin_path
    Utils.get_plugin_path = function(name)
      return temp_dir
    end

    local ok = Build.run(plugin)
    Helpers.expect(ok).to_be(true)
    Helpers.expect(_G.__build_tracker2 and _G.__build_tracker2.auto_detected_init).to_be(true)

    -- Cleanup
    _G.__build_tracker2 = nil
    Utils.get_plugin_path = orig_get_path
    vim.fn.delete(temp_dir, "rf")
  end)

  Helpers.it("build=false skips even if build.lua exists", function()
    local temp_dir = vim.fn.tempname()
    --[[@diagnostic disable-next-line: redundant-parameter]]
    vim.fn.mkdir(temp_dir, "p")

    -- Create build.lua
    local f, err = io.open(temp_dir .. "/build.lua", "w")
    if not f then
      error("failed to write build.lua: " .. tostring(err))
    end
    f:write([[
_G.__build_tracker3 = { should_not_run = true }
]])
    f:close()

    local plugin = {
      owner_repo = "test/plugin",
      name = "plugin",
      build = false,
    }

    local Utils = require("packard.utils")
    local orig_get_path = Utils.get_plugin_path
    Utils.get_plugin_path = function(name)
      return temp_dir
    end

    local ok = Build.run(plugin)
    Helpers.expect(ok).to_be(true)
    Helpers.expect(_G.__build_tracker3).to_be(nil) -- should not have run

    -- Cleanup
    Utils.get_plugin_path = orig_get_path
    vim.fn.delete(temp_dir, "rf")
  end)
end)

Helpers.describe("Build field in parser", function()
  Helpers.it("parses build as a string", function()
    packard.setup({
      self_management = false,
      plugins = {
        { "owner/repo", build = ":TSUpdate" },
      },
    })

    local p = packard.plugins[1]
    Helpers.expect(p.build).to_be(":TSUpdate")
  end)

  Helpers.it("parses build as a function", function()
    local build_fn = function(plugin) end
    packard.setup({
      self_management = false,
      plugins = {
        { "owner/repo", build = build_fn },
      },
    })

    local p = packard.plugins[1]
    Helpers.expect(p.build).to_be(build_fn)
  end)

  Helpers.it("parses build as a list", function()
    local build_fn = function(plugin) end
    packard.setup({
      self_management = false,
      plugins = {
        { "owner/repo", build = { "make", build_fn, ":TSUpdate" } },
      },
    })

    local p = packard.plugins[1]
    Helpers.expect(type(p.build)).to_be("table")
    Helpers.expect(#p.build).to_be(3)
    Helpers.expect(p.build[1]).to_be("make")
    Helpers.expect(p.build[2]).to_be(build_fn)
    Helpers.expect(p.build[3]).to_be(":TSUpdate")
  end)

  Helpers.it("parses build as false", function()
    packard.setup({
      self_management = false,
      plugins = {
        { "owner/repo", build = false },
      },
    })

    local p = packard.plugins[1]
    Helpers.expect(p.build).to_be(false)
  end)

  Helpers.it("errors on invalid build type (number)", function()
    local ok, err = pcall(function()
      packard.setup({
        self_management = false,
        plugins = {
          { "owner/repo", build = 42 },
        },
      })
    end)
    Helpers.expect(ok).to_be(false)
    Helpers.expect(err:find("build")).to_be_truthy()
  end)

  Helpers.it("errors on invalid build list element (table)", function()
    local ok, err = pcall(function()
      packard.setup({
        self_management = false,
        plugins = {
          { "owner/repo", build = { "make", { invalid = true } } },
        },
      })
    end)
    Helpers.expect(ok).to_be(false)
    Helpers.expect(err:find("build")).to_be_truthy()
  end)
end)

print("Build tests passed!")
