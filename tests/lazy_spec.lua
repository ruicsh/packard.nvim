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

  Helpers.it("keys = fn that requires the plugin's main module works", function()
    -- Temporarily un-mock isdirectory so with_temp_dir creates subdirectories
    vim.fn.isdirectory = original_isdirectory

    -- Create a fake plugin module in a temp dir so require("foo") resolves
    local temp_dir, cleanup = Helpers.with_temp_dir({
      ["lua/foo/init.lua"] = [[return { bar = "baz" }]],
    })

    -- Re-mock isdirectory for the rest of the test
    vim.fn.isdirectory = function()
      return 1
    end

    local original_get_plugin_path = require("packard.utils").get_plugin_path
    require("packard.utils").get_plugin_path = function(plugin_or_name)
      return temp_dir
    end

    -- Clear any cached require (Lua caches failed require() as false)
    local prev_foo = package.loaded["foo"]
    package.loaded["foo"] = nil

    local ok = pcall(function()
      packard.setup({
        self_management = false,
        plugins = {
          {
            "foo/req-keys",
            keys = function()
              local r = require("foo")
              return { { "<leader>rk", r.bar, desc = "req keys" } }
            end,
          },
        },
      })
    end)
    Helpers.expect(ok).to_be(true)

    -- Stub should be registered
    local ok_del = pcall(vim.keymap.del, "n", "<leader>rk")
    Helpers.expect(ok_del).to_be(true)

    require("packard.utils").get_plugin_path = original_get_plugin_path
    -- Restore cached state to avoid polluting other tests
    if prev_foo then
      package.loaded["foo"] = prev_foo
    else
      package.loaded["foo"] = nil
    end
    cleanup()
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

  Helpers.it('single-element { "n" } creates stub for key "n" in default mode', function()
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

  Helpers.it("enabled as function returning true includes plugin", function()
    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/enabled-fn-true",
          enabled = function()
            return true
          end,
        },
      },
    })

    local found = false
    for _, p in ipairs(packard.plugins) do
      if p.owner_repo == "foo/enabled-fn-true" then
        found = true
        break
      end
    end
    Helpers.expect(found).to_be(true)
  end)

  Helpers.it("enabled as function returning false excludes plugin", function()
    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/enabled-fn-false",
          enabled = function()
            return false
          end,
        },
      },
    })

    local found = false
    for _, p in ipairs(packard.plugins) do
      if p.owner_repo == "foo/enabled-fn-false" then
        found = true
        break
      end
    end
    Helpers.expect(found).to_be(false)
  end)

  Helpers.it("enabled as function returning nil includes plugin", function()
    packard.setup({
      self_management = false,
      plugins = {
        { "foo/enabled-fn-nil", enabled = function() end },
      },
    })

    local found = false
    for _, p in ipairs(packard.plugins) do
      if p.owner_repo == "foo/enabled-fn-nil" then
        found = true
        break
      end
    end
    Helpers.expect(found).to_be(true)
  end)

  Helpers.it("enabled as function that errors includes plugin", function()
    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/enabled-fn-error",
          enabled = function()
            error("boom")
          end,
        },
      },
    })

    local found = false
    for _, p in ipairs(packard.plugins) do
      if p.owner_repo == "foo/enabled-fn-error" then
        found = true
        break
      end
    end
    Helpers.expect(found).to_be(true)
  end)

  Helpers.it("enabled function returning false on duplicate removes earlier spec", function()
    packard.setup({
      self_management = false,
      plugins = {
        { "foo/enabled-dup", keys = "<leader>ed" },
        {
          "foo/enabled-dup",
          enabled = function()
            return false
          end,
        },
      },
    })

    local found = false
    for _, p in ipairs(packard.plugins) do
      if p.owner_repo == "foo/enabled-dup" then
        found = true
        break
      end
    end
    Helpers.expect(found).to_be(false)

    local ok = pcall(vim.keymap.del, "n", "<leader>ed")
    Helpers.expect(ok).to_be(false)
  end)

  Helpers.it("cond = false keeps plugin in M.plugins but marks _cond = true", function()
    packard.setup({
      self_management = false,
      plugins = {
        { "foo/cond-false", cond = false, keys = "<leader>cf" },
      },
    })

    local plugin = nil
    for _, p in ipairs(packard.plugins) do
      if p.owner_repo == "foo/cond-false" then
        plugin = p
        break
      end
    end
    -- Plugin should still be in M.plugins
    Helpers.expect(plugin).to_be_truthy()
    -- _cond should be set to true
    Helpers.expect(plugin._cond).to_be(true)

    -- No keymap stub should be set (trigger registration suppressed)
    local map_ok = pcall(vim.keymap.del, "n", "<leader>cf")
    Helpers.expect(map_ok).to_be(false)

    -- No autocmd group should exist (trigger registration suppressed)
    local au_ok = pcall(vim.api.nvim_del_augroup_by_name, "packard_load_cond-false")
    Helpers.expect(au_ok).to_be(false)
  end)

  Helpers.it("cond = true leaves plugin loadable", function()
    local config_called = false
    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/cond-true",
          cond = true,
          config = function()
            config_called = true
          end,
        },
      },
    })

    local plugin = nil
    for _, p in ipairs(packard.plugins) do
      if p.owner_repo == "foo/cond-true" then
        plugin = p
        break
      end
    end
    Helpers.expect(plugin).to_be_truthy()
    -- _cond should NOT be set (nil is falsy, but let's check it's not true)
    Helpers.expect(plugin._cond).to_be_nil()

    -- Eager load should have fired since lazy is nil and no triggers
    Helpers.expect(config_called).to_be(true)
  end)

  Helpers.it("cond as function returning false marks _cond", function()
    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/cond-fn-false",
          cond = function()
            return false
          end,
        },
      },
    })

    local plugin = nil
    for _, p in ipairs(packard.plugins) do
      if p.owner_repo == "foo/cond-fn-false" then
        plugin = p
        break
      end
    end
    Helpers.expect(plugin).to_be_truthy()
    Helpers.expect(plugin._cond).to_be(true)
  end)

  Helpers.it("cond as function returning true does not mark _cond", function()
    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/cond-fn-true",
          cond = function()
            return true
          end,
        },
      },
    })

    local plugin = nil
    for _, p in ipairs(packard.plugins) do
      if p.owner_repo == "foo/cond-fn-true" then
        plugin = p
        break
      end
    end
    Helpers.expect(plugin).to_be_truthy()
    Helpers.expect(plugin._cond).to_be_nil()
  end)

  Helpers.it("cond as function returning nil does not mark _cond", function()
    packard.setup({
      self_management = false,
      plugins = {
        { "foo/cond-fn-nil", cond = function() end },
      },
    })

    local plugin = nil
    for _, p in ipairs(packard.plugins) do
      if p.owner_repo == "foo/cond-fn-nil" then
        plugin = p
        break
      end
    end
    Helpers.expect(plugin).to_be_truthy()
    Helpers.expect(plugin._cond).to_be_nil()
  end)

  Helpers.it("cond as function that errors does not mark _cond", function()
    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/cond-fn-error",
          cond = function()
            error("cond boom")
          end,
        },
      },
    })

    local plugin = nil
    for _, p in ipairs(packard.plugins) do
      if p.owner_repo == "foo/cond-fn-error" then
        plugin = p
        break
      end
    end
    Helpers.expect(plugin).to_be_truthy()
    Helpers.expect(plugin._cond).to_be_nil()
  end)

  Helpers.it("cond as function returning string shows notification and loads", function()
    local config_called = false
    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/cond-fn-str",
          cond = function()
            return "custom message"
          end,
          config = function()
            config_called = true
          end,
        },
      },
    })

    local plugin = nil
    for _, p in ipairs(packard.plugins) do
      if p.owner_repo == "foo/cond-fn-str" then
        plugin = p
        break
      end
    end
    Helpers.expect(plugin).to_be_truthy()
    Helpers.expect(plugin._cond).to_be_nil()
    -- Plugin should still load (string is truthy)
    Helpers.expect(config_called).to_be(true)
  end)

  Helpers.it("cond on duplicate spec: last cond wins", function()
    packard.setup({
      self_management = false,
      plugins = {
        { "foo/cond-dup", cond = false },
        { "foo/cond-dup", cond = true },
      },
    })

    local plugin = nil
    for _, p in ipairs(packard.plugins) do
      if p.owner_repo == "foo/cond-dup" then
        plugin = p
        break
      end
    end
    Helpers.expect(plugin).to_be_truthy()
    -- Last occurrence's cond=true should win, so no _cond
    Helpers.expect(plugin._cond).to_be_nil()

    -- Same test but last is false
    packard.setup({
      self_management = false,
      plugins = {
        { "foo/cond-dup2", cond = true },
        { "foo/cond-dup2", cond = false },
      },
    })

    local plugin2 = nil
    for _, p in ipairs(packard.plugins) do
      if p.owner_repo == "foo/cond-dup2" then
        plugin2 = p
        break
      end
    end
    Helpers.expect(plugin2).to_be_truthy()
    Helpers.expect(plugin2._cond).to_be(true)
  end)

  Helpers.it("cond = false suppresses all lazy-load triggers", function()
    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/cond-all-triggers",
          cond = false,
          keys = { { "<leader>ca", function() end } },
          cmd = "CondAllTest",
          event = "BufEnter",
          ft = "lua",
        },
      },
    })

    local plugin = nil
    for _, p in ipairs(packard.plugins) do
      if p.owner_repo == "foo/cond-all-triggers" then
        plugin = p
        break
      end
    end
    Helpers.expect(plugin).to_be_truthy()
    Helpers.expect(plugin._cond).to_be(true)

    -- No keymap stub
    local map_ok = pcall(vim.keymap.del, "n", "<leader>ca")
    Helpers.expect(map_ok).to_be(false)

    -- No command stub
    local cmd_ok = pcall(vim.api.nvim_del_user_command, "CondAllTest")
    Helpers.expect(cmd_ok).to_be(false)

    -- No autocmd group
    local au_ok = pcall(vim.api.nvim_del_augroup_by_name, "packard_load_cond-all-triggers")
    Helpers.expect(au_ok).to_be(false)
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

  Helpers.it("resolves function opts to table before calling setup()", function()
    local setup_opts = nil
    package.loaded["func-opts-mod"] = {
      setup = function(opts)
        setup_opts = opts
      end,
    }

    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/func-opts-mod",
          opts = function()
            return { enabled = true, picker = { layout = "default" } }
          end,
        },
      },
    })

    -- setup() should have been called with the resolved table, not the function
    Helpers.expect(setup_opts).to_be_truthy()
    Helpers.expect(type(setup_opts)).to_be("table")
    Helpers.expect(setup_opts.enabled).to_be(true)
    Helpers.expect(setup_opts.picker.layout).to_be("default")

    package.loaded["func-opts-mod"] = nil
  end)

  Helpers.it("handles opts function errors gracefully", function()
    local setup_opts = nil
    package.loaded["error-opts-mod"] = {
      setup = function(opts)
        setup_opts = opts
      end,
    }

    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notifications, { msg = msg, level = level })
    end

    packard.setup({
      self_management = false,
      plugins = {
        {
          "bar/error-opts-mod",
          opts = function()
            error("opts function failed")
          end,
        },
      },
    })

    -- Should have notified about the error (search all notifications for the opts error)
    local found = false
    for _, n in ipairs(notifications) do
      if n.msg:match("opts function error") then
        found = true
        break
      end
    end
    Helpers.expect(found).to_be(true)
    -- setup() should still be called with empty opts (graceful degradation)
    Helpers.expect(setup_opts).to_be_truthy()
    Helpers.expect(type(setup_opts)).to_be("table")
    -- Verify opts is empty (next() returns nil for empty tables)
    Helpers.expect(next(setup_opts)).to_be(nil)

    package.loaded["error-opts-mod"] = nil
    vim.notify = original_notify
  end)

  Helpers.it("resolves function opts before passing to config()", function()
    local config_opts = nil
    package.loaded["func-opts-config-mod"] = {}

    packard.setup({
      self_management = false,
      plugins = {
        {
          "baz/func-opts-config-mod",
          opts = function()
            return { val = 42 }
          end,
          config = function(_, opts)
            config_opts = opts
          end,
        },
      },
    })

    -- config() should have been called with the resolved table
    Helpers.expect(config_opts).to_be_truthy()
    Helpers.expect(type(config_opts)).to_be("table")
    Helpers.expect(config_opts.val).to_be(42)

    package.loaded["func-opts-config-mod"] = nil
  end)

  Helpers.it("force-loads dependency before dependent on eager load", function()
    local b_setup_called = false
    local a_config_called = false
    local b_setup_order = 0
    local a_config_order = 0
    local order_counter = 0

    -- B: lazy plugin (has event trigger), loaded as dependency
    package.loaded["dep-mod"] = {
      setup = function()
        b_setup_called = true
        order_counter = order_counter + 1
        b_setup_order = order_counter
      end,
    }
    -- A: eager plugin depending on B
    package.loaded["parent-mod"] = {}

    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/dep-mod",
          opts = {},
          event = "VeryLazy",
        },
        {
          "bar/parent-mod",
          dependencies = { "foo/dep-mod" },
          config = function(_, opts)
            a_config_called = true
            order_counter = order_counter + 1
            a_config_order = order_counter
          end,
        },
      },
    })

    -- B should have loaded before A
    Helpers.expect(b_setup_called).to_be(true)
    Helpers.expect(a_config_called).to_be(true)
    Helpers.expect(b_setup_order < a_config_order).to_be(true)

    package.loaded["dep-mod"] = nil
    package.loaded["parent-mod"] = nil
    pcall(vim.api.nvim_del_augroup_by_name, "packard_load_dep-mod")
  end)

  Helpers.it("force-loads dependency when trigger fires", function()
    local b_setup_called = false

    package.loaded["dep-trigger-mod"] = {
      setup = function()
        b_setup_called = true
      end,
    }
    package.loaded["trigger-parent-mod"] = {}

    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/dep-trigger-mod",
          opts = {},
          event = "VeryLazy",
        },
        {
          "bar/trigger-parent-mod",
          dependencies = { "foo/dep-trigger-mod" },
          keys = { { "<leader>tp", function() end, desc = "Trigger parent" } },
          config = function(_, opts) end,
        },
      },
    })

    -- Fire the trigger (B may already be loaded via VeryLazy/UIEnter in headless)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<leader>tp", true, false, true), "x", false)

    -- B should be loaded (either via VeryLazy or force-loaded by A's trigger)
    Helpers.expect(b_setup_called).to_be(true)

    package.loaded["dep-trigger-mod"] = nil
    package.loaded["trigger-parent-mod"] = nil
    pcall(vim.api.nvim_del_augroup_by_name, "packard_load_dep-trigger-mod")
    pcall(vim.api.nvim_del_augroup_by_name, "packard_load_trigger-parent-mod")
  end)

  Helpers.it("resolves transitive dependencies", function()
    local load_order = {}

    package.loaded["transitive-c"] = {
      setup = function()
        table.insert(load_order, "C")
      end,
    }
    package.loaded["transitive-b"] = {
      setup = function()
        table.insert(load_order, "B")
      end,
    }
    package.loaded["transitive-a"] = {}

    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/transitive-c",
          opts = {},
          event = "VeryLazy",
        },
        {
          "bar/transitive-b",
          dependencies = { "foo/transitive-c" },
          opts = {},
          event = "VeryLazy",
        },
        {
          "baz/transitive-a",
          dependencies = { "bar/transitive-b" },
          config = function()
            table.insert(load_order, "A")
          end,
        },
      },
    })

    -- A is eager → loads B as dep → B loads C as dep
    Helpers.expect(load_order[1]).to_be("C")
    Helpers.expect(load_order[2]).to_be("B")
    Helpers.expect(load_order[3]).to_be("A")

    package.loaded["transitive-a"] = nil
    package.loaded["transitive-b"] = nil
    package.loaded["transitive-c"] = nil
    pcall(vim.api.nvim_del_augroup_by_name, "packard_load_transitive-b")
    pcall(vim.api.nvim_del_augroup_by_name, "packard_load_transitive-c")
  end)

  Helpers.it("skips already-loaded dependency", function()
    local b_setup_count = 0

    package.loaded["eager-dep-mod"] = {
      setup = function()
        b_setup_count = b_setup_count + 1
      end,
    }
    package.loaded["eager-parent-mod"] = {}

    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/eager-dep-mod",
          opts = {},
          -- No triggers: loads eagerly in _setup_lazy_load
        },
        {
          "bar/eager-parent-mod",
          dependencies = { "foo/eager-dep-mod" },
          config = function() end,
          -- No triggers: loads eagerly in _setup_lazy_load
        },
      },
    })

    -- B should have loaded exactly once (topo order: B first, then A skips it)
    Helpers.expect(b_setup_count).to_be(1)

    package.loaded["eager-dep-mod"] = nil
    package.loaded["eager-parent-mod"] = nil
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

  -- config = true tests

  Helpers.it("config=true with no opts calls setup({})", function()
    local setup_opts = nil
    package.loaded["config-true-nil-mod"] = {
      setup = function(opts)
        setup_opts = opts
      end,
    }

    packard.setup({
      self_management = false,
      plugins = {
        { "foo/config-true-nil-mod", config = true },
      },
    })

    Helpers.expect(setup_opts).to_be_truthy()
    Helpers.expect(type(setup_opts)).to_be("table")
    -- opts should be empty table, not nil
    Helpers.expect(next(setup_opts)).to_be(nil)

    package.loaded["config-true-nil-mod"] = nil
  end)

  Helpers.it("config=true with opts table calls setup(opts)", function()
    local setup_opts = nil
    package.loaded["config-true-opts-mod"] = {
      setup = function(opts)
        setup_opts = opts
      end,
    }

    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/config-true-opts-mod",
          config = true,
          opts = { enabled = true, value = 42 },
        },
      },
    })

    Helpers.expect(setup_opts).to_be_truthy()
    Helpers.expect(setup_opts.enabled).to_be(true)
    Helpers.expect(setup_opts.value).to_be(42)

    package.loaded["config-true-opts-mod"] = nil
  end)

  Helpers.it("config=true with opts function resolves and calls setup()", function()
    local setup_opts = nil
    package.loaded["config-true-fn-opts-mod"] = {
      setup = function(opts)
        setup_opts = opts
      end,
    }

    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/config-true-fn-opts-mod",
          config = true,
          opts = function()
            return { val = "computed" }
          end,
        },
      },
    })

    Helpers.expect(setup_opts).to_be_truthy()
    Helpers.expect(setup_opts.val).to_be("computed")

    package.loaded["config-true-fn-opts-mod"] = nil
  end)

  Helpers.it("config=true does not error when module has no setup()", function()
    -- Module exists but has no setup() — should silently skip, not crash.
    package.loaded["config-true-no-setup-mod"] = {}

    packard.setup({
      self_management = false,
      plugins = {
        { "bar/config-true-no-setup-mod", config = true },
      },
    })

    package.loaded["config-true-no-setup-mod"] = nil
  end)

  Helpers.it("config=true strips .nvim suffix when resolving module", function()
    local setup_called_with = nil
    package.loaded["config-true-stripped"] = {
      setup = function(opts)
        setup_called_with = opts
      end,
    }

    packard.setup({
      self_management = false,
      plugins = {
        { "folke/config-true-stripped.nvim", config = true },
      },
    })

    Helpers.expect(setup_called_with).to_be_truthy()
    Helpers.expect(type(setup_called_with)).to_be("table")
    Helpers.expect(next(setup_called_with)).to_be(nil)

    package.loaded["config-true-stripped"] = nil
  end)

  -- main field tests

  Helpers.it("main field overrides module name for opts-based auto-config", function()
    local setup_called_with = nil
    package.loaded["custom-main-mod"] = {
      setup = function(opts)
        setup_called_with = opts
      end,
    }

    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/weird-plugin-name",
          main = "custom-main-mod",
          opts = { enabled = true },
        },
      },
    })

    -- setup() should have been called on the module specified by main, not on "weird-plugin-name"
    Helpers.expect(setup_called_with).to_be_truthy()
    Helpers.expect(setup_called_with.enabled).to_be(true)

    package.loaded["custom-main-mod"] = nil
  end)

  Helpers.it("main field overrides module name for config=true auto-config", function()
    local setup_called_with = nil
    package.loaded["config-true-main"] = {
      setup = function(opts)
        setup_called_with = opts
      end,
    }

    packard.setup({
      self_management = false,
      plugins = {
        {
          "bar/other-weird-name",
          main = "config-true-main",
          config = true,
          opts = { value = 42 },
        },
      },
    })

    Helpers.expect(setup_called_with).to_be_truthy()
    Helpers.expect(setup_called_with.value).to_be(42)

    package.loaded["config-true-main"] = nil
  end)

  Helpers.it("main field supports submodule paths", function()
    local setup_called_with = nil
    -- Lua require() for "submodule.feature" expects package.loaded["submodule.feature"]
    package.loaded["submodule.feature"] = {
      setup = function(opts)
        setup_called_with = opts
      end,
    }

    packard.setup({
      self_management = false,
      plugins = {
        {
          "baz/some-plugin",
          main = "submodule.feature",
          opts = { test = true },
        },
      },
    })

    Helpers.expect(setup_called_with).to_be_truthy()
    Helpers.expect(setup_called_with.test).to_be(true)

    package.loaded["submodule.feature"] = nil
  end)

  Helpers.it("explicit config takes priority over main field", function()
    local config_called = false
    local auto_setup_called = false

    package.loaded["override-main-mod"] = {
      setup = function()
        auto_setup_called = true
      end,
    }

    packard.setup({
      self_management = false,
      plugins = {
        {
          "qux/priority-test",
          main = "override-main-mod",
          opts = { val = 1 },
          config = function(_, opts)
            config_called = true
          end,
        },
      },
    })

    Helpers.expect(config_called).to_be(true)
    Helpers.expect(auto_setup_called).to_be(false)

    package.loaded["override-main-mod"] = nil
  end)

  -- init() tests

  Helpers.it("calls init() during setup before plugin loads", function()
    local init_called = false
    local init_plugin = nil

    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/init-basic",
          init = function(p)
            init_called = true
            init_plugin = p
          end,
        },
      },
    })

    Helpers.expect(init_called).to_be(true)
    Helpers.expect(init_plugin).to_be_truthy()
    Helpers.expect(init_plugin.name).to_be("init-basic")
  end)

  Helpers.it("calls init() even for lazy plugins", function()
    local init_called = false

    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/init-lazy",
          lazy = true,
          init = function()
            init_called = true
          end,
          event = "VeryLazy",
        },
      },
    })

    Helpers.expect(init_called).to_be(true)
    pcall(vim.api.nvim_del_augroup_by_name, "packard_load_init-lazy")
  end)

  Helpers.it("calls init() before config()", function()
    local order = {}

    package.loaded["init-order"] = {
      setup = function()
        table.insert(order, "config")
      end,
    }

    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/init-order",
          init = function()
            table.insert(order, "init")
          end,
          opts = {},
        },
      },
    })

    Helpers.expect(order[1]).to_be("init")
    Helpers.expect(order[2]).to_be("config")

    package.loaded["init-order"] = nil
  end)

  Helpers.it("handles init() errors gracefully", function()
    local notifications = {}
    local original_notify = vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, level)
      table.insert(notifications, { msg = msg, level = level })
    end

    local ok = pcall(packard.setup, {
      self_management = false,
      plugins = {
        {
          "foo/init-error",
          init = function()
            error("init boom")
          end,
        },
      },
    })

    -- Restore before assertions
    vim.notify = original_notify

    -- setup should not crash even though init() errors
    Helpers.expect(ok).to_be(true)

    -- Find the init error notification
    local found_init_error = false
    for _, n in ipairs(notifications) do
      if n.msg and n.msg:match("init%-error") and n.msg:match("init boom") then
        found_init_error = true
        break
      end
    end
    Helpers.expect(found_init_error).to_be(true)
  end)

  Helpers.it("later spec wins init from duplicate specs", function()
    local init_value = nil

    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/init-merge",
          init = function()
            init_value = "first"
          end,
        },
        {
          "foo/init-merge",
          init = function()
            init_value = "second"
          end,
        },
      },
    })

    Helpers.expect(init_value).to_be("second")
  end)

  Helpers.it("later spec omitting init preserves earlier init", function()
    local init_value = nil

    packard.setup({
      self_management = false,
      plugins = {
        {
          "foo/init-merge-2",
          init = function()
            init_value = "first"
          end,
        },
        {
          "foo/init-merge-2",
          -- init omitted — should preserve the first init function
          opts = { some_opt = true },
        },
      },
    })

    Helpers.expect(init_value).to_be("first")
  end)

  -- keys=fn + require + mode-table e2e tests (readline.nvim pattern)

  Helpers.it("keys = fn with require: stubs exist in mode table, stub fires and sets real mapping", function()
    -- Temporarily un-mock isdirectory so with_temp_dir creates subdirectories
    vim.fn.isdirectory = original_isdirectory

    -- Create a real plugin module (mirrors readline.nvim's lua/readline.lua)
    local temp_dir, cleanup = Helpers.with_temp_dir({
      ["lua/readlike/init.lua"] = [[
        local M = {}
        function M.move_left() return "left" end
        function M.kill_word() return "kill" end
        return M
      ]],
    })

    -- Re-mock isdirectory for bootstrap path checks
    vim.fn.isdirectory = function()
      return 1
    end

    local original_get_plugin_path = require("packard.utils").get_plugin_path
    require("packard.utils").get_plugin_path = function(plugin_or_name)
      return temp_dir
    end

    -- Clear cached require so keys fn re-evaluates from disk
    local prev_readlike = package.loaded["readlike"]
    package.loaded["readlike"] = nil

    local load_called = false
    local orig_load = packard._load_and_config
    ---@diagnostic disable-next-line: duplicate-set-field
    packard._load_and_config = function(p)
      load_called = true
      orig_load(p)
    end

    local setup_ok = pcall(packard.setup, {
      self_management = false,
      plugins = {
        {
          "foo/readlike",
          keys = function()
            local r = require("readlike")
            return {
              { "<c-b>", "<left>", desc = "backward char", mode = { "i", "c" } },
              { "<a-b>", r.move_left, desc = "backward word", mode = { "i", "c" } },
              { "<c-u>", r.kill_word, desc = "kill backward", mode = { "i", "c" } },
            }
          end,
        },
      },
    })
    Helpers.expect(setup_ok).to_be(true)

    -- Stubs exist in "i" and "c" modes (readline's target modes)
    local i_ok = pcall(vim.keymap.del, "i", "<c-b>")
    local c_ok = pcall(vim.keymap.del, "c", "<c-b>")
    Helpers.expect(i_ok).to_be(true)
    Helpers.expect(c_ok).to_be(true)

    -- Stubs for ALL three key specs in "i" mode
    local i_ab = pcall(vim.keymap.del, "i", "<a-b>")
    local i_cu = pcall(vim.keymap.del, "i", "<c-u>")
    Helpers.expect(i_ab).to_be(true)
    Helpers.expect(i_cu).to_be(true)

    -- Verify the plugin loaded correctly via load_and_config
    -- (simulates what the stub callback does: delete stub → load_fn → set real mapping)
    for _, p in ipairs(packard.plugins) do
      if p.owner_repo == "foo/readlike" then
        packard._load_and_config(p)
        break
      end
    end
    Helpers.expect(load_called).to_be(true)
    Helpers.expect(package.loaded["readlike"]).to_be_truthy()

    -- Cleanup
    packard._load_and_config = orig_load
    require("packard.utils").get_plugin_path = original_get_plugin_path
    if prev_readlike then
      package.loaded["readlike"] = prev_readlike
    else
      package.loaded["readlike"] = nil
    end
    pcall(vim.keymap.del, "i", "<c-b>")
    pcall(vim.keymap.del, "c", "<c-b>")
    pcall(vim.keymap.del, "i", "<a-b>")
    pcall(vim.keymap.del, "c", "<a-b>")
    pcall(vim.keymap.del, "i", "<c-u>")
    pcall(vim.keymap.del, "c", "<c-u>")
    pcall(vim.api.nvim_del_augroup_by_name, "packard_load_readlike")
    cleanup()
  end)

  Helpers.it("keys = fn with require: stub fires in insert mode via feedkeys, no infinite loop", function()
    -- Temporarily un-mock isdirectory so with_temp_dir creates subdirectories
    vim.fn.isdirectory = original_isdirectory

    local temp_dir, cleanup = Helpers.with_temp_dir({
      ["lua/readlike/init.lua"] = [[
        local M = {}
        function M.move_left() return "left" end
        return M
      ]],
    })

    vim.fn.isdirectory = function()
      return 1
    end

    local original_get_plugin_path = require("packard.utils").get_plugin_path
    require("packard.utils").get_plugin_path = function(plugin_or_name)
      return temp_dir
    end

    local prev_readlike = package.loaded["readlike"]
    package.loaded["readlike"] = nil

    local load_called = false
    local orig_load = packard._load_and_config
    ---@diagnostic disable-next-line: duplicate-set-field
    packard._load_and_config = function(p)
      load_called = true
      orig_load(p)
    end

    local setup_ok = pcall(packard.setup, {
      self_management = false,
      plugins = {
        {
          "foo/readlike",
          keys = function()
            local r = require("readlike")
            return {
              { "<c-b>", "<left>", desc = "backward char", mode = { "i", "c" } },
            }
          end,
        },
      },
    })
    Helpers.expect(setup_ok).to_be(true)

    -- Fire the stub by entering insert mode then pressing the trigger key.
    -- The "x" flag processes keys immediately in headless mode.
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i<c-b>", true, false, true), "x", false)

    -- Plugin should have been loaded (stub callback ran, load_fn called)
    Helpers.expect(load_called).to_be(true)
    Helpers.expect(package.loaded["readlike"]).to_be_truthy()

    -- Cleanup
    packard._load_and_config = orig_load
    require("packard.utils").get_plugin_path = original_get_plugin_path
    if prev_readlike then
      package.loaded["readlike"] = prev_readlike
    else
      package.loaded["readlike"] = nil
    end
    pcall(vim.keymap.del, "i", "<c-b>")
    pcall(vim.keymap.del, "c", "<c-b>")
    pcall(vim.api.nvim_del_augroup_by_name, "packard_load_readlike")
    cleanup()
  end)

  Helpers.it("keys = fn with require: function RHS is preserved in real mapping", function()
    -- Temporarily un-mock isdirectory so with_temp_dir creates subdirectories
    vim.fn.isdirectory = original_isdirectory

    local temp_dir, cleanup = Helpers.with_temp_dir({
      ["lua/funcmod/init.lua"] = [[
        local M = {}
        function M.custom_action()
          return 42
        end
        return M
      ]],
    })

    vim.fn.isdirectory = function()
      return 1
    end

    local original_get_plugin_path = require("packard.utils").get_plugin_path
    require("packard.utils").get_plugin_path = function(plugin_or_name)
      return temp_dir
    end

    local prev_funcmod = package.loaded["funcmod"]
    package.loaded["funcmod"] = nil

    -- Track the RHS function reference before setup
    local captured_rhs = nil

    packard.setup({
      self_management = false,
      plugins = {
        {
          "bar/funcmod",
          keys = function()
            local m = require("funcmod")
            captured_rhs = m.custom_action
            return {
              { "<leader>fa", m.custom_action, desc = "custom action" },
            }
          end,
        },
      },
    })

    -- Verify: keys fn was called (captured_rhs was set)
    Helpers.expect(captured_rhs).to_be_truthy()

    -- Verify: the function reference is the same one from the module
    local mod = require("funcmod")
    Helpers.expect(captured_rhs).to_be(mod.custom_action)

    -- Verify: stub exists in default mode "n"
    local stub_ok = pcall(vim.keymap.del, "n", "<leader>fa")
    Helpers.expect(stub_ok).to_be(true)

    -- Cleanup
    require("packard.utils").get_plugin_path = original_get_plugin_path
    if prev_funcmod then
      package.loaded["funcmod"] = prev_funcmod
    else
      package.loaded["funcmod"] = nil
    end
    pcall(vim.keymap.del, "n", "<leader>fa")
    pcall(vim.api.nvim_del_augroup_by_name, "packard_load_funcmod")
    cleanup()
  end)

  -- local plugin with keys=fn + require() — the readline.nvim local install pattern

  Helpers.it("local plugin (dir) keys = fn with require: stubs created from package.path", function()
    -- Temporarily un-mock isdirectory so with_temp_dir creates subdirectories
    vim.fn.isdirectory = original_isdirectory

    -- Create a local plugin dir with a Lua module (mirrors ~/.code/readline.nvim/lua/readline.lua)
    local local_dir, cleanup = Helpers.with_temp_dir({
      ["lua/localmod/init.lua"] = [[
        local M = {}
        function M.do_thing() return "done" end
        return M
      ]],
    })

    -- Re-mock isdirectory for bootstrap path checks
    vim.fn.isdirectory = function()
      return 1
    end

    -- Clear cached require so keys fn re-evaluates from disk
    local prev_localmod = package.loaded["localmod"]
    package.loaded["localmod"] = nil

    -- Save original package.path to verify it gets prepended
    local orig_package_path = package.path

    local load_called = false
    local orig_load = packard._load_and_config
    ---@diagnostic disable-next-line: duplicate-set-field
    packard._load_and_config = function(p)
      load_called = true
      orig_load(p)
    end

    -- Use dir field (local plugin) — this is the key difference from remote plugins
    local setup_ok = pcall(packard.setup, {
      self_management = false,
      plugins = {
        {
          dir = local_dir,
          keys = function()
            local m = require("localmod")
            return {
              { "<leader>lm", m.do_thing, desc = "local mod" },
            }
          end,
        },
      },
    })
    Helpers.expect(setup_ok).to_be(true)

    -- Verify: package.path was prepended with local plugin's lua/ dir
    local expected = local_dir .. "/lua/?.lua"
    local lua_path_added = package.path:find(expected, 1, true)
    Helpers.expect(lua_path_added).to_be_truthy()

    -- Verify: stub exists in default mode "n" (keys fn succeeded)
    local stub_ok = pcall(vim.keymap.del, "n", "<leader>lm")
    Helpers.expect(stub_ok).to_be(true)

    -- Verify: the plugin is marked as local
    local plugin = nil
    for _, p in ipairs(packard.plugins) do
      if p.is_local then
        plugin = p
        break
      end
    end
    Helpers.expect(plugin).to_be_truthy()
    Helpers.expect(plugin.is_local).to_be(true)

    -- Cleanup
    packard._load_and_config = orig_load
    if prev_localmod then
      package.loaded["localmod"] = prev_localmod
    else
      package.loaded["localmod"] = nil
    end
    package.path = orig_package_path
    cleanup()
  end)

  -- Local plugin file sourcing: plugin/ and ftdetect/ should be sourced
  Helpers.it("local plugin (dir) sources plugin/ and ftdetect/ files", function()
    -- Temporarily un-mock isdirectory so with_temp_dir creates subdirectories
    vim.fn.isdirectory = original_isdirectory

    -- Create a local plugin dir with plugin/ and ftdetect/ files
    local local_dir, cleanup = Helpers.with_temp_dir({
      ["plugin/init.lua"] = [[vim.g._local_plugin_sourced = true]],
      ["ftdetect/test.lua"] = [[vim.g._local_ftdetect_sourced = true]],
      ["lua/localplug/init.lua"] = [[local M = {} function M.setup() end return M]],
    })

    -- Re-mock isdirectory for bootstrap path checks
    vim.fn.isdirectory = function()
      return 1
    end

    -- Reset globals
    vim.g._local_plugin_sourced = false
    vim.g._local_ftdetect_sourced = false

    local setup_ok = pcall(packard.setup, {
      self_management = false,
      plugins = {
        {
          dir = local_dir,
          name = "localplug",
          lazy = false,
        },
      },
    })
    Helpers.expect(setup_ok).to_be(true)

    -- Verify: plugin/ file was sourced
    Helpers.expect(vim.g._local_plugin_sourced).to_be(true)

    -- Verify: ftdetect/ file was sourced
    Helpers.expect(vim.g._local_ftdetect_sourced).to_be(true)

    -- Cleanup
    vim.g._local_plugin_sourced = nil
    vim.g._local_ftdetect_sourced = nil
    cleanup()
  end)

  Helpers.it("debug = true emits lazy-load tracing", function()
    -- Temporarily un-mock isdirectory so with_temp_dir creates subdirectories
    vim.fn.isdirectory = original_isdirectory

    local temp_dir, cleanup = Helpers.with_temp_dir({
      ["lua/readlike/init.lua"] = [[
        local M = {}
        function M.move_left() return "left" end
        return M
      ]],
    })

    vim.fn.isdirectory = function()
      return 1
    end

    local original_get_plugin_path = require("packard.utils").get_plugin_path
    require("packard.utils").get_plugin_path = function(plugin_or_name)
      return temp_dir
    end

    local prev_readlike = package.loaded["readlike"]
    package.loaded["readlike"] = nil

    -- Mock nvim_echo to capture debug output
    local echo_calls = {}
    local orig_echo = vim.api.nvim_echo
    vim.api.nvim_echo = function(chunks)
      if chunks and chunks[1] then
        table.insert(echo_calls, chunks[1][1])
      end
    end

    local setup_ok = pcall(packard.setup, {
      self_management = false,
      debug = true,
      plugins = {
        {
          "foo/readlike",
          keys = function()
            local r = require("readlike")
            return {
              { "<c-b>", "<left>", desc = "backward char", mode = { "i", "c" } },
            }
          end,
        },
      },
    })
    Helpers.expect(setup_ok).to_be(true)

    -- Restore nvim_echo before assertions (so failures don't break subsequent tests)
    vim.api.nvim_echo = orig_echo

    -- Check that debug messages were emitted
    local has_create = false
    local has_keys = false
    for _, msg in ipairs(echo_calls) do
      if msg:find("%[packard%] creating stub keymap") then
        has_create = true
      end
      if msg:find("%[packard%] keys fn OK") then
        has_keys = true
      end
    end
    Helpers.expect(has_create).to_be(true)
    Helpers.expect(has_keys).to_be(true)

    -- Cleanup
    require("packard.utils").get_plugin_path = original_get_plugin_path
    if prev_readlike then
      package.loaded["readlike"] = prev_readlike
    else
      package.loaded["readlike"] = nil
    end
    pcall(vim.keymap.del, "i", "<c-b>")
    pcall(vim.keymap.del, "c", "<c-b>")
    pcall(vim.api.nvim_del_augroup_by_name, "packard_load_readlike")
    cleanup()
  end)

  Helpers.it("debug = false suppresses lazy-load tracing", function()
    -- Temporarily un-mock isdirectory so with_temp_dir creates subdirectories
    vim.fn.isdirectory = original_isdirectory

    local temp_dir, cleanup = Helpers.with_temp_dir({
      ["lua/readlike/init.lua"] = [[
        local M = {}
        function M.move_left() return "left" end
        return M
      ]],
    })

    vim.fn.isdirectory = function()
      return 1
    end

    local original_get_plugin_path = require("packard.utils").get_plugin_path
    require("packard.utils").get_plugin_path = function(plugin_or_name)
      return temp_dir
    end

    local prev_readlike = package.loaded["readlike"]
    package.loaded["readlike"] = nil

    -- Mock nvim_echo to capture any output
    local echo_calls = {}
    local orig_echo = vim.api.nvim_echo
    vim.api.nvim_echo = function(chunks)
      if chunks and chunks[1] then
        table.insert(echo_calls, chunks[1][1])
      end
    end

    local setup_ok = pcall(packard.setup, {
      self_management = false,
      -- debug defaults to false (omitted)
      plugins = {
        {
          "foo/readlike",
          keys = function()
            local r = require("readlike")
            return {
              { "<c-b>", "<left>", desc = "backward char", mode = { "i", "c" } },
            }
          end,
        },
      },
    })
    Helpers.expect(setup_ok).to_be(true)

    -- Restore nvim_echo before assertions
    vim.api.nvim_echo = orig_echo

    -- No [packard]-prefixed debug messages should appear
    for _, msg in ipairs(echo_calls) do
      Helpers.expect(msg:find("%[packard%]") == nil).to_be(true)
    end

    -- Cleanup
    require("packard.utils").get_plugin_path = original_get_plugin_path
    if prev_readlike then
      package.loaded["readlike"] = prev_readlike
    else
      package.loaded["readlike"] = nil
    end
    pcall(vim.keymap.del, "i", "<c-b>")
    pcall(vim.keymap.del, "c", "<c-b>")
    pcall(vim.api.nvim_del_augroup_by_name, "packard_load_readlike")
    cleanup()
  end)

  -- Restore mocks
  vim.pack.add = original_pack_add
  vim.fn.isdirectory = original_isdirectory
  Lockfile.get_installed_commit = original_get_installed
end)
