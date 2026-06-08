# Contributing to packard.nvim

Thank you for your interest in contributing to `packard.nvim`! This document provides a brief overview of the architecture and instructions for development.

## Architecture Overview

`packard.nvim` is a security-first Neovim plugin manager built on the native `vim.pack` module (available in Neovim 0.12+). Its core philosophy is to enforce a **cooldown period** and **manual review** for all plugin updates.

### Key Components

- **`lua/packard/core/setup.lua`**: Entry point — validates opts, merges `specs_dir` + inline specs, filters `enabled`/`cond`, dedup & merge, self-management injection, calls parser → bootstrap → eager load → commands.
- **`lua/packard/core/bootstrap.lua`**: Registers `PackChanged` autocmd, calls `vim.pack.add()` (batch), runs builds on fresh installs, auto-resolves undeclared deps via `deps.lua`, initializes state file.
- **`lua/packard/core/check.lua`**: `:Packard check` orchestration — concurrent-safety flag, calls fetch engine, processes results into cooldown queue, prints summary.
- **`lua/packard/core/commands.lua`**: Registers `:Packard` user command with subcommands (`check`, `review`, `summary`, `clean`, `build`, `help`). Tab completion for subcommands and plugin names.
- **`lua/packard/parser/`** (3 files): Spec parsing, normalization, validation, topological sort (Kahn's algorithm), circular dependency detection, dependency normalization.
- **`lua/packard/loader.lua`**: Two responsibilities — (1) directory-based spec loading via `loadfile()` with per-level parent-first recursive walk, and (2) eager loading engine: pre-populate `package.path`, run `init()`, `packadd`/rtp-prepend, `config()`/auto-setup, register `keys` (first-wins), register `cmd`.
- **`lua/packard/colorscheme.lua`**: Loads colorscheme plugins on demand via `ColorSchemePre` autocmd — detects `colors/<name>.{lua,vim}` in plugin paths and loads the matching plugin when the user runs `:colorscheme <name>`.
- **`lua/packard/fetch/`** (2 files): Parallel `git fetch` via `vim.system()` batch-spawn-collect. Network probe, default branch resolution, force-push detection, version-tracked tag resolution.
- **`lua/packard/cooldown.lua`**: Manages discovery timestamps and eligibility. `register_commit()` with blacklist check and superseding. `check_eligibility()` via ISO 8601 timestamp parsing.
- **`lua/packard/state/`** (3 files): Machine-local state persistence (`packard-state.json`). Queue, blacklist, update log CRUD. AI cache (`packard-ai-cache.json`). Atomic writes (`.tmp` → `os.rename`), corrupt file recovery.
- **`lua/packard/ui/`** (7 files): Dashboard UI, split into focused sub-modules — `init.lua` (state + lifecycle), `renderers.lua` (tab content), `handlers.lua` (user actions), `highlights.lua` (extmarks), `expansions.lua` (inline AI + log expansions), `keymaps.lua` (keybindings), and `utils.lua` (formatters). Built on Neovim's floating window and buffer APIs. Tabs: Installed, Update, Pending, Summary, Clean, Help.
- **`lua/packard/lockfile.lua`**: Read-only interface for Neovim's built-in `nvim-pack-lock.json`. Cached reads with `invalidate()`. Supports Neovim 0.12 format (`data.plugins[name].rev`) and legacy format (`data[name].ref`).
- **`lua/packard/build.lua`**: Execute post-install/update build steps — Lua function, `:Command`, `*.lua` file, shell command, or list. Auto-detects `build.lua`/`build/init.lua`.
- **`lua/packard/ai.lua`**: AI review engine — cache check → `git diff` → threshold checks → `curl` HTTP request → response parsing → cache write. Supports OpenAI, Anthropic, Ollama, custom providers.
- **`lua/packard/url.lua`**: Forge compare URL construction for GitHub, GitLab, Bitbucket. Pure string formatting — no API calls.
- **`lua/packard/orphans.lua`**: Find orphaned directories (in `opt/` not in spec) and stale state metadata (queue/blacklist entries not in spec). Self-protection: skips `packard.nvim`.
- **`lua/packard/health.lua`**: `:checkhealth packard` reports — config, lockfile, pending queue, AI config, network, plugin directories, dependency status.

For a detailed design blueprint, see `SPEC.md`.

## Development

### Prerequisites

- Neovim **0.12.0** or later.
- `git` installed.
- `stylua` for code formatting.

### Running Tests

We use a custom test runner that leverages Neovim's headless mode. You can run all tests using the provided `Makefile`:

```bash
make test
```

Or run the script directly:

```bash
./scripts/run_tests.sh
```

To run a specific test file:

```bash
nvim --clean -u NONE -l tests/parser_spec.lua
```

### Code Style

We use `stylua` for formatting. Please ensure your code is formatted before submitting:

```bash
make format
```

You can check for formatting consistency with:

```bash
make lint
```

## Submitting Changes

1. Fork the repository.
2. Create a feature branch.
3. Add tests for any new behavior.
4. Ensure all tests pass (`make test`).
5. Format your code (`make format`).
6. Submit a Pull Request.

By contributing, you agree that your changes will be licensed under the project's **MIT License**.
