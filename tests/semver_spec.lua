local helpers = require("tests.helpers")
local describe, it, expect = helpers.describe, helpers.it, helpers.expect
local Semver = require("packard.semver")

describe("Semver", function()
  it("parses valid version strings", function()
    local v = Semver.parse("1.2.3")
    expect(v.major).to_be(1)
    expect(v.minor).to_be(2)
    expect(v.patch).to_be(3)
    expect(v.prerelease).to_be(nil)

    v = Semver.parse("v1.2.3")
    expect(v.major).to_be(1)
    expect(v.minor).to_be(2)
    expect(v.patch).to_be(3)

    v = Semver.parse("2.0.0-beta.1")
    expect(v.major).to_be(2)
    expect(v.prerelease).to_be("beta.1")

    v = Semver.parse("1.2")
    expect(v.major).to_be(1)
    expect(v.minor).to_be(2)
    expect(v.patch).to_be(0)

    v = Semver.parse("1")
    expect(v.major).to_be(1)
    expect(v.minor).to_be(0)
    expect(v.patch).to_be(0)
  end)

  it("handles invalid versions", function()
    expect(Semver.parse("abc")).to_be(nil)
    expect(Semver.parse("")).to_be(nil)
    expect(Semver.parse(nil)).to_be(nil)
  end)

  it("compares versions correctly", function()
    local v1 = Semver.parse("1.0.0")
    local v2 = Semver.parse("1.0.1")
    local v3 = Semver.parse("1.1.0")
    local v4 = Semver.parse("2.0.0")
    local vp = Semver.parse("1.0.0-alpha")

    expect(Semver.lt(v1, v2)).to_be(true)
    expect(Semver.lt(v2, v3)).to_be(true)
    expect(Semver.lt(v3, v4)).to_be(true)
    expect(Semver.lt(vp, v1)).to_be(true)
    expect(Semver.lt(v1, v1)).to_be(false)
  end)

  it("converts * range", function()
    local range = Semver.to_range("*")
    expect(range.from.major).to_be(0)
    expect(range.to).to_be(nil)
    expect(range.include_prerelease).to_be(false)

    expect(Semver.match(Semver.parse("1.2.3"), range)).to_be(true)
    expect(Semver.match(Semver.parse("0.0.1"), range)).to_be(true)
    expect(Semver.match(Semver.parse("2.0.0-beta"), range)).to_be(false)
  end)

  it("converts caret range ^1.2.3", function()
    local range = Semver.to_range("^1.2.3")
    expect(range.from.major).to_be(1)
    expect(range.from.patch).to_be(3)
    expect(range.to.major).to_be(2)

    expect(Semver.match(Semver.parse("1.2.3"), range)).to_be(true)
    expect(Semver.match(Semver.parse("1.9.9"), range)).to_be(true)
    expect(Semver.match(Semver.parse("2.0.0"), range)).to_be(false)
    expect(Semver.match(Semver.parse("1.2.2"), range)).to_be(false)
  end)

  it("converts tilde range ~1.2.3", function()
    local range = Semver.to_range("~1.2.3")
    expect(range.from.minor).to_be(2)
    expect(range.to.minor).to_be(3)

    expect(Semver.match(Semver.parse("1.2.3"), range)).to_be(true)
    expect(Semver.match(Semver.parse("1.2.9"), range)).to_be(true)
    expect(Semver.match(Semver.parse("1.3.0"), range)).to_be(false)
  end)

  it("converts partial version to range", function()
    -- "1" -> [1.0.0, 2.0.0)
    local range = Semver.to_range("1")
    expect(range.from.major).to_be(1)
    expect(range.to.major).to_be(2)

    -- "1.2" -> [1.2.0, 1.3.0)
    range = Semver.to_range("1.2")
    expect(range.from.minor).to_be(2)
    expect(range.to.minor).to_be(3)

    -- "1.*" -> [1.0.0, 2.0.0)
    range = Semver.to_range("1.*")
    expect(range.from.major).to_be(1)
    expect(range.to.major).to_be(2)
  end)

  it("handles pre-releases correctly in ranges", function()
    -- Range without pre-release excludes them
    local range = Semver.to_range("^1.0.0")
    expect(Semver.match(Semver.parse("1.1.0-beta"), range)).to_be(false)

    -- Range with pre-release includes them
    range = Semver.to_range("^1.1.0-beta")
    expect(Semver.match(Semver.parse("1.1.0-beta"), range)).to_be(true)
    expect(Semver.match(Semver.parse("1.1.0-rc1"), range)).to_be(true)
    expect(Semver.match(Semver.parse("1.1.0"), range)).to_be(true)
  end)

  it("picks the best version", function()
    local tags = {
      { tag = "v1.0.0", sha = "s1" },
      { tag = "v1.1.0", sha = "s2" },
      { tag = "v1.2.0", sha = "s3" },
      { tag = "v2.0.0", sha = "s4" },
    }
    local range = Semver.to_range("1.*")
    local best = Semver.pick_best(tags, range)
    expect(best.tag).to_be("v1.2.0")

    range = Semver.to_range("^1.0.0")
    best = Semver.pick_best(tags, range)
    expect(best.tag).to_be("v1.2.0")

    range = Semver.to_range(">=2.0.0")
    best = Semver.pick_best(tags, range)
    expect(best.tag).to_be("v2.0.0")
  end)
end)
