# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.1](https://github.com/ruicsh/packard.nvim/compare/v0.3.0...v0.3.1) (2026-06-10)


### Bug Fixes

* **loader:** suppress vim.cmd output during plugin config ([b4b9880](https://github.com/ruicsh/packard.nvim/commit/b4b988015d0109d6f8a46c21e845f2ea76b01242))

## [Unreleased]

### Added
- **Self-update Restart**: Approving an update for packard.nvim now prompts to restart Neovim via `:restart` (added in Neovim 0.12) so the new code takes effect immediately.

## [0.3.0] - 2026-06-08

### Added
- **Eager Loading Engine**: Replaced complex lazy-loading stubs with a robust eager-loading orchestrator. 
  Plugins are loaded in topological order, with `package.path` prepending for reliable module resolution.
- **Pinning**: Added `pin = true` field to plugin spec to permanently freeze a plugin at its current commit.
- **Diagnostics**: Added `:Packard diagnose <name>` command for interactive inspection of plugin state and module resolution.
- **Startup Notifications**: Added `notifications` option (enabled by default) to alert users if plugins are eligible for review on Neovim startup.
- **Colorscheme Autoload**: Automatically load `cond`-blocked colorscheme plugins when Neovim's `ColorSchemePre` fires (ADR-011).
- **Hardening**: Added force-push detection during update checks and improved `build = false` handling.
- **UI Highlights**: 29 custom highlight groups for full control over dashboard appearance.
- **Help Tab**: Added a sectioned help tab (`?`) with detailed keybinding documentation.
- **Tests**: Comprehensive e2e test for self-management and Windows compatibility.
- **Documentation**: Finalized vimdoc (`:help packard`) and beta-ready README.

### Changed
- Shifted architecture from lazy-loading stubs to an eager-loading model to eliminate re-entry and mode-switching race conditions.
- Standardized user-facing messages via `vim.notify()`.

### Fixed
- Cross-platform path normalization for Windows compatibility.
- Self-protection logic for `ruicsh/packard.nvim` during orphan cleanup.
- Expansion popup border bleeding and highlight group documentation.

## [0.2.0] - 2026-06-01

### Added
- **Directory Specs**: Added `specs_dir` option to recursively scan and load `.lua` spec files (parent-first, sorted).
- **Dependency Management**: Transitive dependency resolution, topological sorting, and automatic injection of undeclared dependencies.
- **Semver Support**: Full semver range support (`^`, `~`, `>=`, `*`) for version constraints, resolved via git tags.
- **Spec Fields**: Added `cond`, `enabled` (boolean or function), `init`, `main`, and `priority` support.
- **Build Engine**: Support for function, command, file, and shell build steps with auto-detection.
- **Lazy Loading (Legacy)**: Initial implementation of keymap, command, event, and filetype triggers (later replaced by eager engine).
- **Dashboard Enhancements**: Added **Clean** tab for orphan management and **Update** tab (`U`) for inline progress.
- **Commit Logs**: Added inline git log expansion (`<CR>`) with columnar rendering and abbreviated ages.
- **Orphan Management**: Automated detection and cleanup of on-disk orphans and stale metadata.

### Changed
- Renamed `plugins_dir` to `specs_dir` for clarity.
- Refactored monolithic codebase into structured subdirectories (`ui/`, `parser/`, `state/`, `core/`).

### Fixed
- Deep-merge logic for `opts` across duplicate plugin specs.
- Neovim 0.12 lockfile format compatibility (supporting `plugins` key and `rev` field).

## [0.1.0] - 2026-05-25

### Added
- **Foundation**: Core plugin spec parser, bootstrap, and `vim.pack` integration.
- **Persistence**: Machine-local state management (`packard-state.json`) and `nvim-pack-lock.json` interface.
- **Security Engine**: Parallel `git fetch` engine, cooldown queue, eligibility math, and superseding logic.
- **AI Review**: Integrated LLM change analysis with provider presets (OpenAI, Anthropic, Ollama, Custom).
- **AI Cache**: Persistent cache for AI reviews to minimize redundant API calls.
- **Dashboard**: Core UI with **Installed**, **Pending**, and **Summary** tabs.
- **URL Engine**: Forge compare URL builders for GitHub, GitLab, and Bitbucket.
- **Health Check**: Structured health report via `:checkhealth packard`.
- **Self Management**: Capability for packard.nvim to manage its own updates.

### Security
- Mandatory manual review and cooldown period for all updates.
- Commit-pinning by default for every plugin.
- Sandbox subprocess isolation for git and curl via `vim.system()`.
- HTTPS-only enforcement for remote repositories.
- Atomic state file writes via temporary files and `os.rename()`.
- Diff size thresholds (warn/error) for AI reviews to protect privacy and tokens.
