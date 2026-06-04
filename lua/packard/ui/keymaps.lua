---@class packard.ui.keymaps
---Dashboard keybinding setup.
---Maps single-character keys to UI action handlers with buffer-scoped
---mappings. The `U` key triggers `packard.check()` and switches to the
---Update tab.

return function(UI)
  ---Register all dashboard keybindings on `UI.buf`.
  ---Maps navigation (j/k, I/P/S/C/?), actions (A/X/B/U/<Space>/x), and
  ---review (r/R/gx/<CR>) to their respective handlers.
  ---Key bindings are buffer-local and created with `{ silent = true }`.
  function UI.setup_keymaps()
    ---Create a handler that switches to the given tab and re-renders.
    ---@param tab_id string
    local function switch_tab(tab_id)
      return function()
        UI.tab = tab_id
        UI.expanded_row = nil
        UI.expanded_type = nil
        UI._cursor_repo = nil
        UI.render()
      end
    end

    local maps = {
      ["I"] = switch_tab("installed"),
      ["P"] = switch_tab("pending"),
      ["S"] = switch_tab("summary"),
      ["C"] = switch_tab("clean"),
      ["q"] = function()
        UI.close()
      end,
      ["<Esc>"] = function()
        UI.close()
      end,
      ["?"] = function()
        UI.tab = "help"
        UI.render()
      end,
      ["<CR>"] = function()
        UI.handle_log()
      end,
      ["<Space>"] = function()
        UI.handle_toggle_selection()
      end,
      ["x"] = function()
        UI.handle_toggle_selection()
      end,
      ["A"] = function()
        UI.handle_approve()
      end,
      ["X"] = function()
        UI.handle_reject()
      end,
      ["gx"] = function()
        UI.handle_compare()
      end,
      ["r"] = function()
        UI.handle_ai_review()
      end,
      ["R"] = function()
        UI.handle_ai_review({ force = true })
      end,
      ["B"] = function()
        UI.handle_build()
      end,
      ["U"] = function()
        local packard = require("packard")
        if packard._is_checking then
          print("packard: update check already in progress")
          return
        end
        UI.tab = "update"
        UI.expanded_row = nil
        UI.expanded_type = nil
        UI._cursor_repo = nil
        packard.check()
      end,
    }

    for key, action in pairs(maps) do
      if type(action) == "function" then
        vim.keymap.set("n", key, action, { buffer = UI.buf, silent = true })
      end
    end
  end
end
