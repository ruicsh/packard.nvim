local Cooldown = require("packard.cooldown")
local URL = require("packard.url")

local function test_cooldown_logic()
  print("Testing cooldown eligibility...")

  -- Use UTC time to be consistent
  local now_t = os.date("!*t")

  -- Create a timestamp for 31 days ago
  local old_t = vim.deepcopy(now_t)
  old_t.day = old_t.day - 31
  local old_time = os.time(old_t)
  local old_iso = os.date("!%Y-%m-%dT%H:%M:%SZ", old_time) --[[@as string]]

  local eligible, remaining = Cooldown.check_eligibility(old_iso, 30)
  assert(eligible == true)
  assert(remaining == 0)

  -- Create a timestamp for 29 days ago
  local young_t = vim.deepcopy(now_t)
  young_t.day = young_t.day - 29
  local young_time = os.time(young_t)
  local young_iso = os.date("!%Y-%m-%dT%H:%M:%SZ", young_time) --[[@as string]]

  local eligible2, remaining2 = Cooldown.check_eligibility(young_iso, 30)
  assert(eligible2 == false)
  assert(remaining2 > 0 and remaining2 <= 86400)
end

local function test_url_builder()
  print("Testing URL builder...")

  local github = URL.build_compare_url("https://github.com/neovim/nvim-lspconfig.git", "sha1", "sha2")
  assert(github == "https://github.com/neovim/nvim-lspconfig/compare/sha1...sha2")

  local gitlab = URL.build_compare_url("https://gitlab.com/group/project", "sha1", "sha2")
  assert(gitlab == "https://gitlab.com/group/project/-/compare/sha1...sha2")

  local bb = URL.build_compare_url("https://bitbucket.org/owner/repo", "sha1", "sha2")
  assert(bb == "https://bitbucket.org/owner/repo/compare/sha2..sha1")

  print("Testing nested GitLab paths...")
  local gitlab_nested = URL.build_compare_url("https://gitlab.com/group/subgroup/project", "sha1", "sha2")
  assert(gitlab_nested == "https://gitlab.com/group/subgroup/project/-/compare/sha1...sha2")
end

test_cooldown_logic()
test_url_builder()
print("Cooldown and URL tests passed!")
