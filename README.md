# packard.nvim

> [!WARNING]
> **Work in Progress**: This project is currently under active development. APIs and features may change without notice. Use with caution in production environments.

A security-first Neovim plugin manager that protects against supply chain attacks by enforcing a configurable cooldown period on new commits and requiring manual user review before any plugin is updated.

## Features

- **Lazy Loading**: Deferred loading on keymaps, commands, events, or filetypes.
- **Commit Pinning**: Everything is pinned to a specific SHA.
- **Version Constraints**: Semver range support (`version = "1.*"`) — pin to latest stable tag automatically.
- **Cooldown Queue**: New commits are held for a configurable period (default 30 days) before they can be applied.
- **Manual Review**: Approve or reject updates after inspecting changes.
- **AI Review Engine**: Optional inline AI analysis of diffs to identify security risks and breaking changes.
- **Dependency Resolution**: Automatic recursive dependency injection and topological sorting for plugin load order.
- **Parallel Fetch**: Non-blocking `git fetch` for update checking.
- **Dashboard**: `lazy.nvim`-style UI for managing plugins with real-time status.
- **Built on `vim.pack`**: Leverages Neovim 0.12+ native plugin management.
- **Zero External Dependencies**: Self-contained and minimal.

## Requirements

- Neovim **0.12.0** or later.
- `git` and `curl` installed and in your PATH.

## Installation

Add this to your `init.lua` before calling `setup`:

```lua
-- Bootstrap packard.nvim
local packpath = vim.fn.stdpath("data") .. "/site/pack/packard/start/packard.nvim"
if vim.fn.isdirectory(packpath) == 0 then
  vim.fn.system({ "git", "clone", "--filter=blob:none", "https://github.com/ruicsh/packard.nvim.git", packpath })
end
vim.opt.rtp:prepend(packpath)

require("packard").setup({
  defaults = {
    minimum_release_age = 30, -- global default in days
  },
  plugins = {
    "neovim/nvim-lspconfig",
    { "tpope/vim-fugitive", minimum_release_age = 7, cmd = "Git" },
    { "Saghen/blink.cmp", version = "1.*", event = "InsertEnter", dependencies = { "rafamadriz/friendly-snippets" } },
    { "folke/snacks.nvim", keys = { { "<leader><space>", function() Snacks.picker.smart() end, desc = "Files" } } },
    -- ... more plugins
  },
  -- Optional settings:
  -- notifications = true,      -- Notify on startup if plugins are ready for review
  -- self_management = true,    -- Automatically include packard.nvim in the plugin list
  ai_review = {
    provider = "openai", -- "openai", "anthropic", "ollama", or "custom"
    model = "gpt-4o",
    url = "https://api.openai.com/v1/chat/completions",
    headers = {
      ["Authorization"] = "Bearer " .. (os.getenv("OPENAI_API_KEY") or ""),
    },
  },
})
```

## Lazy Loading Support

Packard supports standard `lazy.nvim`-style lazy-loading fields:

| Field | Type | Description |
|---|---|---|
| `keys` | `string\|string[]\|table\|function` | Load on keymap(s). Supports simple strings, full mapping tables, or a function that returns key specs. |
| `cmd` | `string\|string[]` | Load on command(s). |
| `event` | `string\|string[]` | Load on autocmd event(s). Supports pseudo-events like `VeryLazy` and `LazyFile`. |
| `ft` | `string\|string[]` | Load on filetype(s). |
| `lazy` | `boolean` | If `false`, load immediately on startup (default: `true`). |
| `config` | `function\|boolean` | Function called after plugin loads: `function(plugin, opts)`. Set to `true` to auto-call `require(MAIN).setup(opts or {})` — useful for zero-config plugins. If omitted but `opts` is present, Packard auto-calls `require(MAIN).setup(opts)`. |
| `main` | `string` | Override the auto-detected Lua module name used by `config` and `opts` auto-setup. Useful when the plugin's module name doesn't match the repo name. |
| `init` | `function` | Function called at **startup** before the plugin loads: `function(plugin)`. Useful for setting `vim.g.*` values that VimScript plugins check at startup. Runs for all plugins regardless of `lazy` setting. |
| `opts` | `table` or `function` | Options passed to the `config` function. If `config` is absent but `opts` is present, auto-invokes `require(MAIN).setup(opts)`. Can also be a function returning a table. |
| `build` | `function\|string\|string[]\|false` | Post-install/update build step. Supports Lua functions, `:Commands`, `*.lua` files, shell commands, and lists. Auto-detects `build.lua` / `build/init.lua`. Set to `false` to disable. |

Example:
```lua
{
  "folke/snacks.nvim",
  keys = {
    { "<leader><space>", function() Snacks.picker.smart() end, desc = "Smart Picker" },
    { "<leader>,", function() Snacks.picker.buffers() end, desc = "Buffers" },
  },
  opts = {
    picker = { enabled = true }
  },
  -- config is optional when opts is provided:
  -- Packard auto-calls require("snacks").setup(opts)
}
```

If you need custom setup logic, provide an explicit `config`:

```lua
{
  "folke/snacks.nvim",
  opts = {
    picker = { enabled = true }
  },
  config = function(plugin, opts)
    require("snacks").setup(opts)
  end
}
```

For zero-config plugins that just need `require("plugin").setup({})` called, use `config = true`:

```lua
{
  "folke/todo-comments.nvim",
  config = true,
}
```

This is equivalent to:

```lua
{
  "folke/todo-comments.nvim",
  config = function()
    require("todo-comments").setup({})
  end,
}
```

`config = true` always calls `setup()`, even without `opts`. If you also provide `opts`, they are passed to `setup(opts)`.

If the module name cannot be auto-detected (e.g., the repo name doesn't match the Lua module), use `main` to specify it explicitly:

```lua
{
  "some-org/plugin-with-unusual-name",
  main = "actual-module-name",  -- override: require("actual-module-name").setup(opts)
  opts = {
    setting = "value",
  },
}
```

`init` runs at startup before the plugin loads — useful for early `vim.g.*` setup:

```lua
{
  "vim-scripts/old-vim-plugin",
  init = function(plugin)
    vim.g.old_plugin_setting = "value"
  end,
}
```

`keys` can also be a function that returns key specs:

```lua
{
  "folke/snacks.nvim",
  keys = function()
    return {
      { "<leader><space>", function() Snacks.picker.smart() end, desc = "Smart Picker" },
      { "<leader>,",      function() Snacks.picker.buffers() end, desc = "Buffers" },
    }
  end,
}
```

When multiple specs for the same plugin are declared, trigger fields
(`keys`, `cmd`, `event`, `ft`) are merged from all specs.

## Version Support

Packard supports various ways to pin your plugins:

| Field | Example | Description |
|---|---|---|
| `version` | `"1.*"`, `"^2.0"`, `"~1.2.3"` | Semver range — resolves to latest matching git tag |
| `tag` | `"v1.9.2"` | Exact tag pin |
| `commit` | `"abc1234..."` | Exact commit SHA pin (highest priority) |
| `branch` | `"dev"` | Track a specific branch (rolling) |

**Priority:** `commit` > `tag` > `version` > `branch` > default branch HEAD.

Semver ranges follow [lazy.nvim](https://github.com/folke/lazy.nvim) conventions. Pre-release tags (e.g., `-beta`) are excluded from ranges unless the range explicitly starts with a pre-release.

## Build Support

Packard supports post-install and post-update build steps, matching lazy.nvim conventions. The `build` field is executed after a plugin is first installed and after each update.

| Type | Example | Description |
|---|---|---|
| `fun(plugin)` | `build = function(p) ... end` | Lua function called with the plugin table |
| `":Command"` | `build = ":TSUpdate"` | Neovim command executed via `vim.cmd` |
| `"*.lua"` | `build = "build.lua"` | Lua file loaded from the plugin directory |
| Shell command | `build = "make"` | Run via `vim.system()` in the plugin directory |
| List | `build = { "make", ":TSUpdate" }` | Multiple steps run sequentially |
| Auto-detect | (no `build` field) | Uses `build.lua` or `build/init.lua` if present |
| `false` | `build = false` | Explicitly skip build (even if `build.lua` exists) |

Examples:

```lua
{
  "nvim-treesitter/nvim-treesitter",
  build = ":TSUpdate",
},
{
  "nvim-telescope/telescope-fzf-native.nvim",
  build = "make",
},
{
  "some/plugin",
  build = function(plugin)
    vim.fn.system({ "make", "-C", plugin.dir })
  end,
},
{
  "another/plugin",
  build = { "make", ":TSUpdate" },
},
```

Run `:Packard build <name>` to manually rebuild a plugin, or `:Packard build` to rebuild all plugins with build steps. In the dashboard, press `B` on a plugin row to rebuild it.

## Usage

- `:Packard` - Open the dashboard.
- `:Packard check` - Check for new commits (async).
- `:Packard review` - Open dashboard to the Pending tab.
- `:Packard summary` - View history of applied updates.
- `:Packard build [name]` - Rebuild a plugin (or all plugins with build steps).
- `:Packard help` - Show dashboard keybindings.
- `:checkhealth packard` - Check plugin health and consistency.

### Dashboard Keybindings

- `i`: Switch to **Installed** tab.
- `p`: Switch to **Pending** tab.
- `s`: Switch to **Summary** (History) tab.
- `?`: Show help overlay.
- `<CR>`: Approve update (on Pending tab).
- `a`: Trigger/Toggle AI Review inline.
- `A`: Force re-run AI Review (bypass cache).
- `a`: Trigger/Toggle AI Review inline.
- `A`: Force re-run AI Review (bypass cache).
- `r`: Reject and blacklist commit (on Pending tab).
- `B`: Rebuild plugin under cursor.
- `gx`: Open forge compare URL (GitHub/GitLab/Bitbucket).
- `q` / `<Esc>`: Close dashboard.

## Security Model

1. **Discovery**: `:Packard check` fetches the latest HEAD for each plugin.
2. **Quarantine**: New commits enter a "Pending" queue with a discovery timestamp.
3. **Cooldown**: Commits are held in "In Cooldown" until `minimum_release_age` days have passed since discovery.
4. **Audit**: User reviews the "Eligible" changes (using `gx` for browser diff or `a` for AI analysis).
5. **Action**: User explicitly approves (installs) or rejects (permanently blacklists) the commit.

## AI Review Configuration

The `ai_review` table supports the following providers:

- **OpenAI**: Requires `url` and `Authorization` header.
- **Anthropic**: Requires `url` and `x-api-key` header.
- **Ollama**: Works with local endpoints (e.g., `http://localhost:11434/api/chat`).
- **Custom**: Flexible for other JSON-based APIs.

### Configuration Fields

| Field           | Description                                         | Default                       |
| --------------- | --------------------------------------------------- | ----------------------------- |
| `provider`      | `openai`, `anthropic`, `ollama`, or `custom`        | **Required**                  |
| `model`         | The model name to use                               | `gpt-4o` (varies by provider) |
| `url`           | The API endpoint                                    | Provider default              |
| `headers`       | Table of HTTP headers                               | `{}`                          |
| `diff_warn_kb`  | KB threshold to ask for confirmation before sending | `50`                          |
| `diff_error_kb` | KB threshold to block the request                   | `200`                         |

AI reviews are cached locally in `stdpath('state')/packard-ai-cache.json` to prevent redundant API calls.

If a force-push is detected
(upstream SHA changes but is not a descendant of the discovery commit), `packard` will mark it as an anomaly for extra caution.

No plugin code is updated without your explicit consent.
