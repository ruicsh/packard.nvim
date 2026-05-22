# Contributing to packard.nvim

Thank you for your interest in contributing to `packard.nvim`! This document provides a brief overview of the architecture and instructions for development.

## Architecture Overview

`packard.nvim` is a security-first Neovim plugin manager built on the native `vim.pack` module (available in Neovim 0.12+). Its core philosophy is to enforce a **cooldown period** and **manual review** for all plugin updates.

### Key Components

- **`lua/packard/parser.lua`**: Parses and normalizes plugin specs (following `lazy.nvim` conventions).
- **`lua/packard/fetch.lua`**: Handles parallel `git fetch` operations to check for updates.
- **`lua/packard/cooldown.lua`**: Logic for managing discovery timestamps and eligibility.
- **`lua/packard/state.lua`**: Persistence layer for the machine-local queue, blacklist, and history.
- **`lua/packard/ui.lua`**: The dashboard UI, built on Neovim's floating window and buffer APIs.
- **`lua/packard/lockfile.lua`**: Interface for Neovim's built-in `nvim-pack-lock.json`.

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
