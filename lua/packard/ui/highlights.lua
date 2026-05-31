local ns = vim.api.nvim_create_namespace("packard")

return function(UI)
  function UI.setup_highlights(user_highlights)
    if user_highlights then
      UI._highlight_config = user_highlights
    end

    local defaults = {
      PackardHeader = { link = "Normal" },
      PackardH2 = { link = "Comment" },
      PackardComment = { link = "Comment" },
      PackardButton = { link = "CursorLine" },
      PackardButtonActive = { link = "Visual" },
      PackardPluginName = { link = "Normal" },
      PackardPluginNameSelected = { link = "Visual" },
      PackardRowSelected = { link = "Visual" },
      PackardCommit = { link = "Normal" },
      PackardCommitHash = { link = "Identifier" },
      PackardCommitAge = {},
      PackardStatusOk = { link = "DiagnosticOk" },
      PackardStatusWarn = { link = "DiagnosticWarn" },
      PackardStatusError = { link = "DiagnosticError" },
      PackardEligible = { link = "Normal" },
      PackardCooldown = { link = "Normal" },
      PackardKeyHint = { link = "@punctuation.special" },
      PackardDivider = { link = "Normal" },
      PackardProgressDone = { link = "Normal" },
      PackardProgressTodo = { link = "Normal" },
      PackardAIRiskLow = { link = "DiagnosticInfo" },
      PackardAIRiskMedium = { link = "DiagnosticWarn" },
      PackardAIRiskHigh = { link = "DiagnosticError" },
      PackardAIValue = {},
      PackardAIBorder = {},
    }

    local highlights = vim.tbl_deep_extend("force", defaults, UI._highlight_config or {})

    for name, opts in pairs(highlights) do
      opts.default = true
      vim.api.nvim_set_hl(0, name, opts)
    end

    -- Re-apply on colorscheme change
    local ok, autocmds = pcall(vim.api.nvim_get_autocmds, { group = "packard_ui_highlights", event = "ColorScheme" })
    if not ok or not autocmds[1] then
      vim.api.nvim_create_autocmd("ColorScheme", {
        group = vim.api.nvim_create_augroup("packard_ui_highlights", { clear = true }),
        callback = function()
          UI.setup_highlights()
        end,
      })
    end
  end

  function UI.apply_highlights(lines)
    local buf = UI.buf
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    lines = lines or vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    -- Apply header tab highlights
    if UI._tab_extmarks then
      for _, em in ipairs(UI._tab_extmarks) do
        vim.api.nvim_buf_set_extmark(buf, ns, 1, em.start_col, {
          end_col = em.end_col,
          hl_group = em.hl_group,
        })
        -- Highlight the shortcut key within the pill
        vim.api.nvim_buf_set_extmark(buf, ns, 1, em.key_start, {
          end_col = em.key_end,
          hl_group = "PackardKeyHint",
        })
      end
    end

    -- Apply progress bar highlights
    if UI._progress_info then
      local start_col = 2
      local done_bytes = UI._progress_info.done_len * 3
      local todo_bytes = UI._progress_info.todo_len * 3

      vim.api.nvim_buf_set_extmark(buf, ns, UI._progress_info.line_idx, start_col, {
        end_col = start_col + done_bytes,
        hl_group = "PackardProgressDone",
      })
      vim.api.nvim_buf_set_extmark(buf, ns, UI._progress_info.line_idx, start_col + done_bytes, {
        end_col = start_col + done_bytes + todo_bytes,
        hl_group = "PackardProgressTodo",
      })
    end

    for i, line in ipairs(lines) do
      -- Section headers (Installed (8), etc.)
      if line:match("^  %a") then
        local count_start = line:find(" %(", 3)
        if count_start then
          -- Title: bold
          vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 2, {
            end_col = count_start,
            hl_group = "PackardH2",
          })
          -- Count: comment-style
          vim.api.nvim_buf_set_extmark(buf, ns, i - 1, count_start, {
            end_col = #line,
            hl_group = "PackardComment",
          })
        else
          -- Fallback (e.g. KEYBINDINGS: in help tab)
          vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 2, {
            hl_group = "PackardH2",
          })
        end
      elseif line:match("^    AI Review") or line:match("^    Commit Log") then
        -- Expansion headers: dimmed
        vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 4, {
          end_col = #line,
          hl_group = "PackardComment",
        })
      elseif line:match("^    %s*%S") and not line:match("^    [●⚠⏳☒☐]") then
        -- Expansion content (non-plugin-row 4-space indent lines)
        local label_col = 4 -- 0-indexed byte offset of content after indent

        -- 1. Labels (Risk:, Summary:, Reasoning:)
        local labels = { "Summary:", "Risk:", "Reasoning:" }
        local found_label = false
        for _, label_text in ipairs(labels) do
          if line:match("^    " .. label_text) then
            found_label = true
            -- Label
            vim.api.nvim_buf_set_extmark(buf, ns, i - 1, label_col, {
              end_col = label_col + #label_text,
              hl_group = "PackardH2",
            })
            -- Value (skip spaces after label)
            local value_start_col = label_col + #label_text
            while value_start_col < #line and line:sub(value_start_col + 1, value_start_col + 1) == " " do
              value_start_col = value_start_col + 1
            end
            if value_start_col < #line then
              vim.api.nvim_buf_set_extmark(buf, ns, i - 1, value_start_col, {
                end_col = #line,
                hl_group = "PackardAIValue",
              })
            end
            break
          end
        end

        -- 2. No new commits
        if not found_label then
          local no_new = line:find("No new commits", 5, true)
          if no_new then
            vim.api.nvim_buf_set_extmark(buf, ns, i - 1, no_new - 1, {
              end_col = no_new - 1 + #"No new commits",
              hl_group = "PackardStatusWarn",
            })
          -- 3. Commit log line (starts with hex hash after 4-space indent)
          elseif line:match("^    %x%x%x%x%x%x%x") then
            vim.api.nvim_buf_set_extmark(buf, ns, i - 1, label_col, {
              end_col = label_col + 7,
              hl_group = "PackardCommitHash",
            })
            -- Age column: 2 spaces after hash, then right-padded age (max 3 chars)
            local age_text = line:sub(label_col + 9, label_col + 11)
            local age_display_width = vim.fn.strdisplaywidth(age_text)
            local msg_start = label_col + 9 + age_display_width + 2
            local age_end = math.min(msg_start - 2, #line)
            vim.api.nvim_buf_set_extmark(buf, ns, i - 1, label_col + 9, {
              end_col = age_end,
              hl_group = "PackardCommitAge",
            })
            if msg_start <= #line then
              vim.api.nvim_buf_set_extmark(buf, ns, i - 1, msg_start, {
                end_col = #line,
                hl_group = "PackardAIValue",
              })
            end
          -- 4. AI review in progress
          elseif line:match("AI review in progress") then
            vim.api.nvim_buf_set_extmark(buf, ns, i - 1, label_col, {
              end_col = #line,
              hl_group = "PackardStatusWarn",
            })
          -- 5. [R] Re-run button
          elseif line:find("[R] Re-run", 5, true) then
            local pos_in_line = line:find("[R] Re-run", 5, true)
            vim.api.nvim_buf_set_extmark(buf, ns, i - 1, pos_in_line - 1, {
              end_col = pos_in_line - 1 + #"[R] Re-run",
              hl_group = "PackardButton",
            })
          -- 6. [A] Re-run legacy
          elseif line:find("[A] Re-run", 5, true) then
            local pos_in_line = line:find("[A] Re-run", 5, true)
            vim.api.nvim_buf_set_extmark(buf, ns, i - 1, pos_in_line - 1, {
              end_col = pos_in_line - 1 + #"[A] Re-run",
              hl_group = "PackardButton",
            })
          -- 7. Error message line
          elseif line:match("^    Error:") then
            vim.api.nvim_buf_set_extmark(buf, ns, i - 1, label_col, {
              end_col = label_col + 6,
              hl_group = "PackardH2",
            })
            -- Error value
            local value_start = label_col + 6
            while value_start < #line and line:sub(value_start + 1, value_start + 1) == " " do
              value_start = value_start + 1
            end
            if value_start < #line then
              vim.api.nvim_buf_set_extmark(buf, ns, i - 1, value_start, {
                end_col = #line,
                hl_group = "PackardStatusWarn",
              })
            end
          -- 8. Continuation lines (wrapped text, no label, 4-space indent)
          else
            local content_start = line:find("%S", 5)
            if content_start then
              vim.api.nvim_buf_set_extmark(buf, ns, i - 1, content_start - 1, {
                end_col = #line,
                hl_group = "PackardAIValue",
              })
            end
          end
        end

        -- Risk value color overrides (only on Risk: lines)
        if found_label and line:match("^    Risk:") then
          local risk = line:match("^    Risk:%s+(%w+)")
          if risk then
            local r_start_in_line = line:find(risk, nil, true)
            if r_start_in_line then
              local hl = (risk == "high" and "PackardAIRiskHigh")
                or (risk == "medium" and "PackardAIRiskMedium")
                or "PackardAIRiskLow"
              vim.api.nvim_buf_set_extmark(buf, ns, i - 1, r_start_in_line - 1, {
                end_col = r_start_in_line - 1 + #risk,
                hl_group = hl,
                priority = 200,
              })
            end
          end
        end
      elseif line:match("^    [●⚠⏳☒☐]") then -- Plugin rows
        -- 1. Icon
        local icon_match = line:match("^    (%S+)")
        if icon_match then
          local icon_len = #icon_match
          local hl_icon = "PackardStatusOk"
          if line:match("⚠") then
            hl_icon = "PackardStatusError"
          elseif line:match("☒") or line:match("☐") then
            hl_icon = "PackardComment"
          end

          vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 4, {
            end_col = 4 + icon_len,
            hl_group = hl_icon,
          })

          -- 2. Plugin Name
          local name_start = 4 + icon_len + 1
          -- Use a pattern to find the first double-space or multiple spaces that separate name from commit
          local name_end = line:find("  ", name_start) or #line
          local owner_repo = UI.line_map[i]
          local is_selected = (owner_repo and owner_repo == UI._cursor_repo)
          local hl_name = is_selected and "PackardPluginNameSelected" or "PackardPluginName"

          -- Full-row selected background at low priority so individual element highlights override foreground
          if is_selected then
            vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
              end_col = #line,
              hl_group = "PackardRowSelected",
              priority = 50,
            })
          end

          vim.api.nvim_buf_set_extmark(buf, ns, i - 1, name_start, {
            end_col = name_end,
            hl_group = hl_name,
            priority = is_selected and 200 or 100,
          })

          -- 3. Commit (find next word)
          local commit_start = line:find("%w", name_end)
          if commit_start then
            local commit_end = line:find(" ", commit_start) or (commit_start + 7)
            vim.api.nvim_buf_set_extmark(buf, ns, i - 1, commit_start - 1, {
              end_col = commit_end,
              hl_group = "PackardCommitHash",
            })

            -- 4. Risk (if in pending tab)
            if UI.tab == "pending" then
              local risk_start = line:find("%S", commit_end)
              if risk_start then
                local risk_end = line:find(" ", risk_start)
                local risk = line:sub(risk_start, risk_end and risk_end - 1 or #line)
                local hl = "PackardAIRiskLow"
                if risk == "medium" then
                  hl = "PackardAIRiskMedium"
                elseif risk == "high" then
                  hl = "PackardAIRiskHigh"
                end
                vim.api.nvim_buf_set_extmark(buf, ns, i - 1, risk_start - 1, {
                  end_col = risk_start - 1 + #risk,
                  hl_group = hl,
                })

                -- 5. Cooldown/Eligible status
                if risk_end then
                  local status_start = line:find("%S", risk_end)
                  if status_start then
                    local status_end = line:find("  ", status_start)
                    vim.api.nvim_buf_set_extmark(buf, ns, i - 1, status_start - 1, {
                      end_col = status_end or #line,
                      hl_group = line:match("Eligible") and "PackardEligible" or "PackardCooldown",
                    })
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end
