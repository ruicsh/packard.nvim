local AI = {}
local State = require("packard.state")

AI.DEFAULT_PROMPT_TEMPLATE = [[
Review the following git diff between two commits of a Neovim plugin.
Your primary task is to assess security risk — does this change introduce or
modify code that could compromise the user's system? Look specifically for:
- Shell command execution (vim.fn.system, io.popen, vim.system) with
  potentially unsafe inputs
- Network calls (curl, sockets, HTTP) to new or unexpected endpoints
- File system writes, especially with user-controlled paths
- Changes to credential or token handling
- Dynamic code execution (load, dofile, eval) with unvalidated arguments

Secondarily, note any breaking changes that require user migration. Ignore
trivial changes like whitespace, comments, or version bumps in the summary.

Respond in JSON format with these fields:
- "summary": A one-paragraph plain-language summary of the changes (max 200 words)
- "risk": One of "Low", "Medium", or "High" (security + breaking-change risk)
- "reasoning": A brief explanation of the risk assessment

Diff:
```
%s
```
]]

---Parse LLM response based on provider
---@param provider string
---@param raw_body string
---@return {summary:string, risk:string, reasoning:string}|nil, string|nil error
local function parse_llm_response(provider, raw_body)
  local ok, decoded = pcall(vim.json.decode, raw_body)
  if not ok then
    return nil, "AI response was not valid JSON"
  end

  local content
  if provider == "openai" or provider == "ollama" then
    -- Ollama can use OpenAI compatible format or its own
    if decoded.choices and decoded.choices[1] and decoded.choices[1].message then
      content = decoded.choices[1].message.content
    elseif decoded.message and decoded.message.content then
      content = decoded.message.content
    elseif decoded.response then -- Simple Ollama generate
      content = decoded.response
    end
  elseif provider == "anthropic" then
    if decoded.content and decoded.content[1] and decoded.content[1].text then
      content = decoded.content[1].text
    end
  elseif provider == "custom" then
    -- Try to find content in a generic way
    content = decoded.content or decoded.response or decoded.text or raw_body
  end

  if not content then
    return nil, "AI response missing expected content field for provider " .. provider
  end

  -- If content is a string that contains JSON, try to extract it
  if type(content) == "string" then
    -- Find the first '{' and last '}'
    local first = content:find("{")
    local last = content:match(".*}")
    if first and last then
      local json_str = content:sub(first, content:find("}", first + (content:find(".*}") or 0) - 1))
      -- Re-find last because pattern matching in Lua is limited
      json_str = content:match("{.*}")
      local pok, pdecoded = pcall(vim.json.decode, json_str)
      if pok then
        content = pdecoded
      end
    end
  end

  if type(content) ~= "table" then
    return nil, "AI response content is not a JSON object"
  end

  -- Validate required fields
  if not content.summary or not content.risk or not content.reasoning then
    return nil, "AI response missing required fields: summary, risk, or reasoning"
  end

  return content
end

---Build request body based on provider
---@param provider string
---@param model string
---@param prompt string
---@return string
local function build_request_body(provider, model, prompt)
  if provider == "openai" or provider == "ollama" then
    return vim.json.encode({
      model = model,
      messages = {
        { role = "user", content = prompt },
      },
      response_format = { type = "json_object" },
    })
  elseif provider == "anthropic" then
    return vim.json.encode({
      model = model,
      max_tokens = 1024,
      messages = {
        { role = "user", content = prompt },
      },
    })
  else -- custom
    return vim.json.encode({
      model = model,
      messages = {
        { role = "user", content = prompt },
      },
    })
  end
end

---Run AI review flow
---@param plugin table Normalized plugin object
---@param from_sha string
---@param to_sha string
---@param opts table ai_review options from config
---@param callback fun(err: string|nil, result: AICacheEntry|nil)
function AI.review(plugin, from_sha, to_sha, opts, callback)
  if not opts or not opts.provider then
    callback("AI review not configured")
    return
  end

  -- 1. Check cache
  local cached = State.get_ai_cache(plugin.owner_repo, from_sha, to_sha)
  if cached then
    callback(nil, cached)
    return
  end

  -- 2. Generate diff
  local plugin_path = vim.fs.joinpath(vim.fn.stdpath("data"), "site", "pack", "core", "opt", plugin.name)
  if vim.fn.isdirectory(plugin_path) == 0 then
    callback("Plugin directory not found: " .. plugin_path)
    return
  end

  --[[@diagnostic disable-next-line: redundant-parameter]]
  vim.system({ "git", "-C", plugin_path, "diff", from_sha .. ".." .. to_sha }, { text = true }, function(out)
    if out.code ~= 0 then
      vim.schedule(function()
        callback("git diff failed: " .. (out.stderr or "unknown error"))
      end)
      return
    end

    local diff_text = out.stdout or ""
    local byte_size = #diff_text
    local warn_kb = opts.diff_warn_kb or 50
    local error_kb = opts.diff_error_kb or 200

    if byte_size > error_kb * 1024 then
      vim.schedule(function()
        callback(string.format("Diff too large (%.1f KB). Max %d KB.", byte_size / 1024, error_kb))
      end)
      return
    end

    if byte_size > warn_kb * 1024 and not opts.ignore_warn then
      vim.schedule(function()
        ---@diagnostic disable-next-line: missing-fields
        callback("WARN_LARGE_DIFF", { byte_size = byte_size })
      end)
      return
    end

    -- 3. Build request
    local prompt = string.format(opts.prompt_template or AI.DEFAULT_PROMPT_TEMPLATE, diff_text)
    local body = build_request_body(opts.provider, opts.model, prompt)
    local headers = vim.deepcopy(opts.headers or {})
    headers["Content-Type"] = "application/json"

    local curl_args = { "curl", "-s", "-X", "POST", "-d", body }
    for k, v in pairs(headers) do
      table.insert(curl_args, "-H")
      table.insert(curl_args, string.format("%s: %s", k, v))
    end
    table.insert(curl_args, opts.url)

    -- 4. Execute curl
    --[[@diagnostic disable-next-line: redundant-parameter]]
    vim.system(curl_args, { text = true }, function(curl_out)
      vim.schedule(function()
        if curl_out.code ~= 0 then
          callback("curl failed: " .. (curl_out.stderr or "unknown error"))
          return
        end

        -- 5. Parse response
        local result, err = parse_llm_response(opts.provider, curl_out.stdout)
        if err or not result then
          callback(err or "Failed to parse AI response")
          return
        end

        local entry = {
          summary = result.summary,
          risk = result.risk,
          reasoning = result.reasoning,
          cached_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        } ---@type AICacheEntry

        -- 6. Cache result
        if result and result.summary and result.risk and result.reasoning then
          State.set_ai_cache(plugin.owner_repo, from_sha, to_sha, entry)
        end
        callback(nil, entry)
      end)
    end)
  end)
end

---Exposed for testing
AI.parse_llm_response = parse_llm_response
-- Exposed for testing
AI.build_request_body = build_request_body

return AI
