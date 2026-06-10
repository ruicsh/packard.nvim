-- tests/run_all.lua
-- Runs all tests in a single Neovim process.
-- Used by CI (especially on Windows) where bash loops are less convenient.

-- Snapshot commonly-mocked globals before a test file and restore them
-- after (even on failure) to prevent mock leakage between files.
-- This list covers all globals that *_spec.lua files currently mock.
local function snapshot_globals()
  return {
    io_open = io.open,
    os_rename = os.rename,
    os_remove = os.remove,
    vim_system = vim.system,
    vim_pack = vim.pack,
    vim_fn_filereadable = vim.fn.filereadable,
    vim_fn_isdirectory = vim.fn.isdirectory,
    vim_fn_mkdir = vim.fn.mkdir,
    vim_fn_confirm = vim.fn.confirm,
  }
end

local function restore_globals(snap)
  io.open = snap.io_open
  os.rename = snap.os_rename
  os.remove = snap.os_remove
  vim.system = snap.vim_system
  vim.pack = snap.vim_pack
  vim.fn.filereadable = snap.vim_fn_filereadable
  vim.fn.isdirectory = snap.vim_fn_isdirectory
  vim.fn.mkdir = snap.vim_fn_mkdir
  vim.fn.confirm = snap.vim_fn_confirm
end

local function run_all()
  local tests_dir = "tests"
  local files = {}

  -- 1. Discover all *_spec.lua files
  local fd = vim.loop.fs_scandir(tests_dir)
  if not fd then
    print("Error: Could not open tests directory: " .. tests_dir)
    os.exit(1)
  end

  while true do
    local name, type = vim.loop.fs_scandir_next(fd)
    if not name then
      break
    end
    if type == "file" and name:match("_spec%.lua$") then
      table.insert(files, vim.fs.joinpath(tests_dir, name))
    end
  end

  table.sort(files)

  if #files == 0 then
    print("No test files found in " .. tests_dir)
    os.exit(0)
  end

  print(string.format("Found %d test files\n", #files))

  local failed_files = {}

  -- 2. Run each file
  for _, file in ipairs(files) do
    print("--------------------------------------------------")
    print("Running: " .. file)

    -- Clear module cache for packard to ensure isolation between specs.
    -- Most specs mock packard internals, so we need a fresh start.
    for modname, _ in pairs(package.loaded) do
      if modname:match("^packard") then
        package.loaded[modname] = nil
      end
    end

    -- Snapshot globals before the test so we can restore them even on failure
    local snap = snapshot_globals()

    -- Run the test file
    local ok, err = pcall(dofile, file)

    -- Always restore globals — prevents mock leakage into subsequent tests
    restore_globals(snap)

    if not ok then
      print("\nFAILED: " .. file)
      print(err)
      table.insert(failed_files, { file = file, error = err })
    end
  end

  -- 3. Report summary
  print("\n" .. string.rep("=", 50))
  print("SUMMARY")
  print(string.rep("-", 50))
  print(string.format("Total:  %d", #files))
  print(string.format("Passed: %d", #files - #failed_files))
  print(string.format("Failed: %d", #failed_files))

  if #failed_files > 0 then
    print("\nFailures:")
    for _, failure in ipairs(failed_files) do
      print("- " .. failure.file)
    end
    print(string.rep("=", 50))
    -- Use cquit to exit with non-zero status in Neovim headless mode
    vim.cmd("cquit")
  else
    print(string.rep("=", 50))
    print("ALL TESTS PASSED!")
    os.exit(0)
  end
end

run_all()
