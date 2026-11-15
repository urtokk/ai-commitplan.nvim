local function non_empty_string(value)
  if type(value) ~= "string" then
    return nil
  end
  local trimmed = vim.trim(value)
  return trimmed ~= "" and trimmed or nil
end

local function curl_timeout_args(config)
  local connect_timeout = config.connect_timeout > 0 and config.connect_timeout or 5
  local idle_timeout = config.idle_timeout > 0 and config.idle_timeout or 120
  return {
    "--connect-timeout",
    tostring(connect_timeout),
    "--speed-limit",
    "1",
    "--speed-time",
    tostring(idle_timeout),
  }
end

local function auth_file(config)
  local path = vim.fn.tempname()
  local fd, err = vim.uv.fs_open(path, "wx", 384)
  if not fd then
    return nil, err
  end
  local prefix = config.provider == "anthropic" and "x-api-key: " or "Authorization: Bearer "
  local written, write_error = vim.uv.fs_write(fd, prefix .. config.api_key .. "\n", 0)
  vim.uv.fs_close(fd)
  if not written then
    os.remove(path)
    return nil, write_error
  end
  return path
end

local function request(config, path, body, callback)
  local command = {
    "curl",
    "--fail-with-body",
    "--silent",
    "--show-error",
    "-H",
    "Content-Type: application/json",
  }
  vim.list_extend(command, curl_timeout_args(config))
  if config.provider == "anthropic" then
    vim.list_extend(command, { "-H", "anthropic-version: 2023-06-01" })
  end
  local header_path
  if config.api_key then
    local header_error
    header_path, header_error = auth_file(config)
    if not header_path then
      callback(nil, "Could not create a protected API header file: " .. tostring(header_error))
      return
    end
    vim.list_extend(command, { "--header", "@" .. header_path })
  end
  local request_body
  if body then
    request_body = vim.json.encode(body)
    vim.list_extend(command, { "--data-binary", "@-" })
  end
  table.insert(command, config.endpoint .. path)

  vim.system(command, { text = true, stdin = request_body }, function(result)
    if header_path then
      os.remove(header_path)
    end
    vim.schedule(function()
      if result.code ~= 0 then
        local ok, response = pcall(vim.json.decode, result.stdout or "")
        local detail = ok
            and type(response) == "table"
            and (non_empty_string(response.detail) or (type(response.error) == "table" and non_empty_string(
              response.error.message
            )))
          or nil
        local curl_error = vim.trim(result.stderr or "")
        if curl_error:find("507", 1, true) then
          local message = "oMLX has insufficient memory for this model or prompt."
          callback(nil, message .. (detail and " " .. detail or "") .. " Unload another model or select a smaller one.")
        elseif detail then
          callback(nil, "AI API: " .. detail)
        else
          callback(nil, curl_error ~= "" and curl_error or "AI API request failed")
        end
        return
      end

      local ok, response = pcall(vim.json.decode, result.stdout)
      callback(ok and response or nil, ok and nil or "AI API returned invalid JSON")
    end)
  end)
end

local function stream_decoder(on_activity)
  local pending, content, reasoning = "", {}, {}
  local finish_error

  local function append_delta(delta)
    local reasoning_delta = type(delta.reasoning_content) == "string" and delta.reasoning_content
      or type(delta.reasoning) == "string" and delta.reasoning
      or nil
    if reasoning_delta and reasoning_delta ~= "" then
      table.insert(reasoning, reasoning_delta)
      on_activity("reasoning", reasoning_delta)
    end
    if type(delta.content) == "string" and delta.content ~= "" then
      table.insert(content, delta.content)
      on_activity("content", delta.content)
    end
  end

  local function consume(line)
    line = line:gsub("\r$", "")
    if not line:match("^data:") then
      return
    end
    local data = vim.trim(line:sub(6))
    if data == "" or data == "[DONE]" then
      return
    end
    local ok, chunk = pcall(vim.json.decode, data)
    local choices = ok and type(chunk) == "table" and type(chunk.choices) == "table" and chunk.choices or {}
    local choice = type(choices[1]) == "table" and choices[1] or {}
    if type(choice.finish_reason) == "string" and choice.finish_reason ~= "stop" then
      finish_error = "Incomplete model response: " .. choice.finish_reason
    end
    if type(choice.delta) == "table" then
      append_delta(choice.delta)
    end
  end

  return {
    feed = function(chunk)
      pending = pending .. (chunk or "")
      while true do
        local newline = pending:find("\n", 1, true)
        if not newline then
          break
        end
        consume(pending:sub(1, newline - 1))
        pending = pending:sub(newline + 1)
      end
    end,
    finish = function()
      if pending ~= "" then
        consume(pending)
      end
      return table.concat(content), table.concat(reasoning), finish_error
    end,
  }
end

local function stream_request(config, path, body, on_activity, callback)
  if config.provider == "anthropic" then
    request(config, "/messages", {
      model = body.model,
      max_tokens = body.max_tokens,
      system = body.messages[1].content,
      messages = { body.messages[2] },
    }, function(response, err)
      if not response then
        callback(nil, err)
        return
      end
      if response.stop_reason ~= "end_turn" then
        callback(nil, "Anthropic response did not finish normally: " .. tostring(response.stop_reason))
        return
      end
      local parts = {}
      for _, block in ipairs(type(response.content) == "table" and response.content or {}) do
        if block.type == "text" and type(block.text) == "string" then
          table.insert(parts, block.text)
        end
      end
      local content = table.concat(parts)
      on_activity("content", content)
      callback(non_empty_string(content), content == "" and "Anthropic returned no text" or nil)
    end)
    return
  end
  local command = {
    "curl",
    "--fail-with-body",
    "--silent",
    "--show-error",
    "--no-buffer",
    "-H",
    "Content-Type: application/json",
  }
  vim.list_extend(command, curl_timeout_args(config))
  local header_path
  if config.api_key then
    local header_error
    header_path, header_error = auth_file(config)
    if not header_path then
      callback(nil, "Could not create a protected API header file: " .. tostring(header_error))
      return
    end
    vim.list_extend(command, { "--header", "@" .. header_path })
  end
  body.stream = true
  vim.list_extend(command, { "--data-binary", "@-", config.endpoint .. path })

  local decoder = stream_decoder(on_activity)
  local stderr = {}
  vim.system(command, {
    text = true,
    stdin = vim.json.encode(body),
    stdout = function(_, data)
      if data then
        vim.schedule(function()
          decoder.feed(data)
        end)
      end
    end,
    stderr = function(_, data)
      if data then
        table.insert(stderr, data)
      end
    end,
  }, function(result)
    if header_path then
      os.remove(header_path)
    end
    vim.schedule(function()
      local content, _, finish_error = decoder.finish()
      if finish_error then
        callback(nil, finish_error)
        return
      end
      if result.code ~= 0 then
        local message = vim.trim(table.concat(stderr))
        callback(nil, message ~= "" and message or "oMLX streaming request failed")
        return
      end
      callback(non_empty_string(content), nil)
    end)
  end)
end

return {
  request = request,
  stream_request = stream_request,
  stream_decoder = stream_decoder,
  curl_timeout_args = curl_timeout_args,
}
