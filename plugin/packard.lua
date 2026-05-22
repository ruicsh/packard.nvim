-- plugin/packard.lua
-- Neovim >= 0.12 plugin manager

if vim.g.loaded_packard then
  return
end
vim.g.loaded_packard = true

-- The main module is lazy-loaded when the user calls require("packard").setup().
