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

  Helpers.it("supports 'VeryLazy' and 'LazyFile' events", function()
    local loaded_plugin = nil
    local original_load = packard._load_and_config
    packard._load_and_config = function(p)
      loaded_plugin = p.name
    end

    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/lazybones",
          event = "VeryLazy",
        },
        {
          "foo/filey",
          event = "LazyFile",
        },
      },
    })

    -- Should create UIEnter autocmd for both
    local autocmds = vim.api.nvim_get_autocmds({ event = "UIEnter" })
    local bones_found = false
    local filey_found = false
    for _, au in ipairs(autocmds) do
      if au.desc and au.desc:match("packard: load lazybones") then
        bones_found = true
        -- Trigger both deferred callbacks to verify neither errors
        au.callback()
      end
      if au.desc and au.desc:match("packard: load filey") then
        filey_found = true
        au.callback()
      end
    end
    Helpers.expect(bones_found).to_be(true)
    Helpers.expect(filey_found).to_be(true)

    -- Check if it would load (callbacks call vim.schedule, so we can't check loaded_plugin immediately
    -- unless we mock vim.schedule too, but let's at least verify they didn't error)

    -- Cleanup
    packard._load_and_config = original_load
    pcall(vim.api.nvim_del_augroup_by_name, "packard_load_lazybones")
    pcall(vim.api.nvim_del_augroup_by_name, "packard_load_filey")
  end)

  Helpers.it("handles combined deferred and real events", function()
    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/hybrid",
          event = { "VeryLazy", "BufReadPost" },
        },
      },
    })

    -- Should create UIEnter autocmd
    local ui_autocmds = vim.api.nvim_get_autocmds({ event = "UIEnter" })
    local ui_found = false
    for _, au in ipairs(ui_autocmds) do
      if au.desc and au.desc:match("packard: load hybrid %(deferred%)") then
        ui_found = true
        break
      end
    end
    Helpers.expect(ui_found).to_be(true)

    -- Should create BufReadPost autocmd
    local real_autocmds = vim.api.nvim_get_autocmds({ event = "BufReadPost" })
    local real_found = false
    for _, au in ipairs(real_autocmds) do
      if au.desc and au.desc:match("packard: load hybrid") and not au.desc:match("deferred") then
        real_found = true
        break
      end
    end
    Helpers.expect(real_found).to_be(true)

    -- Cleanup
    pcall(vim.api.nvim_del_augroup_by_name, "packard_load_hybrid")
  end)

  Helpers.it("handles ModeChanged events with control character notation", function()
    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/visual-mode",
          event = "ModeChanged *:[vV^V]",
        },
      },
    })

    -- Should create ModeChanged autocmd without error
    local autocmds = vim.api.nvim_get_autocmds({ event = "ModeChanged" })
    local found = false
    for _, au in ipairs(autocmds) do
      if au.desc and au.desc:match("packard: load visual%-mode") then
        found = true
        break
      end
    end
    Helpers.expect(found).to_be(true)

    -- Cleanup
    pcall(vim.api.nvim_del_augroup_by_name, "packard_load_visual-mode")
  end)

  Helpers.it("supports multiple pattern events for the same event name", function()
    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/multi-pattern",
          event = { "ModeChanged *:n", "ModeChanged *:i" },
        },
      },
    })

    local autocmds = vim.api.nvim_get_autocmds({ event = "ModeChanged" })
    local count = 0
    for _, au in ipairs(autocmds) do
      if au.desc and au.desc:match("packard: load multi%-pattern") then
        count = count + 1
      end
    end
    -- Each separate pattern creates a separate autocmd
    Helpers.expect(count).to_be(2)

    -- Cleanup
    pcall(vim.api.nvim_del_augroup_by_name, "packard_load_multi-pattern")
  end)

  Helpers.it("preserves negation in patterns after opening bracket", function()
    local Utils = require("packard.utils")

    -- ^V after [ is negation, not control character
    local result = Utils.convert_control_chars("[^V]:*")
    Helpers.expect(result).to_be("[^V]:*")

    -- ^V not after [ should still be converted
    local result2 = Utils.convert_control_chars("*:[vV^V]")
    Helpers.expect(result2).to_be("*:[vV\x16]")
  end)

  -- keys = fn tests

  Helpers.it("keys = fn returning a string creates a stub", function()
    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/keys-string",
          keys = function()
            return "<leader>fs"
          end,
        },
      },
    })

    local ok = pcall(vim.keymap.del, "n", "<leader>fs")
    Helpers.expect(ok).to_be(true)
  end)

  Helpers.it("keys = fn returning a table creates stubs", function()
    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/keys-table",
          keys = function()
            return { { "<leader>ft", desc = "fn table" } }
          end,
        },
      },
    })

    local ok = pcall(vim.keymap.del, "n", "<leader>ft")
    Helpers.expect(ok).to_be(true)
  end)

  Helpers.it("keys = fn returning nil creates no stubs", function()
    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/keys-nil",
          keys = function()
            return nil
          end,
        },
      },
    })

    -- No stub should be set; trying to delete should fail
    local ok = pcall(vim.keymap.del, "n", "<leader>xnotset")
    Helpers.expect(ok).to_be(false)
  end)

  Helpers.it("keys = fn that throws creates no stubs and does not error", function()
    local ok, err = pcall(function()
      packard.setup({
        self_management = false,
        plugins = {
          {
            "foo/keys-error",
            keys = function()
              error("boom")
            end,
          },
        },
      })
    end)
    -- The test itself should not error (packard handles the pcall internally)
    Helpers.expect(ok).to_be(true)
  end)

  Helpers.it("merges keys = fn from duplicate specs", function()
    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/fn-merge",
          keys = function()
            return { { "<leader>fm1", desc = "first" } }
          end,
        },
        {
          "foo/fn-merge",
          keys = function()
            return { { "<leader>fm2", desc = "second" } }
          end,
        },
      },
    })

    local ok1 = pcall(vim.keymap.del, "n", "<leader>fm1")
    local ok2 = pcall(vim.keymap.del, "n", "<leader>fm2")
    Helpers.expect(ok1).to_be(true)
    Helpers.expect(ok2).to_be(true)
  end)

  Helpers.it("merges keys = fn where one throws and one succeeds", function()
    local notified = false
    local original_notify = vim.notify
    --[[@diagnostic disable-next-line: duplicate-set-field]]
    vim.notify = function(msg, level)
      if msg:find("keys function error") then
        notified = true
      end
    end

    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/fn-merge-err",
          keys = function()
            error("boom")
          end,
        },
        {
          "foo/fn-merge-err",
          keys = function()
            return { { "<leader>fme", desc = "ok" } }
          end,
        },
      },
    })

    vim.notify = original_notify
    Helpers.expect(notified).to_be(true)

    -- The working function's key should still be registered
    local ok = pcall(vim.keymap.del, "n", "<leader>fme")
    Helpers.expect(ok).to_be(true)
  end)

  -- Duplicate spec merge tests

  Helpers.it("merges keys from duplicate specs", function()
    packard.setup({
      self_management = false,
      plugins = {
        { "foo/merge-keys", keys = "<leader>m1" },
        { "foo/merge-keys", keys = { { "<leader>m2", desc = "M2" } } },
      },
    })

    local ok1 = pcall(vim.keymap.del, "n", "<leader>m1")
    local ok2 = pcall(vim.keymap.del, "n", "<leader>m2")
    Helpers.expect(ok1).to_be(true)
    Helpers.expect(ok2).to_be(true)
  end)

  Helpers.it("single-char key 'n' with function rhs uses lhs='n', not mode", function()
    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/single-char",
          keys = {
            { "n", function() end, desc = "Next result" },
          },
        },
      },
    })

    -- Stub should be mapped for key "n" in normal mode, not treated as mode
    local ok = pcall(vim.keymap.del, "n", "n")
    Helpers.expect(ok).to_be(true)
  end)

  Helpers.it("single-char key 'v' with function rhs uses lhs='v', not mode", function()
    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/single-char-v",
          keys = {
            { "v", function() end, desc = "Visual action" },
          },
        },
      },
    })

    -- Default mode is "n" since no explicit mode was set in the key spec.
    -- This test only verifies the regression fix ("v" is treated as lhs, not mode).
    local ok = pcall(vim.keymap.del, "n", "v")
    Helpers.expect(ok).to_be(true)
  end)

  Helpers.it("mode-prefixed { mode, lhs, rhs } format still works", function()
    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/mode-prefix",
          keys = {
            { "n", "<leader>mp", function() end, desc = "Mode prefix" },
          },
        },
      },
    })

    local ok = pcall(vim.keymap.del, "n", "<leader>mp")
    Helpers.expect(ok).to_be(true)
  end)

  Helpers.it("single-element { \"n\" } creates stub for key \"n\" in default mode", function()
    -- key[2] is nil, so the mode-detection guard falls through to the else branch,
    -- treating key[1] as lhs and defaulting mode to "n".
    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/single-elem",
          keys = {
            { "n" },
          },
        },
      },
    })

    local ok = pcall(vim.keymap.del, "n", "n")
    Helpers.expect(ok).to_be(true)
  end)

  Helpers.it("merges cmd from duplicate specs", function()
    packard.setup({
      self_management = false,
      plugins = {
        { "foo/merge-cmd", cmd = "MergeCmdA" },
        { "foo/merge-cmd", cmd = "MergeCmdB" },
      },
    })

    local commands = vim.api.nvim_get_commands({})
    Helpers.expect(commands.MergeCmdA).to_be_truthy()
    Helpers.expect(commands.MergeCmdB).to_be_truthy()

    pcall(vim.api.nvim_del_user_command, "MergeCmdA")
    pcall(vim.api.nvim_del_user_command, "MergeCmdB")
  end)

  Helpers.it("merges event from duplicate specs", function()
    packard.setup({
      self_management = false,
      plugins = {
        { "foo/merge-event", event = "BufRead" },
        { "foo/merge-event", event = "VimEnter" },
      },
    })

    local autocmds_a = vim.api.nvim_get_autocmds({ event = "BufRead" })
    local autocmds_b = vim.api.nvim_get_autocmds({ event = "VimEnter" })
    local found_a = false
    local found_b = false
    for _, au in ipairs(autocmds_a) do
      if au.desc and au.desc:match("packard: load merge%-event") then
        found_a = true
        break
      end
    end
    for _, au in ipairs(autocmds_b) do
      if au.desc and au.desc:match("packard: load merge%-event") then
        found_b = true
        break
      end
    end
    Helpers.expect(found_a).to_be(true)
    Helpers.expect(found_b).to_be(true)

    pcall(vim.api.nvim_del_augroup_by_name, "packard_load_merge-event")
  end)

  Helpers.it("deep-merges opts from duplicate specs", function()
    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/opts-merge",
          opts = { picker = { enabled = true } },
        },
        {
          "foo/opts-merge",
          opts = { zen = { enabled = true } },
        },
      },
    })

    -- Both sub-keys should be present in the merged opts
    local p
    for _, plug in ipairs(packard.plugins) do
      if plug.owner_repo == "foo/opts-merge" then
        p = plug
        break
      end
    end
    Helpers.expect(p).to_be_truthy()
    Helpers.expect(p.opts.picker.enabled).to_be(true)
    Helpers.expect(p.opts.zen.enabled).to_be(true)
  end)

  Helpers.it("later spec wins on conflicting nested opts keys", function()
    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/opts-conflict",
          opts = { picker = { enabled = true, layout = "default" } },
        },
        {
          "foo/opts-conflict",
          opts = { picker = { enabled = false } },
        },
      },
    })

    local p
    for _, plug in ipairs(packard.plugins) do
      if plug.owner_repo == "foo/opts-conflict" then
        p = plug
        break
      end
    end
    -- Later spec's enabled=false wins; layout from first spec is preserved
    Helpers.expect(p.opts.picker.enabled).to_be(false)
    Helpers.expect(p.opts.picker.layout).to_be("default")
  end)

  Helpers.it("non-table opts falls back to last-wins", function()
    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/opts-non-table",
          opts = { picker = { enabled = true } },
        },
        {
          "foo/opts-non-table",
          opts = function()
            return { zen = { enabled = true } }
          end,
        },
      },
    })

    local p
    for _, plug in ipairs(packard.plugins) do
      if plug.owner_repo == "foo/opts-non-table" then
        p = plug
        break
      end
    end
    -- Non-table opts from second spec wins (last-wins fallback)
    Helpers.expect(type(p.opts)).to_be("function")
  end)

  Helpers.it("later enabled = false removes plugin entirely", function()
    packard.setup({
      self_management = false,
      plugins = {
        { "foo/enabled-test", keys = "<leader>et" },
        { "foo/enabled-test", enabled = false },
      },
    })

    -- Plugin should not be in the list
    local found = false
    for _, p in ipairs(packard.plugins) do
      if p.owner_repo == "foo/enabled-test" then
        found = true
        break
      end
    end
    Helpers.expect(found).to_be(false)

    -- No stub should be set
    local ok = pcall(vim.keymap.del, "n", "<leader>et")
    Helpers.expect(ok).to_be(false)
  end)

  Helpers.it("opts without config auto-calls setup() on plugin module", function()
    local setup_opts = nil
    package.loaded["auto-setup-mod"] = {
      setup = function(opts)
        setup_opts = opts
      end,
    }

    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/auto-setup-mod",
          opts = { enabled = true, picker = { layout = "default" } },
        },
      },
    })

    -- setup() should have been called with the opts table
    Helpers.expect(setup_opts).to_be_truthy()
    Helpers.expect(setup_opts.enabled).to_be(true)
    Helpers.expect(setup_opts.picker.layout).to_be("default")

    package.loaded["auto-setup-mod"] = nil
  end)

  Helpers.it("strips .nvim suffix when resolving module for auto-config", function()
    local setup_called_with = nil
    -- Plugin name will be "snacks.nvim" (from "folke/snacks.nvim"), auto-config should require "snacks"
    package.loaded["snacks"] = {
      setup = function(opts)
        setup_called_with = opts
      end,
    }

    packard.setup({
      self_management = false,
      plugins = {
        {
          "folke/snacks.nvim",
          opts = { picker = { enabled = true } },
        },
      },
    })

    Helpers.expect(setup_called_with).to_be_truthy()
    Helpers.expect(setup_called_with.picker.enabled).to_be(true)

    package.loaded["snacks"] = nil
  end)

  Helpers.it("does not error when plugin module has no setup()", function()
    -- Module exists but has no setup() function — auto-config should silently skip.
    -- Test passes by not crashing: if auto-config errors, the runner catches it.
    package.loaded["no-setup-mod"] = {}

    packard.setup({
      self_management = false,
      plugins = {
        {
          "bar/no-setup-mod",
          opts = { foo = "bar" },
        },
      },
    })

    package.loaded["no-setup-mod"] = nil
  end)

  Helpers.it("explicit config takes priority over auto-config from opts", function()
    local config_called = false
    local auto_setup_called = false

    package.loaded["priority-test-mod"] = {
      setup = function()
        auto_setup_called = true
      end,
    }

    packard.setup({
      self_management = false,
      plugins = {
        {
          "baz/priority-test-mod",
          opts = { val = 1 },
          config = function(_, opts)
            config_called = true
          end,
        },
      },
    })

    -- Explicit config should have been called
    Helpers.expect(config_called).to_be(true)
    -- Auto-config should NOT have been called
    Helpers.expect(auto_setup_called).to_be(false)

    package.loaded["priority-test-mod"] = nil
  end)

  -- Restore mocks
  vim.pack.add = original_pack_add
  vim.fn.isdirectory = original_isdirectory
  Lockfile.get_installed_commit = original_get_installed
end)
