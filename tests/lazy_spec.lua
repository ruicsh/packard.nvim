local Helpers = require("tests.helpers")
local packard = require("packard")
local Lockfile = require("packard.lockfile")

Helpers.describe("Lazy Loading", function()
  -- Setup mocks
  local original_pack_add = vim.pack.add
  vim.pack.add = function() end

  local original_isdirectory = vim.fn.isdirectory
  vim.fn.isdirectory = function()
    return 1
  end

  local original_get_installed = Lockfile.get_installed_commit
  Lockfile.get_installed_commit = function()
    return "abc1234"
  end

  Helpers.it("creates keymap stubs", function()
    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/bar",
          keys = { { "<leader>fb", function() end, desc = "Foo Bar" } },
          config = function()
            -- Config would be called when the trigger fires
          end,
        },
      },
    })

    -- Check if stub mapping exists
    local maps = vim.api.nvim_get_keymap("n")
    local found = false
    for _, map in ipairs(maps) do
      if map.lhs == " <leader>fb" or map.lhs == " \22" then -- Keycodes can vary
        found = true
        break
      end
    end
    -- nvim_get_keymap might not show it depending on how it's set
    -- Let's check via pcall to del which should work if it exists
    local ok = pcall(vim.keymap.del, "n", "<leader>fb")
    Helpers.expect(ok).to_be(true)

    -- Cleanup
    pcall(vim.api.nvim_del_augroup_by_name, "packard_load_bar")
  end)

  Helpers.it("creates command stubs", function()
    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/baz",
          cmd = "FooBaz",
          lazy = true,
        },
      },
    })

    local commands = vim.api.nvim_get_commands({})
    Helpers.expect(commands.FooBaz).to_be_truthy()

    -- Cleanup
    vim.api.nvim_del_user_command("FooBaz")
  end)

  Helpers.it("creates event stubs", function()
    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/eventful",
          event = "BufReadPost",
        },
      },
    })

    local autocmds = vim.api.nvim_get_autocmds({ event = "BufReadPost" })
    local found = false
    for _, au in ipairs(autocmds) do
      if au.desc and au.desc:match("packard: load eventful") then
        found = true
        break
      end
    end
    Helpers.expect(found).to_be(true)

    -- Cleanup
    pcall(vim.api.nvim_del_augroup_by_name, "packard_load_eventful")
  end)

  -- Restore mocks
  vim.pack.add = original_pack_add
  vim.fn.isdirectory = original_isdirectory
  Lockfile.get_installed_commit = original_get_installed
end)
