local Helpers = require("tests.helpers")
local AI = require("packard.ai")

-- ============================================================================
-- build_request_body
-- ============================================================================
Helpers.describe("AI.build_request_body", function()
  Helpers.it("builds OpenAI body with response_format", function()
    local body = vim.json.decode(AI.build_request_body("openai", "gpt-4o", "hello"))
    Helpers.expect(body.model).to_be("gpt-4o")
    Helpers.expect(body.messages[1].role).to_be("user")
    Helpers.expect(body.messages[1].content).to_be("hello")
    Helpers.expect(body.response_format.type).to_be("json_object")
    Helpers.expect(body.max_tokens).to_be_nil()
  end)

  Helpers.it("builds Anthropic body with max_tokens and no response_format", function()
    local body = vim.json.decode(AI.build_request_body("anthropic", "claude-sonnet-4", "prompt"))
    Helpers.expect(body.model).to_be("claude-sonnet-4")
    Helpers.expect(body.messages[1].content).to_be("prompt")
    Helpers.expect(body.max_tokens).to_be(1024)
    Helpers.expect(body.response_format).to_be_nil()
  end)

  Helpers.it("builds Ollama body like OpenAI with response_format", function()
    local body = vim.json.decode(AI.build_request_body("ollama", "llama3", "prompt"))
    Helpers.expect(body.model).to_be("llama3")
    Helpers.expect(body.response_format.type).to_be("json_object")
  end)

  Helpers.it("builds Custom body as generic openai-compatible (no response_format)", function()
    local body = vim.json.decode(AI.build_request_body("custom", "my-model", "prompt"))
    Helpers.expect(body.model).to_be("my-model")
    Helpers.expect(body.messages[1].content).to_be("prompt")
    Helpers.expect(body.response_format).to_be_nil()
    Helpers.expect(body.max_tokens).to_be_nil()
  end)
end)

-- ============================================================================
-- parse_llm_response
-- ============================================================================
Helpers.describe("AI.parse_llm_response", function()
  local function openai_resp(content)
    return vim.json.encode({ choices = { { message = { content = content } } } })
  end

  local function anthropic_resp(content)
    return vim.json.encode({ content = { { text = content } } })
  end

  local function ollama_chat_resp(content)
    return vim.json.encode({ message = { content = content } })
  end

  local function ollama_gen_resp(content)
    return vim.json.encode({ response = content })
  end

  Helpers.it("parses OpenAI choices[1].message.content with embedded JSON", function()
    local body = openai_resp('{"summary":"Minor refactor","risk":"Low","reasoning":"No API changes"}')
    local result, err = AI.parse_llm_response("openai", body)
    Helpers.expect(err).to_be_nil()
    assert(result ~= nil)
    Helpers.expect(result.summary).to_be("Minor refactor")
    Helpers.expect(result.risk).to_be("Low")
    Helpers.expect(result.reasoning).to_be("No API changes")
  end)

  Helpers.it("parses Anthropic content[1].text with embedded JSON", function()
    local body = anthropic_resp('{"summary":"Config update","risk":"Low","reasoning":"Minor version bump"}')
    local result, err = AI.parse_llm_response("anthropic", body)
    Helpers.expect(err).to_be_nil()
    assert(result ~= nil)
    Helpers.expect(result.summary).to_be("Config update")
    Helpers.expect(result.risk).to_be("Low")
  end)

  Helpers.it("parses Ollama chat format (message.content)", function()
    local body = ollama_chat_resp('{"summary":"Bug fix","risk":"Medium","reasoning":"Core logic change"}')
    local result, err = AI.parse_llm_response("ollama", body)
    Helpers.expect(err).to_be_nil()
    assert(result ~= nil)
    Helpers.expect(result.risk).to_be("Medium")
    Helpers.expect(result.summary).to_be("Bug fix")
  end)

  Helpers.it("parses Ollama generate format (.response)", function()
    local body = ollama_gen_resp('{"summary":"Docs update","risk":"Low","reasoning":"Comments only"}')
    local result, err = AI.parse_llm_response("ollama", body)
    Helpers.expect(err).to_be_nil()
    assert(result ~= nil)
    Helpers.expect(result.summary).to_be("Docs update")
  end)

  Helpers.it("parses pre-parsed JSON content (content is already a table)", function()
    -- When the LLM returns the JSON object directly rather than a string
    local body = vim.json.encode({
      choices = {
        {
          message = { content = { summary = "Direct", risk = "High", reasoning = "already parsed" } },
        },
      },
    })
    local result, err = AI.parse_llm_response("openai", body)
    Helpers.expect(err).to_be_nil()
    assert(result ~= nil)
    Helpers.expect(result.summary).to_be("Direct")
    Helpers.expect(result.risk).to_be("High")
  end)

  Helpers.it("handles Custom provider with content as a table", function()
    local body = vim.json.encode({ content = { summary = "Custom work", risk = "Low", reasoning = "fine" } })
    local result, err = AI.parse_llm_response("custom", body)
    Helpers.expect(err).to_be_nil()
    assert(result ~= nil)
    Helpers.expect(result.summary).to_be("Custom work")
  end)

  Helpers.it("returns error for invalid JSON", function()
    local result, err = AI.parse_llm_response("openai", "not json at all")
    Helpers.expect(result).to_be_nil()
    Helpers.expect(err).to_be("AI response was not valid JSON")
  end)

  Helpers.it("returns error when provider content field is missing", function()
    local body = vim.json.encode({ foo = "bar" })
    local result, err = AI.parse_llm_response("anthropic", body)
    Helpers.expect(result).to_be_nil()
    assert(err ~= nil)
    Helpers.expect(err:find("missing expected content field")).to_be_truthy()
  end)

  Helpers.it("returns error when parsed content field exists but has no JSON extraction", function()
    -- Content is extracted as a string but contains no JSON object
    local body = openai_resp("Hello, this is a plain text response without JSON.")
    local result, err = AI.parse_llm_response("openai", body)
    Helpers.expect(result).to_be_nil()
    Helpers.expect(err).to_be("AI response content is not a JSON object")
  end)

  Helpers.it("returns error when content is missing required fields (summary/risk/reasoning)", function()
    local body = openai_resp('{"summary":"Only summary present"}')
    local result, err = AI.parse_llm_response("openai", body)
    Helpers.expect(result).to_be_nil()
    assert(err ~= nil)
    Helpers.expect(err:find("missing required fields")).to_be_truthy()
  end)

  Helpers.it("returns error when content has summary/risk but missing reasoning", function()
    local body = ollama_chat_resp('{"summary":"partial","risk":"High"}')
    local result, err = AI.parse_llm_response("ollama", body)
    Helpers.expect(result).to_be_nil()
    assert(err ~= nil)
    Helpers.expect(err:find("missing required fields")).to_be_truthy()
  end)

  Helpers.it("handles markdown-wrapped JSON in content string", function()
    local body = openai_resp([[
Here is my analysis:

```json
{"summary":"Markdown wrapped","risk":"Low","reasoning":"Wrapped in code fence"}
```

Let me know if you have questions.
    ]])
    local result, err = AI.parse_llm_response("openai", body)
    Helpers.expect(err).to_be_nil()
    assert(result ~= nil)
    Helpers.expect(result.summary).to_be("Markdown wrapped")
    Helpers.expect(result.risk).to_be("Low")
  end)

  -- Generic fallback tests
  Helpers.it("parses choices[1].text (older Completions API)", function()
    local body = vim.json.encode({
      choices = { { text = '{"summary":"Fallback text","risk":"Low","reasoning":"via choices[1].text"}' } },
    })
    local result, err = AI.parse_llm_response("openai", body)
    Helpers.expect(err).to_be_nil()
    assert(result ~= nil)
    Helpers.expect(result.summary).to_be("Fallback text")
    Helpers.expect(result.risk).to_be("Low")
  end)

  Helpers.it("parses content as array of {type, text} parts (anthropic-style for openai)", function()
    local body = vim.json.encode({
      content = { { type = "text", text = '{"summary":"Array parts","risk":"Medium","reasoning":"via content[1].text"}' } },
    })
    local result, err = AI.parse_llm_response("openai", body)
    Helpers.expect(err).to_be_nil()
    assert(result ~= nil)
    Helpers.expect(result.summary).to_be("Array parts")
    Helpers.expect(result.risk).to_be("Medium")
  end)

  Helpers.it("parses content as bare string (direct response)", function()
    local body = vim.json.encode({
      content = '{"summary":"Direct string","risk":"Low","reasoning":"via content string"}',
    })
    local result, err = AI.parse_llm_response("openai", body)
    Helpers.expect(err).to_be_nil()
    assert(result ~= nil)
    Helpers.expect(result.summary).to_be("Direct string")
  end)

  Helpers.it("parses output[0].content[0].text (Responses API)", function()
    local body = vim.json.encode({
      output = { { content = { { text = '{"summary":"Responses API","risk":"Low","reasoning":"via output[0].content[0].text"}' } } } },
    })
    local result, err = AI.parse_llm_response("openai", body)
    Helpers.expect(err).to_be_nil()
    assert(result ~= nil)
    Helpers.expect(result.summary).to_be("Responses API")
    Helpers.expect(result.reasoning:find("output") ~= nil).to_be_truthy()
    local result2, err2 = AI.parse_llm_response("anthropic", body)
    Helpers.expect(err2).to_be_nil()
    assert(result2 ~= nil)
    Helpers.expect(result2.summary).to_be("Responses API")
  end)

  Helpers.it("parses delta.content (streaming chunk format)", function()
    local body = vim.json.encode({
      choices = { { delta = { content = '{"summary":"Streaming","risk":"Low","reasoning":"via delta"}' } } },
    })
    local result, err = AI.parse_llm_response("openai", body)
    Helpers.expect(err).to_be_nil()
    assert(result ~= nil)
    Helpers.expect(result.summary).to_be("Streaming")
  end)

  -- API error detection tests
  Helpers.it("detects API error with message field", function()
    local body = vim.json.encode({ error = { message = "Rate limit exceeded" } })
    local result, err = AI.parse_llm_response("openai", body)
    Helpers.expect(result).to_be_nil()
    assert(err ~= nil)
    Helpers.expect(err:find("API error")).to_be_truthy()
    Helpers.expect(err:find("Rate limit")).to_be_truthy()
  end)

  Helpers.it("detects API error with code field", function()
    local body = vim.json.encode({ error = { code = "insufficient_quota" } })
    local result, err = AI.parse_llm_response("openai", body)
    Helpers.expect(result).to_be_nil()
    assert(err ~= nil)
    Helpers.expect(err:find("API error")).to_be_truthy()
    Helpers.expect(err:find("insufficient_quota")).to_be_truthy()
  end)

  Helpers.it("detects string API error", function()
    local body = vim.json.encode({ error = "Insufficient credits" })
    local result, err = AI.parse_llm_response("openai", body)
    Helpers.expect(result).to_be_nil()
    assert(err ~= nil)
    Helpers.expect(err:find("API error")).to_be_truthy()
    Helpers.expect(err:find("Insufficient credits")).to_be_truthy()
  end)

  Helpers.it("handles empty choices array gracefully", function()
    local body = vim.json.encode({ choices = {}, model = "gpt-4o" })
    local result, err = AI.parse_llm_response("openai", body)
    Helpers.expect(result).to_be_nil()
    assert(err ~= nil)
    Helpers.expect(err:find("missing expected content field")).to_be_truthy()
    -- Should include top-level keys in the error message
    Helpers.expect(err:find("choices")).to_be_truthy()
    Helpers.expect(err:find("model")).to_be_truthy()
  end)
end)

-- ============================================================================
-- AI.review (synchronous-only paths; async paths require vim.system mocking)
-- ============================================================================
Helpers.describe("AI.review", function()
  Helpers.it("returns error when opts is nil", function()
    local called = false
    --[[@diagnostic disable-next-line: param-type-mismatch]]
    AI.review({ owner_repo = "a/b", name = "b" }, "from", "to", nil, function(err, res)
      called = true
      Helpers.expect(err).to_be("AI review not configured")
      Helpers.expect(res).to_be_nil()
    end)
    Helpers.expect(called).to_be(true)
  end)

  Helpers.it("returns error when opts.provider is nil", function()
    local called = false
    AI.review({ owner_repo = "a/b", name = "b" }, "from", "to", {}, function(err, res)
      called = true
      Helpers.expect(err).to_be("AI review not configured")
    end)
    Helpers.expect(called).to_be(true)
  end)

  Helpers.it("returns cached result synchronously when cache hit", function()
    local State = require("packard.state")
    local restore = Helpers.mock(State, "get_ai_cache", function()
      return {
        summary = "cached result summary",
        risk = "Low",
        reasoning = "Returned from cache",
        cached_at = "2026-01-01T00:00:00Z",
      }
    end)

    local called = false
    AI.review(
      { owner_repo = "owner/repo", name = "repo" },
      "from-sha",
      "to-sha",
      { provider = "openai" },
      function(err, res)
        called = true
        Helpers.expect(err).to_be_nil()
        assert(res ~= nil)
        Helpers.expect(res.summary).to_be("cached result summary")
        Helpers.expect(res.risk).to_be("Low")
        Helpers.expect(res.cached_at).to_be("2026-01-01T00:00:00Z")
      end
    )
    Helpers.expect(called).to_be(true)

    restore()
  end)

  Helpers.it("returns error when plugin directory is missing", function()
    local State = require("packard.state")
    local restore_cache = Helpers.mock(State, "get_ai_cache", function()
      return nil
    end)

    local original_isdir = vim.fn.isdirectory
    rawset(vim.fn, "isdirectory", function(_path)
      return 0
    end)

    local called = false
    AI.review(
      { owner_repo = "missing/plugin", name = "nonexistent" },
      "from",
      "to",
      { provider = "openai" },
      function(err, _res)
        called = true
        assert(err ~= nil)
        Helpers.expect(err:find("Plugin directory not found") ~= nil).to_be_truthy()
      end
    )
    Helpers.expect(called).to_be(true)

    rawset(vim.fn, "isdirectory", original_isdir)
    restore_cache()
  end)
end)

-- ============================================================================
-- AI default prompt template
-- ============================================================================
Helpers.describe("AI.DEFAULT_PROMPT_TEMPLATE", function()
  Helpers.it("contains expected sections", function()
    Helpers.expect(AI.DEFAULT_PROMPT_TEMPLATE:find("summary")).to_be_truthy()
    Helpers.expect(AI.DEFAULT_PROMPT_TEMPLATE:find("risk")).to_be_truthy()
    Helpers.expect(AI.DEFAULT_PROMPT_TEMPLATE:find("reasoning")).to_be_truthy()
    Helpers.expect(AI.DEFAULT_PROMPT_TEMPLATE:find("%s")).to_be_truthy() -- has %s for diff
  end)
end)

print("AI tests passed!")
