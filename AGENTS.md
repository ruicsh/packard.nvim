# AGENTS.md — packard.nvim

Security-first Neovim plugin manager (cooldown + manual review on `vim.pack`).

## Commands

| Command       | What it does                                         |
| ------------- | ---------------------------------------------------- |
| `make test`   | Run all tests (`./scripts/run_tests.sh`)             |
| `make format` | `stylua .`                                           |
| `make lint`   | `stylua --check .` + `lua-language-server --check .` |
| `make check`  | `lua-language-server --check .` only                 |

After code changes, run `make check` to verify no new `lua-language-server` diagnostics.

**Run a single test file:**

```
nvim --clean -u NONE --cmd "set rtp+=. \| set rtp+=./lua" -l tests/parser_spec.lua
```

**Run specific files via env var:**

```
TESTS="tests/parser_spec.lua tests/state_spec.lua" make test
```

## Test quirks

- **No busted.** Uses a custom mini framework in `tests/helpers.lua` (`describe`, `it`, `expect(…).to_be(…)`).
- Tests run headless (`nvim --clean -u NONE -l <file>`). **Must** set `rtp` to include `.` and `./lua` (the `--cmd` snippet above).
- **Always mock `_bootstrap`** and `packard.git.get_default_branch` / `check_network` — test files must not touch the network or real `vim.pack`.
- The `redundant-parameter` diagnostic is suppressed inline with `--[[@diagnostic disable-next-line: redundant-parameter]]` for Neovim API calls like `vim.fn.mkdir(dir, "p")`.

## Architecture

- **`plugin/packard.lua`** — guard file only (sets `vim.g.loaded_packard`, returns). Does not load the module.
- **`lua/packard/init.lua`** — real entrypoint: `setup()`, `check()`, `_bootstrap()`, `_register_commands()`.
- Entry order: `require("packard").setup({plugins = {...}})` → parse spec → `_bootstrap` (calls `vim.pack.add()`) → register commands.
- **State file**: `stdpath('state')/packard-state.json` — machine-local, never VCS-tracked. Atomic writes (write `.tmp` → `os.rename`). Keyed by `owner/repo`.
- **Lockfile**: reads Neovim's `nvim-pack-lock.json` (read-only by packard; writes happen via `vim.pack.update()`).
- **AI cache**: separate file at `stdpath('state')/packard-ai-cache.json`.
- **All git ops** use `vim.system()` (not `vim.fn.jobstart` or `vim.uv`).
- Dashboard is **custom on native Neovim API** (`nvim_open_win`, scratch buffers) — zero external UI deps.
- Plugin path: `stdpath('data')/site/pack/core/opt/<name>` (see `lua/packard/utils.lua`).

## Key conventions

- **Formatter**: `stylua` (120 col width, 2-space indent, double quotes — see `stylua.toml`).
- **Lua LSP**: `lua-language-server` with config in `.luarc.json` (LuaJIT runtime, `$VIMRUNTIME/lua` workspace).
- **Spec format**: lazy.nvim-compatible (`"owner/repo"` or `{ "owner/repo", … }`). `opts` without `config` auto-calls `require("plugin").setup(opts)`.
- **Self-management**: packard auto-prepends itself to the plugin list unless `self_management = false`.
- **Concurrent safety**: `_is_checking` flag prevents overlapping `:Packard check` runs.
- **Spec function `require` resolution**: `setup_lazy_load` prepends each non-cond, non-local plugin's `lua/` dir to `package.path` before evaluating `keys`/`cmd`/`event`/`ft` functions. This matches lazy.nvim: `keys = function() local p = require("plugin") ... end` works without sourcing the plugin's `plugin/`, `ftdetect/`, or `colors/` files. The mutation persists for the rest of the Neovim session (same model as lazy.nvim).
- **Ignore `harper_ls` diagnostics** on Markdown files (README, AGENTS, etc.) — prose linting suggestions, not bugs or required fixes.

## Reference docs

- **`REQUIREMENTS.md`** — functional requirements, scope, constraints.
- **`SPEC.md`** — ADRs, architecture, data model, interfaces, full implementation plan.
- **`CONTRIBUTING.md`** — architecture overview, dev setup.
