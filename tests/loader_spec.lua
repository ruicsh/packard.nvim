local Helpers = require("tests.helpers")
local packard = require("packard")
local Loader = require("packard.loader")

Helpers.describe("Loader eager loading", function()
  -- Mock Git/Bootstrap
  local Git = require("packard.git")
  Git.get_default_branch = function()
    return "main"
  end
  Git.check_network = function()
    return true
  end

  local original_bootstrap = packard._bootstrap
  packard._bootstrap = function() end

  -- Mock vim.cmd.packadd to simulate loading
  local loaded = {}
  local original_packadd = vim.cmd.packadd
  vim.cmd.packadd = function(opts)
    if type(opts) == "table" and opts.args then
      loaded[opts.args[1]] = true
    end
  end

  Helpers.it("loads and configures plugins eagerly", function()
    local config_called = false
    local init_called = false

    packard.setup({
      self_management = false,
      plugins = {
        {
          "user/test",
          init = function()
            init_called = true
          end,
          config = function()
            config_called = true
          end,
        },
      },
    })

    Helpers.expect(init_called).to_be(true)
    Helpers.expect(loaded["test"]).to_be(true)
    Helpers.expect(config_called).to_be(true)
  end)

  Helpers.it("creates real keymaps immediately", function()
    local fired = false
    packard.setup({
      self_management = false,
      plugins = {
        {
          "user/keys",
          keys = {
            {
              "<leader>tk",
              function()
                fired = true
              end,
              desc = "test key",
            },
          },
        },
      },
    })

    -- Check if mapping exists
    local map = vim.fn.maparg("<leader>tk", "n", false, true)
    Helpers.expect(type(map)).to_be("table")
    Helpers.expect(map.desc).to_be("test key")

    -- Fire it
    if type(map.callback) == "function" then
      map.callback()
    end
    Helpers.expect(fired).to_be(true)

    -- Cleanup
    pcall(vim.keymap.del, "n", "<leader>tk")
  end)

  Helpers.it("silently skips duplicate keymaps", function()
    local p1_called = false
    local p2_called = false

    packard.setup({
      self_management = false,
      plugins = {
        {
          "user/p1",
          keys = {
            {
              "<leader>dup",
              function()
                p1_called = true
              end,
              desc = "first",
            },
          },
        },
        {
          "user/p2",
          keys = {
            {
              "<leader>dup",
              function()
                p2_called = true
              end,
              desc = "second",
            },
          },
        },
      },
    })

    local map = vim.fn.maparg("<leader>dup", "n", false, true)
    Helpers.expect(type(map)).to_be("table")
    Helpers.expect(map.desc).to_be("first") -- First one should win

    if type(map.callback) == "function" then
      map.callback()
    end
    Helpers.expect(p1_called).to_be(true)
    Helpers.expect(p2_called).to_be(false)

    -- Cleanup
    pcall(vim.keymap.del, "n", "<leader>dup")
  end)

  Helpers.it("silently skips duplicate keymaps (string RHS)", function()
    packard.setup({
      self_management = false,
      plugins = {
        {
          "user/s1",
          keys = {
            { "<leader>sdup", ":first<cr>", desc = "first" },
          },
        },
        {
          "user/s2",
          keys = {
            { "<leader>sdup", ":second<cr>", desc = "second" },
          },
        },
      },
    })

    local map = vim.fn.maparg("<leader>sdup", "n", false, true)
    Helpers.expect(type(map)).to_be("table")
    Helpers.expect(map.desc).to_be("first")

    -- Cleanup
    pcall(vim.keymap.del, "n", "<leader>sdup")
  end)

  Helpers.it("creates real commands immediately", function()
    packard.setup({
      self_management = false,
      plugins = {
        { "user/cmd", cmd = "TestCommand" },
      },
    })

    local exists = vim.fn.exists(":TestCommand")
    Helpers.expect(exists).to_be(2)

    -- Cleanup
    pcall(vim.api.nvim_del_user_command, "TestCommand")
  end)

  Helpers.it("skips plugins when cond is false", function()
    local config_called = false
    packard.setup({
      self_management = false,
      plugins = {
        {
          "user/skipped",
          cond = false,
          config = function()
            config_called = true
          end,
        },
      },
    })

    Helpers.expect(loaded["skipped"]).to_be_nil()
    Helpers.expect(config_called).to_be(false)
  end)

  Helpers.it("force-loads dependencies first", function()
    local load_order = {}
    packard.setup({
      self_management = false,
      plugins = {
        {
          "user/main",
          dependencies = { "user/dep" },
          config = function()
            table.insert(load_order, "main")
          end,
        },
        {
          "user/dep",
          config = function()
            table.insert(load_order, "dep")
          end,
        },
      },
    })

    Helpers.expect(load_order[1]).to_be("dep")
    Helpers.expect(load_order[2]).to_be("main")
  end)

  -- Restore
  packard._bootstrap = original_bootstrap
  vim.cmd.packadd = original_packadd
end)
