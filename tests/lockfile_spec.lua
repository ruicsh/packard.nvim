local Lockfile = require("packard.lockfile")

local lockfile_path = vim.fn.stdpath("config") .. "/nvim-pack-lock.json"

local function setup_lockfile(data)
  local f = io.open(lockfile_path, "w")
  if f then
    f:write(vim.json.encode(data))
    f:close()
  end
end

local function cleanup_lockfile()
  if vim.fn.filereadable(lockfile_path) == 1 then
    os.remove(lockfile_path)
  end
end

local function test_lockfile()
  print("Testing lockfile reading...")
  cleanup_lockfile()
  Lockfile.invalidate()

  -- Test empty/missing
  assert(Lockfile.get_installed_commit("foo") == nil)
  assert(Lockfile.has_plugin("foo") == false)

  -- Test valid data
  setup_lockfile({
    ["nvim-lspconfig"] = {
      src = "https://github.com/neovim/nvim-lspconfig.git",
      ref = "a1b2c3d4e5f6",
    },
  })
  Lockfile.invalidate()

  assert(Lockfile.has_plugin("nvim-lspconfig") == true)
  assert(Lockfile.get_installed_commit("nvim-lspconfig") == "a1b2c3d4e5f6")
  assert(Lockfile.get_installed_commit("missing") == nil)

  cleanup_lockfile()
end

test_lockfile()
print("Lockfile tests passed!")
