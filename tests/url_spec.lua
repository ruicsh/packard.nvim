local Helpers = require("tests.helpers")
local URL = require("packard.url")

Helpers.describe("URL module", function()
  ----------------------------------------------------------------------------
  -- Forge detection
  ----------------------------------------------------------------------------
  Helpers.describe("detect_forge", function()
    Helpers.it("detects GitHub URLs", function()
      Helpers.expect(URL.detect_forge("https://github.com/owner/repo")).to_be("github")
      Helpers.expect(URL.detect_forge("https://github.com/owner/repo.git")).to_be("github")
    end)

    Helpers.it("detects GitLab URLs", function()
      Helpers.expect(URL.detect_forge("https://gitlab.com/owner/repo")).to_be("gitlab")
      Helpers.expect(URL.detect_forge("https://gitlab.com/group/subgroup/repo")).to_be("gitlab")
    end)

    Helpers.it("detects Bitbucket URLs", function()
      Helpers.expect(URL.detect_forge("https://bitbucket.org/owner/repo")).to_be("bitbucket")
    end)

    Helpers.it("returns nil for unknown forges", function()
      Helpers.expect(URL.detect_forge("https://example.com/owner/repo")).to_be_nil()
      Helpers.expect(URL.detect_forge("https://sourcehut.org/owner/repo")).to_be_nil()
    end)

    Helpers.it("returns nil for invalid URLs", function()
      Helpers.expect(URL.detect_forge("not-a-url")).to_be_nil()
      Helpers.expect(URL.detect_forge("")).to_be_nil()
    end)
  end)

  ----------------------------------------------------------------------------
  -- Compare URL building
  ----------------------------------------------------------------------------
  Helpers.describe("build_compare_url", function()
    Helpers.it("builds GitHub compare URLs", function()
      local url = URL.build_compare_url("https://github.com/neovim/nvim-lspconfig.git", "sha1", "sha2")
      Helpers.expect(url).to_be("https://github.com/neovim/nvim-lspconfig/compare/sha1...sha2")
    end)

    Helpers.it("builds GitHub compare URLs without .git", function()
      local url = URL.build_compare_url("https://github.com/neovim/nvim-lspconfig", "sha1", "sha2")
      Helpers.expect(url).to_be("https://github.com/neovim/nvim-lspconfig/compare/sha1...sha2")
    end)

    Helpers.it("builds GitLab compare URLs", function()
      local url = URL.build_compare_url("https://gitlab.com/group/project", "sha1", "sha2")
      Helpers.expect(url).to_be("https://gitlab.com/group/project/-/compare/sha1...sha2")
    end)

    Helpers.it("builds GitLab compare URLs with nested paths", function()
      local url = URL.build_compare_url("https://gitlab.com/group/subgroup/project.git", "sha1", "sha2")
      Helpers.expect(url).to_be("https://gitlab.com/group/subgroup/project/-/compare/sha1...sha2")
    end)

    Helpers.it("builds Bitbucket compare URLs", function()
      local url = URL.build_compare_url("https://bitbucket.org/owner/repo", "sha1", "sha2")
      Helpers.expect(url).to_be("https://bitbucket.org/owner/repo/compare/sha2..sha1")
    end)

    Helpers.it("returns nil for unknown forge", function()
      local url = URL.build_compare_url("https://sourcehut.org/owner/repo", "sha1", "sha2")
      Helpers.expect(url).to_be_nil()
    end)

    Helpers.it("returns nil when URL has no path", function()
      local url = URL.build_compare_url("https://github.com", "sha1", "sha2")
      Helpers.expect(url).to_be_nil()
    end)

    Helpers.it("returns nil when URL has a single path segment", function()
      local url = URL.build_compare_url("https://github.com/repo", "sha1", "sha2")
      Helpers.expect(url).to_be_nil()
    end)

    Helpers.it("handles empty SHAs gracefully", function()
      -- Empty SHAs produce a URL, but the compare will be invalid
      local url = URL.build_compare_url("https://github.com/owner/repo", "", "")
      Helpers.expect(url).to_be("https://github.com/owner/repo/compare/...")
    end)
  end)

  ----------------------------------------------------------------------------
  -- Individual forge builders
  ----------------------------------------------------------------------------
  Helpers.describe("forge-specific builders", function()
    Helpers.it("build_github_compare formats correctly", function()
      local url = URL.build_github_compare("owner", "repo", "from", "to")
      Helpers.expect(url).to_be("https://github.com/owner/repo/compare/from...to")
    end)

    Helpers.it("build_gitlab_compare formats correctly", function()
      local url = URL.build_gitlab_compare("owner", "repo", "from", "to")
      Helpers.expect(url).to_be("https://gitlab.com/owner/repo/-/compare/from...to")
    end)

    Helpers.it("build_bitbucket_compare formats correctly", function()
      local url = URL.build_bitbucket_compare("owner", "repo", "from", "to")
      Helpers.expect(url).to_be("https://bitbucket.org/owner/repo/compare/to..from")
    end)
  end)
end)

print("URL tests passed!")
