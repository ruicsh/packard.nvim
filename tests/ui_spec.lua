local Helpers = require("tests.helpers")

-- Mock modules
local State = require("packard.state")
local Cooldown = require("packard.cooldown")
local Lockfile = require("packard.lockfile")

local original_state_read = State.read
local original_cooldown_get_status = Cooldown.get_status
local original_lockfile_get_installed = Lockfile.get_installed_commit

--[[@diagnostic disable-next-line: duplicate-set-field]]
State.read = function()
  return { queue = {}, update_log = {}, blacklist = {} }
end
--[[@diagnostic disable-next-line: duplicate-set-field]]
Cooldown.get_status = function()
  return { eligible = {}, cooldown = {} }
end
--[[@diagnostic disable-next-line: duplicate-set-field]]
Lockfile.get_installed_commit = function()
  return "abc1234"
end

local UI = require("packard.ui")

Helpers.describe("UI Dashboard", function()
  Helpers.it("opens with default tab", function()
    UI.open({}, "installed")
    Helpers.expect(UI.tab).to_be("installed")
    Helpers.expect(vim.api.nvim_buf_is_valid(UI.buf)).to_be_truthy()

    -- Check if it rendered (headers should be there)
    -- We need to wait for vim.schedule
    vim.wait(100, function()
      return not UI._render_scheduled
    end)

    local lines = vim.api.nvim_buf_get_lines(UI.buf, 0, -1, false)
    local found = false
    for _, line in ipairs(lines) do
      if line:match("Installed") and line:match("Pending") then
        found = true
        break
      end
    end
    Helpers.expect(found).to_be_truthy()
    UI.close()
  end)

  Helpers.it("switches tabs", function()
    UI.open({}, "installed")

    UI.tab = "pending"
    UI._do_render() -- Bypass schedule for sync test
    local lines = vim.api.nvim_buf_get_lines(UI.buf, 0, -1, false)
    local found = false
    for _, line in ipairs(lines) do
      if line:match("Pending") then
        found = true
        break
      end
    end
    Helpers.expect(found).to_be_truthy()
    UI.close()
  end)

  Helpers.it("shows help tab", function()
    UI.open({}, "help")
    UI._do_render()
    local lines = vim.api.nvim_buf_get_lines(UI.buf, 0, -1, false)
    for i, l in ipairs(lines) do
      print(string.format("line %d: %q", i, l))
    end
    local found = false
    for _, line in ipairs(lines) do
      if line:match("KEYBINDINGS:") then
        found = true
        break
      end
    end
    Helpers.expect(found).to_be_truthy()
    UI.close()
  end)

  Helpers.it("renders AI expansion", function()
    UI.open({}, "pending")
    UI.ai_results = {
      ["owner/repo"] = {
        state = "result",
        data = {
          summary = "This is a summary of the AI review.",
          risk = "low",
          reasoning = "The reasoning behind the risk level.",
        },
      },
    }
    UI.expanded_row = "owner/repo"

    -- Mock Cooldown.get_status to return our plugin
    local old_get_status = Cooldown.get_status
    --[[@diagnostic disable-next-line: duplicate-set-field]]
    Cooldown.get_status = function()
      return {
        eligible = {
          ["owner/repo"] = { commit = "abcdef1", remaining_days = 0 },
        },
        cooldown = {},
      }
    end

    UI._do_render()

    local lines = vim.api.nvim_buf_get_lines(UI.buf, 0, -1, false)
    local found_expansion = false
    local found_summary = false
    local found_spinner = false
    for _, line in ipairs(lines) do
      if line:match("AI Review") then
        found_expansion = true
      end
      if line:match("Summary:") and line:match("This is a summary") then
        found_summary = true
      end
    end

    Helpers.expect(found_expansion).to_be_truthy()
    Helpers.expect(found_summary).to_be_truthy()

    -- Test loading state (spinner)
    UI.ai_results["owner/repo"] = { state = "loading" }
    UI._do_render()
    lines = vim.api.nvim_buf_get_lines(UI.buf, 0, -1, false)
    for _, line in ipairs(lines) do
      if line:match("AI review in progress") then
        found_spinner = true
      end
    end
    Helpers.expect(found_spinner).to_be_truthy()
    -- Cleanup
    Cooldown.get_status = old_get_status
    UI.ai_results = {}
    UI.expanded_row = nil
    UI.close()
  end)

  Helpers.it("highlights selected plugin name", function()
    local plugins = { { name = "foo/bar", owner_repo = "foo/bar" }, { name = "baz/qux", owner_repo = "baz/qux" } }
    UI.open(plugins, "installed")
    UI._do_render()

    -- Find the line for "foo/bar"
    local line_idx = nil
    for i, owner_repo in pairs(UI.line_map) do
      if owner_repo == "foo/bar" then
        line_idx = i
        break
      end
    end
    Helpers.expect(line_idx).to_be_truthy()

    -- Simulate cursor on that line
    UI._cursor_repo = "foo/bar"
    UI.apply_highlights()

    local packard_ns = vim.api.nvim_create_namespace("packard")
    local extmarks = vim.api.nvim_buf_get_extmarks(UI.buf, packard_ns, 0, -1, { details = true })
    local found_selected = false
    for _, em in ipairs(extmarks) do
      local row = em[2]
      local details = em[4]
      if row == line_idx - 1 and details.hl_group == "PackardPluginNameSelected" then
        found_selected = true
        break
      end
    end
    Helpers.expect(found_selected).to_be_truthy()

    -- Move cursor away
    UI._cursor_repo = "baz/qux"
    UI.apply_highlights()

    extmarks = vim.api.nvim_buf_get_extmarks(UI.buf, packard_ns, 0, -1, { details = true })
    found_selected = false
    local found_normal = false
    for _, em in ipairs(extmarks) do
      local row = em[2]
      local details = em[4]
      if row == line_idx - 1 then
        if details.hl_group == "PackardPluginNameSelected" then
          found_selected = true
        elseif details.hl_group == "PackardPluginName" then
          found_normal = true
        end
      end
    end
    Helpers.expect(found_selected).to_be(false)
    Helpers.expect(found_normal).to_be_truthy()

    UI.close()
  end)
end)

-- Restore
State.read = original_state_read
Cooldown.get_status = original_cooldown_get_status
Lockfile.get_installed_commit = original_lockfile_get_installed
