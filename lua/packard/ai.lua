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

---Detect and report API-level errors in the response
---@param decoded table
---@return boolean true if an error was detected (caller should return nil, err)
---@return string|nil error message
local function detect_api_error(decoded)
  if decoded.error then
    if type(decoded.error) == "string" then
      return true, "API error: " .. decoded.error
    end
    local msg = decoded.error.message or decoded.error.code or tostring(decoded.error)
    return true, "API error: " .. msg
  end
  return false
end

---Try to extract content from a decoded API response using common paths.
---Returns nil if nothing found.
---@param decoded table
---@return string|table|nil
local function extract_content(decoded)
  -- Standard Chat Completions: choices[0].message.content
  if decoded.choices and decoded.choices[1] and decoded.choices[1].message then
    if decoded.choices[1].message.content ~= nil then
      return decoded.choices[1].message.content
    end
  end
  -- Older Completions API: choices[0].text
  if decoded.choices and decoded.choices[1] and decoded.choices[1].text then
    return decoded.choices[1].text
  end
  -- Streaming delta: choices[0].delta.content
  if decoded.choices and decoded.choices[1] and decoded.choices[1].delta then
    if decoded.choices[1].delta.content ~= nil then
      return decoded.choices[1].delta.content
    end
  end
  -- Ollama chat: message.content
  if decoded.message and decoded.message.content ~= nil then
    return decoded.message.content
  end
  -- Anthropic / content as array of {type, text}
  if type(decoded.content) == "table" then
    if decoded.content[1] and decoded.content[1].text then
      return decoded.content[1].text
    end
    -- If it's a table but not the array-of-parts format, return as-is
    return decoded.content
  end
  -- Content as bare string
  if type(decoded.content) == "string" then
    return decoded.content
  end
  -- Simple Ollama generate: response
  if decoded.response then
    return decoded.response
  end
  -- Generic text field
  if decoded.text then
    return decoded.text
  end
  -- Responses API: output[0].content[0].text
  if type(decoded.output) == "table" and decoded.output[1] and decoded.output[1].content then
    if
      type(decoded.output[1].content) == "table"
      and decoded.output[1].content[1]
      and decoded.output[1].content[1].text
    then
      return decoded.output[1].content[1].text
    end
    if type(decoded.output[1].content) == "string" then
      return decoded.output[1].content
    end
  end

  return nil
end

---Format top-level keys from a JSON response for diagnostic messages
---@param decoded table
---@return string
local function format_response_keys(decoded)
  local keys = {}
  for k, _ in pairs(decoded) do
    table.insert(keys, tostring(k))
  end
  table.sort(keys)
  return table.concat(keys, ", ")
end

---Parse LLM response based on provider
---@param provider string
---@param raw_body string
---@return {summary:string, risk:string, reasoning:string}|nil, string|nil error
local function parse_llm_response(provider, raw_body)
  local ok, decoded = pcall(vim.json.decode, raw_body)
  if not ok then
    return nil, "AI response was not valid JSON"
  end

  -- 1. Detect API-level errors (rate limits, auth failures, etc.)
  local is_error, err_msg = detect_api_error(decoded)
  if is_error then
    return nil, err_msg
  end

  -- 2. Extract content using provider-specific logic + generic fallback
  local content

  -- Provider-specific path: Anthropic uses content[1].text but extract_content
  -- already handles that generically. Only custom provider gets the raw fallback.
  if provider == "custom" then
    -- For custom provider, try all common paths then fall back to raw body
    content = extract_content(decoded)
    if not content then
      content = raw_body
    end
  else
    content = extract_content(decoded)
  end

  if not content then
    local keys_str = format_response_keys(decoded)
    local diag = string.format(
      "AI response missing expected content field for provider %s. Top-level keys: %s",
      provider,
      keys_str
    )
    -- Log the raw body (truncated) so the user can inspect it
    local truncated = raw_body:sub(1, 1500)
    if #raw_body > 1500 then
      truncated = truncated .. "\n... [response truncated, check :messages for full body]"
    end
    print("packard: AI response parsing failed. Full response body:\n" .. truncated)
    return nil, diag
  end

  -- 3. If content is a string that might contain JSON, try to extract it
  if type(content) == "string" then
    local json_str = content:match("{.*}")
    if json_str then
      local pok, pdecoded = pcall(vim.json.decode, json_str)
      if pok and type(pdecoded) == "table" then
        content = pdecoded
      end
    end
  end

  if type(content) ~= "table" then
    return nil, "AI response content is not a JSON object"
  end

  -- 4. Validate required fields
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
  local Utils = require("packard.utils")
  local plugin_path = Utils.get_plugin_path(plugin)
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

        -- Debug: log raw response before parsing
        if opts.debug and curl_out.stdout then
          print("packard [debug]: AI raw response body:\n" .. curl_out.stdout)
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
