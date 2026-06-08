local Helpers = require("tests.helpers")
local Utils = require("packard.utils")

Helpers.describe("Utils.norm", function()
  Helpers.it("expands tilde to home directory", function()
    local result = Utils.norm("~/projects/foo.nvim")
    Helpers.expect(result:sub(1, 1) == "/").to_be_truthy()
    Helpers.expect(string.find(result, "projects/foo.nvim", 1, true) ~= nil).to_be_truthy()
  end)

  Helpers.it("resolves relative paths to absolute", function()
    local result = Utils.norm("./my-plugin")
    Helpers.expect(result:sub(1, 1) == "/").to_be_truthy()
    Helpers.expect(string.find(result, "my-plugin", 1, true) ~= nil).to_be_truthy()
  end)

  Helpers.it("resolves parent-relative paths to absolute", function()
    local result = Utils.norm("../my-plugin")
    Helpers.expect(result:sub(1, 1) == "/").to_be_truthy()
    Helpers.expect(string.find(result, "my-plugin", 1, true) ~= nil).to_be_truthy()
  end)

  Helpers.it("keeps absolute paths unchanged", function()
    local result = Utils.norm("/usr/local/my-plugin")
    Helpers.expect(result).to_be("/usr/local/my-plugin")
  end)

  Helpers.it("strips trailing slash", function()
    local result = Utils.norm("/usr/local/my-plugin/")
    Helpers.expect(result).to_be("/usr/local/my-plugin")
  end)

  Helpers.it("deduplicates internal slashes", function()
    local result = Utils.norm("/usr//local///my-plugin")
    Helpers.expect(result).to_be("/usr/local/my-plugin")
  end)

  Helpers.it("resolves bare names to absolute", function()
    local result = Utils.norm("my-plugin")
    Helpers.expect(result:sub(1, 1) == "/").to_be_truthy()
    Helpers.expect(string.find(result, "my-plugin", 1, true) ~= nil).to_be_truthy()
  end)
end)

Helpers.describe("Utils.path_name", function()
  Helpers.it("extracts name from path", function()
    Helpers.expect(Utils.path_name("/some/dir/my-plugin")).to_be("my-plugin")
  end)

  Helpers.it("strips .git suffix", function()
    Helpers.expect(Utils.path_name("/some/dir/my-plugin.git")).to_be("my-plugin")
  end)

  Helpers.it("returns input when no slash", function()
    Helpers.expect(Utils.path_name("my-plugin")).to_be("my-plugin")
  end)

  Helpers.it("handles trailing slash", function()
    Helpers.expect(Utils.path_name("/some/dir/")).to_be("dir")
  end)
end)

Helpers.describe("Utils.get_plugin_path", function()
  Helpers.it("returns dir for local plugins", function()
    local plugin = { dir = "/custom/path", name = "my-plugin", is_local = true }
    local path = Utils.get_plugin_path(plugin)
    Helpers.expect(path).to_be("/custom/path")
  end)

  Helpers.it("returns standard path for remote plugins", function()
    local plugin = { name = "test-plugin", owner_repo = "user/test-plugin" }
    local path = Utils.get_plugin_path(plugin)
    Helpers.expect(path:find("test-plugin", 1, true)).to_be_truthy()
    Helpers.expect(path:find("pack/core/opt", 1, true)).to_be_truthy()
  end)

  Helpers.it("accepts a string name", function()
    local path = Utils.get_plugin_path("string-name")
    Helpers.expect(path:find("string-name", 1, true)).to_be_truthy()
    Helpers.expect(path:find("pack/core/opt", 1, true)).to_be_truthy()
  end)
end)

Helpers.describe("Utils.convert_control_chars", function()
  Helpers.it("converts ^A to Ctrl-A (0x01)", function()
    local result = Utils.convert_control_chars("^A")
    Helpers.expect(result).to_be(string.char(1))
  end)

  Helpers.it("converts ^[ to ESC (0x1B)", function()
    local result = Utils.convert_control_chars("^[")
    Helpers.expect(result).to_be(string.char(27))
  end)

  Helpers.it("converts ^] to GS (0x1D)", function()
    local result = Utils.convert_control_chars("^]")
    Helpers.expect(result).to_be(string.char(29))
  end)

  Helpers.it("converts control char in middle of string", function()
    local result = Utils.convert_control_chars("prefix^X")
    Helpers.expect(result).to_be("prefix" .. string.char(24))
  end)

  Helpers.it("skips conversion after [ (negation context)", function()
    local result = Utils.convert_control_chars("[^A]")
    Helpers.expect(result).to_be("[^A]")
  end)
end)

print("Utils tests passed!")
