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

  Helpers.describe("_derive_modname", function()
    Helpers.it("returns plugin.main when set", function()
      local plugin = { main = "custom.module", name = "nvim-cmp" }
      Helpers.expect(Loader._derive_modname(plugin)).to_be("custom.module")
    end)

    Helpers.it("strips .nvim suffix", function()
      local plugin = { name = "plenary.nvim" }
      Helpers.expect(Loader._derive_modname(plugin)).to_be("plenary")
    end)

    Helpers.it("strips .vim suffix", function()
      local plugin = { name = "fugitive.vim" }
      Helpers.expect(Loader._derive_modname(plugin)).to_be("fugitive")
    end)

    Helpers.it("strips nvim- prefix", function()
      local plugin = { name = "nvim-cmp" }
      Helpers.expect(Loader._derive_modname(plugin)).to_be("cmp")
    end)

    Helpers.it("strips vim- prefix", function()
      local plugin = { name = "vim-fugitive" }
      Helpers.expect(Loader._derive_modname(plugin)).to_be("fugitive")
    end)

    Helpers.it("strips both nvim- prefix and .nvim suffix", function()
      local plugin = { name = "nvim-plenary.nvim" }
      Helpers.expect(Loader._derive_modname(plugin)).to_be("plenary")
    end)

    Helpers.it("returns name unchanged when no matching prefix/suffix", function()
      local plugin = { name = "blink.cmp" }
      Helpers.expect(Loader._derive_modname(plugin)).to_be("blink.cmp")
      -- mini.nvim is also unchanged
      local plugin2 = { name = "mini.nvim" }
      Helpers.expect(Loader._derive_modname(plugin2)).to_be("mini")
    end)
  end)

  -- Restore
  packard._bootstrap = original_bootstrap
  vim.cmd.packadd = original_packadd
end)

Helpers.describe("_with_silent_cmd (via load_and_config)", function()
  local Git = require("packard.git")
  --[[@diagnostic disable-next-line: duplicate-set-field]]
  Git.get_default_branch = function()
    return "main"
  end
  --[[@diagnostic disable-next-line: duplicate-set-field]]
  Git.check_network = function()
    return true
  end

  local original_bootstrap = packard._bootstrap
  packard._bootstrap = function() end

  -- Spy on vim.cmd: record all string calls, forward sub-commands to original
  local original_cmd = vim.cmd
  local string_calls = {}

  local spy_cmd = setmetatable({}, {
    __call = function(_, s, opts)
      if type(s) == "string" then
        table.insert(string_calls, s)
      end
      return original_cmd(s, opts)
    end,
    __index = function(_, k)
      return original_cmd[k]
    end,
    __newindex = function(_, k, v)
      original_cmd[k] = v
    end,
  })

  vim.cmd = spy_cmd

  -- Mock packadd (needed by load_and_config for non-local plugins)
  original_cmd.packadd = function(opts)
    if type(opts) == "table" and opts.args then
      -- no-op, just prevent errors
    end
  end

  local function clear_calls()
    string_calls = {}
  end

  -- 1. Explicit config wrapping
  Helpers.it("wraps vim.cmd string calls with silent! in explicit config", function()
    clear_calls()
    packard.setup({
      self_management = false,
      plugins = {
        {
          "user/explicit",
          config = function()
            vim.cmd("echo 'hello'")
          end,
        },
      },
    })
    Helpers.expect(#string_calls).to_be(1)
    Helpers.expect(string_calls[1]).to_be("silent! echo 'hello'")
  end)

  -- 2. Auto-setup wrapping
  Helpers.it("wraps vim.cmd string calls with silent! in auto-setup", function()
    clear_calls()
    -- Preload a mock module so require("mock_auto_setup") works
    package.loaded["mock_auto_setup"] = {
      setup = function(opts)
        vim.cmd("echo 'auto setup'")
      end,
    }
    packard.setup({
      self_management = false,
      plugins = {
        {
          "user/auto-test",
          main = "mock_auto_setup",
          opts = { key = "value" },
          config = true,
        },
      },
    })
    Helpers.expect(#string_calls).to_be(1)
    Helpers.expect(string_calls[1]).to_be("silent! echo 'auto setup'")
    package.loaded["mock_auto_setup"] = nil
  end)

  -- 3. No double-wrapping
  Helpers.it("does not double-wrap already-silent commands", function()
    clear_calls()
    packard.setup({
      self_management = false,
      plugins = {
        {
          "user/double",
          config = function()
            vim.cmd("silent! echo 'no double'")
          end,
        },
      },
    })
    Helpers.expect(#string_calls).to_be(1)
    Helpers.expect(string_calls[1]).to_be("silent! echo 'no double'")
  end)

  -- 4. vim.cmd restored after config completes
  Helpers.it("restores vim.cmd after config completes", function()
    clear_calls()
    local cmd_before = vim.cmd
    packard.setup({
      self_management = false,
      plugins = {
        {
          "user/restore",
          config = function()
            vim.cmd("echo 'run'")
          end,
        },
      },
    })
    local cmd_after = vim.cmd
    Helpers.expect(cmd_after).to_be(cmd_before)
  end)

  -- 5. vim.cmd restored even when config throws
  Helpers.it("restores vim.cmd even when config throws", function()
    clear_calls()
    local cmd_before = vim.cmd
    local ok, err = pcall(packard.setup, {
      self_management = false,
      plugins = {
        {
          "user/throws",
          config = function()
            vim.cmd("echo 'before error'")
            error("plugin config failed")
          end,
        },
      },
    })
    -- setup should have failed
    Helpers.expect(ok).to_be(false)
    -- vim.cmd should still be restored
    local cmd_after = vim.cmd
    Helpers.expect(cmd_after).to_be(cmd_before)
  end)

  -- 6. vim.cmd sub-commands preserved inside config
  Helpers.it("preserves vim.cmd sub-commands like packadd", function()
    clear_calls()
    local packadd_type = nil
    packard.setup({
      self_management = false,
      plugins = {
        {
          "user/subcmd",
          config = function()
            packadd_type = type(vim.cmd.packadd)
          end,
        },
      },
    })
    Helpers.expect(packadd_type).to_be("function")
  end)

  -- Restore
  packard._bootstrap = original_bootstrap
  vim.cmd = original_cmd
end)
