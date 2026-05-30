local M = {}

---Bootstrap packard.nvim
---This snippet should be used in init.lua before require("packard").setup()
---It clones the plugin manager itself if it's missing.
function M.init()
  local packpath = vim.fn.stdpath("data") .. "/site/pack/packard/start/packard.nvim"
  if vim.fn.isdirectory(packpath) == 0 then
    -- If we are in the packard.nvim repo itself, we can just link it
    local current_dir = vim.fn.getcwd()
    if vim.fn.filereadable(current_dir .. "/lua/packard/init.lua") == 1 then
      print("Local packard.nvim detected, linking...")
      --[[@diagnostic disable-next-line: redundant-parameter]]
      vim.fn.mkdir(vim.fn.fnamemodify(packpath, ":h"), "p")
      -- Use a symlink if possible, or just copy if on windows and symlink fails
      if vim.fn.has("win32") == 1 then
        vim.fn.system({ "cmd", "/c", "mklink", "/D", packpath:gsub("/", "\\"), current_dir:gsub("/", "\\") })
      else
        vim.fn.system({ "ln", "-s", current_dir, packpath })
      end
    else
      print("Bootstrapping packard.nvim...")
      vim.fn.system({
        "git",
        "clone",
        "--filter=blob:none",
        "https://github.com/ruicsh/packard.nvim.git",
        packpath,
      })
    end
    print("Done. Please restart Neovim.")
  end
end

return M
