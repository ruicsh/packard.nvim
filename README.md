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
| `keys` | `string\|string[]\|table` | Load on keymap(s). Supports simple strings or full mapping tables. |
| `cmd` | `string\|string[]` | Load on command(s). |
| `event` | `string\|string[]` | Load on autocmd event(s). Supports pseudo-events like `VeryLazy` and `LazyFile`. |
| `ft` | `string\|string[]` | Load on filetype(s). |
| `lazy` | `boolean` | If `false`, load immediately on startup (default: `true`). |
| `config` | `function` | Function called after plugin loads: `function(plugin, opts)`. |
| `opts` | `table` | Options passed to the `config` function. |

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
  config = function(plugin, opts)
    require("snacks").setup(opts)
  end
}
```

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

## Usage

- `:Packard` - Open the dashboard.
- `:Packard check` - Check for new commits (async).
- `:Packard review` - Open dashboard to the Pending tab.
- `:Packard summary` - View history of applied updates.
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
- `r`: Reject and blacklist commit (on Pending tab).
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
