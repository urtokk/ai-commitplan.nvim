local M = {}
local options = {}

function M.setup(opts)
  opts = opts or {}
  assert(type(opts) == "table", "AICommit setup expects a table")
  assert(
    vim.tbl_contains({ "omlx", "openai_compatible", "anthropic" }, opts.provider or "omlx"),
    "Unknown AICommit provider"
  )
  for _, field in ipairs({ "connect_timeout", "idle_timeout" }) do
    assert(opts[field] == nil or (type(opts[field]) == "number" and opts[field] > 0), field .. " must be positive")
  end
  assert(opts.api_key == nil or type(opts.api_key) == "string" or type(opts.api_key) == "function", "Invalid api_key")
  assert(
    opts.endpoint == nil or (type(opts.endpoint) == "string" and opts.endpoint:match("^https?://")),
    "Expected an HTTP(S) endpoint"
  )
  options = vim.deepcopy(opts or {})
end

local MAX_CONTEXT_BYTES = 50000
local MAX_FILE_CONTEXT_BYTES = 40000
local MAX_SINGLE_FILE_BYTES = 16000
local MAX_COMMIT_HEADER_BYTES = 72
local MAX_ACTIVITY_LINES = 200
local session_active = false

local function non_empty_string(value)
  if type(value) ~= "string" then
    return nil
  end
  local trimmed = vim.trim(value)
  return trimmed ~= "" and trimmed or nil
end

local function read_json(path)
  local file = io.open(path, "r")
  if not file then
    return {}
  end
  local ok, value = pcall(vim.json.decode, file:read("*a"))
  file:close()
  return ok and type(value) == "table" and value or {}
end

local function omlx_config()
  local settings = read_json(vim.fs.joinpath(vim.fn.expand("~"), ".omlx", "settings.json"))
  local server = type(settings.server) == "table" and settings.server or {}
  local integrations = type(settings.integrations) == "table" and settings.integrations or {}
  local auth = type(settings.auth) == "table" and settings.auth or {}
  local host = non_empty_string(server.host) or "127.0.0.1"
  local port = type(server.port) == "number" and server.port or non_empty_string(server.port) or 8000

  return {
    endpoint = ("http://%s:%s/v1"):format(host, port),
    api_key = non_empty_string(vim.env.OMLX_API_KEY) or non_empty_string(auth.api_key),
    model = non_empty_string(vim.env.OMLX_COMMIT_MODEL) or non_empty_string(integrations.commit_model),
    connect_timeout = tonumber(vim.env.OMLX_CONNECT_TIMEOUT) or 5,
    idle_timeout = tonumber(vim.env.OMLX_IDLE_TIMEOUT) or 120,
  }
end

local function connection_config()
  local config = (options.provider == "openai_compatible" or options.provider == "anthropic")
      and { connect_timeout = 5, idle_timeout = 120 }
    or omlx_config()
  config = vim.tbl_extend("force", config, options)
  if config.provider == "anthropic" then
    config.endpoint = config.endpoint or "https://api.anthropic.com/v1"
    config.api_key_env = config.api_key_env or (not config.api_key and "ANTHROPIC_API_KEY" or nil)
  end
  if type(config.api_key) == "function" then
    config.api_key = config.api_key()
  end
  if config.api_key_env then
    config.api_key = vim.env[config.api_key_env]
  end
  config.endpoint = (config.endpoint or ""):gsub("/+$", "")
  assert(
    not config.api_key or (type(config.api_key) == "string" and not config.api_key:find("[\r\n]")),
    "Invalid API key"
  )
  return config
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

local function show_activity(snapshot)
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buffer, "AI Commit Model Activity " .. buffer)
  local width = math.max(1, math.min(100, vim.o.columns - 8))
  local height = math.max(1, math.min(28, vim.o.lines - 8))
  local window = vim.api.nvim_open_win(buffer, true, {
    relative = "editor",
    row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " AI Commit Model Activity ",
    title_pos = "center",
  })
  vim.api.nvim_set_option_value("wrap", true, { win = window })
  vim.api.nvim_set_option_value("linebreak", true, { win = window })

  local started = vim.uv.hrtime()
  local state = { model = "selecting …", phase = "Preparing request", reasoning = "", response_bytes = 0 }
  local timer = vim.uv.new_timer()

  local function render()
    if not vim.api.nvim_buf_is_valid(buffer) then
      return
    end
    local elapsed = math.floor((vim.uv.hrtime() - started) / 1e9)
    local lines = {
      "AI Commit Planner",
      ("Model: %s"):format(state.model),
      ("Changes: %d files / %d units"):format(#snapshot.files, #snapshot.units),
      ("Status: %s (%ds)"):format(state.phase, elapsed),
      ("Response: %d bytes"):format(state.response_bytes),
      "",
      "Model activity",
      "──────────────",
    }
    local activity_lines = vim.split(state.reasoning, "\n", { plain = true })
    while #activity_lines > MAX_ACTIVITY_LINES do
      table.remove(activity_lines, 1)
    end
    if state.reasoning == "" then
      table.insert(lines, "Waiting for streamed model activity …")
    else
      vim.list_extend(lines, activity_lines)
    end
    vim.api.nvim_set_option_value("modifiable", true, { buf = buffer })
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = buffer })
    if vim.api.nvim_win_is_valid(window) then
      vim.api.nvim_win_set_cursor(window, { #lines, 0 })
    end
  end

  timer:start(0, 1000, vim.schedule_wrap(render))
  vim.keymap.set("n", "q", function()
    if vim.api.nvim_win_is_valid(window) then
      vim.api.nvim_win_close(window, true)
    end
  end, { buffer = buffer, desc = "Hide model activity" })

  local activity = {}
  function activity.set_model(model)
    state.model = model
    state.phase = "Generating commit plan"
    render()
  end
  function activity.set_phase(phase)
    state.phase = phase
    render()
  end
  function activity.append(kind, text)
    if kind == "content" then
      state.response_bytes = state.response_bytes + #text
      state.phase = "Receiving structured commit plan"
    else
      state.phase = "Model is reasoning"
      state.reasoning = state.reasoning .. text
    end
    render()
  end
  function activity.close()
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    if vim.api.nvim_buf_is_valid(buffer) then
      vim.api.nvim_buf_delete(buffer, { force = true })
    end
  end
  function activity.fail(message)
    state.phase = "Failed: " .. message
    render()
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
  end
  render()
  return activity
end

local function git(args, options)
  local command = { "git" }
  vim.list_extend(command, args)
  return vim.system(command, vim.tbl_extend("force", { text = true }, options or {})):wait()
end

local function nul_items(value)
  return vim.split(value or "", "\0", { plain = true, trimempty = true })
end

local function split_hunks(patch)
  local header, hunks, current = {}, {}, nil
  for _, line in ipairs(vim.split(patch, "\n", { plain = true })) do
    if line:match("^@@ ") then
      current = { line }
      table.insert(hunks, current)
    elseif current then
      table.insert(current, line)
    else
      table.insert(header, line)
    end
  end
  if #hunks == 0 then
    return {}
  end

  local header_text = table.concat(header, "\n")
  local patches = {}
  for _, hunk in ipairs(hunks) do
    table.insert(patches, header_text .. "\n" .. table.concat(hunk, "\n") .. "\n")
  end
  return patches
end

local function whitespace_only_patch(patch)
  local removed, added = {}, {}
  for line in (patch or ""):gmatch("[^\n]+") do
    if line:sub(1, 1) == "-" and line:sub(1, 3) ~= "---" then
      table.insert(removed, (line:sub(2):gsub("%s", "")))
    elseif line:sub(1, 1) == "+" and line:sub(1, 3) ~= "+++" then
      table.insert(added, (line:sub(2):gsub("%s", "")))
    end
  end
  return #removed > 0 and #added > 0 and vim.deep_equal(removed, added)
end

local function collect_snapshot()
  local root = git({ "rev-parse", "--show-toplevel" })
  if root.code ~= 0 then
    return nil, "Not inside a Git repository"
  end
  local repo_root = vim.trim(root.stdout)
  local git_dir = git({ "-C", repo_root, "rev-parse", "--absolute-git-dir" })
  if git_dir.code ~= 0 then
    return nil, "Could not locate Git metadata"
  end
  for _, marker in ipairs({
    "MERGE_HEAD",
    "CHERRY_PICK_HEAD",
    "REVERT_HEAD",
    "rebase-merge",
    "rebase-apply",
    "sequencer",
  }) do
    if vim.uv.fs_stat(vim.fs.joinpath(vim.trim(git_dir.stdout), marker)) then
      return nil, "Finish the in-progress Git operation before planning commits"
    end
  end
  local head = git({ "-C", repo_root, "rev-parse", "--verify", "HEAD" })
  if head.code ~= 0 then
    return nil, "Create the initial commit before using the AI commit planner"
  end

  local tracked = git({ "-C", repo_root, "diff", "--name-only", "--no-renames", "-z", "HEAD" })
  local untracked = git({ "-C", repo_root, "ls-files", "--others", "--exclude-standard", "-z" })
  local unmerged = git({ "-C", repo_root, "diff", "--name-only", "--diff-filter=U", "-z" })
  if tracked.code ~= 0 or untracked.code ~= 0 or unmerged.code ~= 0 then
    return nil, vim.trim(tracked.stderr ~= "" and tracked.stderr or untracked.stderr or "Could not read Git changes")
  end
  if unmerged.stdout ~= "" then
    return nil, "Resolve merge conflicts before planning commits"
  end

  local untracked_paths, untracked_set = nul_items(untracked.stdout), {}
  for _, path in ipairs(untracked_paths) do
    untracked_set[path] = true
  end
  local seen, files = {}, {}
  for _, path in ipairs(vim.list_extend(nul_items(tracked.stdout), untracked_paths)) do
    if not seen[path] then
      seen[path] = true
      table.insert(files, path)
    end
  end
  table.sort(files)
  if #files == 0 then
    return nil, "No changes to commit"
  end

  local units, context_parts, file_context_parts = {}, {}, {}
  local file_context_bytes = 0
  local function add_unit(path, kind, patch)
    local unit = {
      id = ("U%03d"):format(#units + 1),
      path = path,
      kind = kind,
      patch = patch,
      whitespace_only = whitespace_only_patch(patch),
    }
    table.insert(units, unit)
    local classification = unit.whitespace_only and kind .. ", whitespace-only" or kind
    table.insert(context_parts, ("[%s | %s | %s]\n%s"):format(unit.id, classification, path, patch))
  end

  for _, path in ipairs(files) do
    local result
    if untracked_set[path] then
      result = git({ "-C", repo_root, "diff", "--no-index", "--binary", "--unified=3", "--", "/dev/null", path })
    else
      result = git({
        "-C",
        repo_root,
        "diff",
        "--no-ext-diff",
        "--no-renames",
        "--binary",
        "--unified=3",
        "HEAD",
        "--",
        path,
      })
    end
    if result.code ~= 0 and not (untracked_set[path] and result.code == 1) then
      return nil, vim.trim(result.stderr or ("Could not read changes for " .. path))
    end

    local patch = result.stdout or ""
    local whole_file = untracked_set[path]
      or patch:find("\nnew file mode ", 1, true)
      or patch:find("\ndeleted file mode ", 1, true)
      or patch:find("\nold mode ", 1, true)
      or patch:find("\nGIT binary patch", 1, true)
      or patch:find("\nBinary files ", 1, true)
    local hunks = not whole_file and split_hunks(patch) or {}
    if #hunks == 0 then
      add_unit(path, "file", patch)
    else
      for _, hunk_patch in ipairs(hunks) do
        add_unit(path, "hunk", hunk_patch)
      end
    end
    if not untracked_set[path] and file_context_bytes < MAX_FILE_CONTEXT_BYTES then
      local file = io.open(vim.fs.joinpath(repo_root, path), "rb")
      local content = file and file:read(MAX_SINGLE_FILE_BYTES + 1) or nil
      if file then
        file:close()
      end
      if content and not content:find("\0", 1, true) then
        if #content > MAX_SINGLE_FILE_BYTES then
          content = content:sub(1, MAX_SINGLE_FILE_BYTES) .. "\n[file truncated]"
        end
        local remaining = MAX_FILE_CONTEXT_BYTES - file_context_bytes
        if #content <= remaining then
          local rendered = ("### %s\n%s"):format(path, content)
          table.insert(file_context_parts, rendered)
          file_context_bytes = file_context_bytes + #rendered
        end
      end
    end
  end

  local full_context = table.concat(context_parts, "\n\n")
  local index = git({ "-C", repo_root, "diff", "--cached", "--binary", "--no-ext-diff" })
  if index.code ~= 0 then
    return nil, "Could not read Git index"
  end
  local identity = vim.fn.sha256(
    repo_root
      .. "\0"
      .. head.stdout
      .. "\0"
      .. index.stdout
      .. "\0"
      .. table.concat(files, "\0")
      .. "\0"
      .. full_context
  )
  local truncated = #full_context > MAX_CONTEXT_BYTES
  local context = full_context
  if truncated then
    local catalog = {}
    for _, unit in ipairs(units) do
      local classification = unit.whitespace_only and unit.kind .. ", whitespace-only" or unit.kind
      table.insert(catalog, ("%s | %s | %s"):format(unit.id, classification, unit.path))
    end
    context = context:sub(1, MAX_CONTEXT_BYTES)
      .. "\n\n[patches truncated]\n\nComplete unit catalog:\n"
      .. table.concat(catalog, "\n")
  end
  return {
    root = repo_root,
    files = files,
    units = units,
    context = context,
    file_context = table.concat(file_context_parts, "\n\n"),
    identity = identity,
    truncated = truncated,
  }
end

local function model_size(model)
  for _, field in ipairs({ "size_gb", "model_size_gb", "memory_gb", "estimated_memory_gb" }) do
    if type(model[field]) == "number" then
      return model[field] * 1024 ^ 3
    end
  end
  local fields = { "size_bytes", "model_size_bytes", "memory_bytes", "estimated_memory_bytes", "model_size", "size" }
  for _, field in ipairs(fields) do
    local value = model[field]
    if type(value) == "number" then
      return value
    end
    if type(value) == "string" then
      local number, unit = value:match("([%d.]+)%s*([GMK]?)B")
      if number then
        local multiplier = unit == "G" and 1024 ^ 3 or unit == "M" and 1024 ^ 2 or unit == "K" and 1024 or 1
        return tonumber(number) * multiplier
      end
    end
  end

  local id = non_empty_string(model.id) or non_empty_string(model.model_alias) or ""
  local largest = 0
  for parameters in id:gmatch("([%d.]+)[Bb]") do
    largest = math.max(largest, (tonumber(parameters) or 0) * 1024 ^ 3)
  end
  return largest
end

local function is_loaded(model)
  if model.loaded == true or model.is_loaded == true or model.engine_loaded == true then
    return true
  end
  local state = non_empty_string(model.status) or non_empty_string(model.state) or ""
  state = state:lower()
  return vim.tbl_contains({ "loaded", "ready", "running", "idle", "active", "busy", "prefilling", "generating" }, state)
end

local function largest_loaded_model(response_models)
  local models = {}
  for _, model in ipairs(response_models) do
    local id = type(model) == "table" and (non_empty_string(model.model_alias) or non_empty_string(model.id)) or nil
    local model_type = type(model) == "table" and non_empty_string(model.model_type) or nil
    if id and id ~= "MarkItDown" and model_type ~= "embedding" and model_type ~= "reranker" and is_loaded(model) then
      table.insert(models, { id = id, size = model_size(model) })
    end
  end
  table.sort(models, function(left, right)
    if left.size == right.size then
      return left.id < right.id
    end
    return left.size > right.size
  end)
  return models[1] and models[1].id or nil
end

local function select_model(config, callback)
  if config.model then
    callback(config.model)
    return
  end

  request(config, "/models/status", nil, function(response, err)
    local response_models = response and type(response.models) == "table" and response.models or {}
    local model = largest_loaded_model(response_models)
    if not model then
      callback(nil, err or "No loaded oMLX language model is available; load one and try again")
      return
    end
    vim.notify("Using largest loaded oMLX model: " .. model)
    callback(model)
  end)
end

local function extract_content(response)
  local choices = response and type(response.choices) == "table" and response.choices or {}
  local first = type(choices[1]) == "table" and choices[1] or {}
  local message = type(first.message) == "table" and first.message or {}
  return non_empty_string(message.content)
end

local function parse_plan(content, units)
  if type(content) ~= "string" then
    return nil, "Expected a JSON plan"
  end
  content = content:gsub("^```[%w_-]*%s*", ""):gsub("%s*```%s*$", "")
  local ok, value = pcall(vim.json.decode, content)
  if not ok or type(value) ~= "table" or type(value.commits) ~= "table" or #value.commits == 0 then
    return nil, "The model did not return a valid commit plan"
  end

  local expected, assigned = {}, {}
  for _, unit in ipairs(units) do
    expected[unit.id] = unit
  end
  for index, commit in ipairs(value.commits) do
    if type(commit) ~= "table" then
      return nil, "Commit " .. index .. " is invalid"
    end
    commit.type = non_empty_string(commit.type)
    commit.scope = non_empty_string(commit.scope)
    commit.description = non_empty_string(commit.description)
    commit.body = non_empty_string(commit.body)
    commit.breaking_change = non_empty_string(commit.breaking_change)
    if not commit.type or not commit.type:match("^[a-z][a-z0-9-]*$") then
      return nil, "Commit " .. index .. " has an invalid type"
    end
    if commit.scope and not commit.scope:match("^[a-z0-9][a-z0-9-]*$") then
      return nil, "Commit " .. index .. " has an invalid scope"
    end
    if not commit.description or type(commit.units) ~= "table" or #commit.units == 0 then
      return nil, "Commit " .. index .. " needs a description and units"
    end
    if commit.description:find("[\r\n]") then
      return nil, "Commit " .. index .. " has a multi-line description"
    end
    local header = commit.type
      .. (commit.scope and "(" .. commit.scope .. ")" or "")
      .. (commit.breaking_change and "!" or "")
      .. ": "
      .. commit.description
    if #header > MAX_COMMIT_HEADER_BYTES then
      return nil, ("Commit %d header exceeds %d bytes"):format(index, MAX_COMMIT_HEADER_BYTES)
    end
    if
      commit.description:match("U%d%d%d")
      or (commit.body and commit.body:match("U%d%d%d"))
      or (commit.breaking_change and commit.breaking_change:match("U%d%d%d"))
    then
      return nil, "Commit " .. index .. " leaks internal unit IDs into its message"
    end
    commit.resolved_units = {}
    for _, unit_id in ipairs(commit.units) do
      if not expected[unit_id] then
        return nil, "Commit " .. index .. " references an unknown unit: " .. tostring(unit_id)
      end
      if assigned[unit_id] then
        return nil, "Unit assigned more than once: " .. unit_id
      end
      assigned[unit_id] = true
      table.insert(commit.resolved_units, expected[unit_id])
    end
    local whitespace_units = 0
    for _, unit in ipairs(commit.resolved_units) do
      whitespace_units = whitespace_units + (unit.whitespace_only and 1 or 0)
    end
    if whitespace_units > 0 and whitespace_units < #commit.resolved_units then
      return nil, "Commit " .. index .. " mixes whitespace-only and functional changes"
    end
    if whitespace_units > 0 and commit.type ~= "style" then
      return nil, "Commit " .. index .. " must use type style for whitespace-only changes"
    end
  end
  for _, unit in ipairs(units) do
    if not assigned[unit.id] then
      return nil, "Unit is missing from the plan: " .. unit.id
    end
  end
  return value.commits
end

local function commit_message(commit)
  local header = commit.type .. (commit.scope and "(" .. commit.scope .. ")" or "")
  if commit.breaking_change then
    header = header .. "!"
  end
  local parts = { header .. ": " .. commit.description }
  if commit.body then
    table.insert(parts, commit.body)
  end
  if commit.breaking_change then
    table.insert(parts, "BREAKING CHANGE: " .. commit.breaking_change)
  end
  return table.concat(parts, "\n\n")
end

local function stage_unit(unit, root)
  if unit.kind == "hunk" then
    return git({ "-C", root, "apply", "--cached", "--unidiff-zero", "-" }, { stdin = unit.patch })
  end
  return git({ "-C", root, "add", "--all", "--", unit.path })
end

local function execute_plan(commits, snapshot, buffer, on_failure)
  local current, err = collect_snapshot()
  if not current or current.identity ~= snapshot.identity then
    vim.notify(err or "Changes were modified after planning; generate a new plan", vim.log.levels.ERROR)
    on_failure()
    return
  end

  local reset = git({ "-C", snapshot.root, "restore", "--staged", ":/" })
  if reset.code ~= 0 then
    vim.notify(vim.trim(reset.stderr), vim.log.levels.ERROR)
    on_failure()
    return
  end

  local function create(index)
    if index > #commits then
      vim.notify(("Created %d Conventional Commit%s"):format(#commits, #commits == 1 and "" or "s"))
      if vim.api.nvim_buf_is_valid(buffer) then
        vim.api.nvim_buf_delete(buffer, { force = true })
      end
      return
    end

    local commit = commits[index]
    for _, unit in ipairs(commit.resolved_units) do
      local staged = stage_unit(unit, snapshot.root)
      if staged.code ~= 0 then
        vim.notify(
          ("Could not stage %s for commit %d: %s"):format(unit.id, index, vim.trim(staged.stderr)),
          vim.log.levels.ERROR
        )
        on_failure()
        return
      end
    end

    vim.system(
      { "git", "-C", snapshot.root, "commit", "--file", "-" },
      { text = true, stdin = commit_message(commit) },
      function(result)
        vim.schedule(function()
          if result.code ~= 0 then
            vim.notify(("Commit %d failed: %s"):format(index, vim.trim(result.stderr)), vim.log.levels.ERROR)
            on_failure()
            return
          end
          vim.notify(("Created %d/%d: %s"):format(index, #commits, commit_message(commit):match("[^\n]+")))
          create(index + 1)
        end)
      end
    )
  end

  create(1)
end

local function merge_messages(content, commits, units)
  local ok, response = pcall(vim.json.decode, content)
  if not ok or type(response) ~= "table" or type(response.messages) ~= "table" or #response.messages ~= #commits then
    return nil, "Expected one message per existing commit group"
  end
  local candidate, seen = vim.deepcopy(commits), {}
  for _, message in ipairs(response.messages) do
    local group = type(message) == "table" and message.group or nil
    if type(group) ~= "number" or group % 1 ~= 0 or not candidate[group] or seen[group] then
      return nil, "Invalid or duplicate commit group in generated messages"
    end
    seen[group] = true
    for _, field in ipairs({ "type", "scope", "description", "body", "breaking_change" }) do
      candidate[group][field] = message[field]
    end
  end
  -- Unit assignments always come from the reviewed plan, never the response.
  return parse_plan(vim.json.encode({ commits = candidate }), units)
end

local function show_plan(commits, snapshot, config, model)
  local line_units = {}
  local lines
  local function render_lines()
    line_units = {}
    lines = {
      "AI Conventional Commit Plan",
      ("%d commit%s for %d unit%s across %d file%s"):format(
        #commits,
        #commits == 1 and "" or "s",
        #snapshot.units,
        #snapshot.units == 1 and "" or "s",
        #snapshot.files,
        #snapshot.files == 1 and "" or "s"
      ),
      "",
    }
    for index, commit in ipairs(commits) do
      table.insert(lines, ("%d. %s"):format(index, commit_message(commit):match("[^\n]+")))
      if commit.body then
        for _, line in ipairs(vim.split(commit.body, "\n", { plain = true })) do
          table.insert(lines, "   " .. line)
        end
      end
      for _, unit in ipairs(commit.resolved_units) do
        local kind = unit.whitespace_only and unit.kind .. ", whitespace-only" or unit.kind
        table.insert(lines, ("   - %s [%s] %s"):format(unit.id, kind, unit.path))
        line_units[#lines] = unit
      end
      table.insert(lines, "")
    end
  end
  render_lines()

  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buffer, "AI Conventional Commit Plan " .. buffer)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buffer })
  local preview_buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(preview_buffer, "AI Commit Unit Preview " .. preview_buffer)

  local total_width = math.max(3, vim.o.columns - 6)
  local gap = total_width > 20 and 2 or 1
  local plan_width = math.max(1, math.floor((total_width - gap) * 0.38))
  local preview_width = math.max(1, total_width - gap - plan_width)
  total_width = plan_width + gap + preview_width
  local height = math.max(1, vim.o.lines - 6)
  local row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1)
  local column = math.max(0, math.floor((vim.o.columns - total_width) / 2))
  local plan_window = vim.api.nvim_open_win(buffer, true, {
    relative = "editor",
    row = row,
    col = column,
    width = plan_width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " AI Commit Plan ",
    title_pos = "center",
  })
  local preview_window = vim.api.nvim_open_win(preview_buffer, false, {
    relative = "editor",
    row = row,
    col = column + plan_width + gap,
    width = preview_width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Hunk Preview ",
    title_pos = "center",
  })
  vim.api.nvim_set_option_value("filetype", "diff", { buf = preview_buffer })
  vim.api.nvim_set_option_value("wrap", false, { win = preview_window })
  vim.api.nvim_set_option_value("wrap", true, { win = plan_window })
  vim.api.nvim_set_option_value("linebreak", true, { win = plan_window })

  local function unit_near_cursor()
    local line = vim.api.nvim_win_get_cursor(plan_window)[1]
    if vim.api.nvim_get_option_value("modifiable", { buf = buffer }) then
      local text = vim.api.nvim_buf_get_lines(buffer, line - 1, line, false)[1] or ""
      for _, unit in ipairs(snapshot.units) do
        if text:find('"' .. unit.id .. '"', 1, true) then
          return unit
        end
      end
      return
    end
    if line_units[line] then
      return line_units[line]
    end
    for candidate = line + 1, #lines do
      if line_units[candidate] then
        return line_units[candidate]
      end
    end
    for candidate = line - 1, 1, -1 do
      if line_units[candidate] then
        return line_units[candidate]
      end
    end
  end

  local function update_preview()
    if not vim.api.nvim_buf_is_valid(preview_buffer) then
      return
    end
    local unit = unit_near_cursor()
    if not unit then
      return
    end
    local kind = unit.whitespace_only and unit.kind .. ", whitespace-only" or unit.kind
    local preview = ("# %s [%s] %s\n\n%s"):format(unit.id, kind, unit.path, unit.patch)
    vim.api.nvim_set_option_value("modifiable", true, { buf = preview_buffer })
    vim.api.nvim_buf_set_lines(preview_buffer, 0, -1, false, vim.split(preview, "\n", { plain = true }))
    vim.api.nvim_set_option_value("modifiable", false, { buf = preview_buffer })
  end

  vim.api.nvim_create_autocmd("CursorMoved", { buffer = buffer, callback = update_preview })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buffer,
    once = true,
    callback = function()
      session_active = false
      if vim.api.nvim_win_is_valid(preview_window) and #vim.api.nvim_list_wins() > 1 then
        vim.api.nvim_win_close(preview_window, true)
      end
      if vim.api.nvim_buf_is_valid(preview_buffer) then
        vim.api.nvim_buf_delete(preview_buffer, { force = true })
      end
    end,
  })
  update_preview()

  local editing, regenerating = false, false
  local confirming, executing = false, false
  local edit_plan
  local function review_plan()
    editing = false
    render_lines()
    vim.api.nvim_set_option_value("modifiable", true, { buf = buffer })
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = buffer })
    vim.api.nvim_set_option_value("filetype", "", { buf = buffer })
    vim.keymap.set("n", "e", edit_plan, { buffer = buffer, desc = "Edit messages and hunk assignments" })
    update_preview()
  end
  edit_plan = function()
    if editing or regenerating or confirming or executing then
      return
    end
    local editable = {}
    for _, commit in ipairs(commits) do
      table.insert(editable, {
        type = commit.type,
        scope = commit.scope,
        description = commit.description,
        body = commit.body,
        breaking_change = commit.breaking_change,
        units = commit.units,
      })
    end
    editing = true
    vim.keymap.del("n", "e", { buffer = buffer })
    vim.api.nvim_set_option_value("modifiable", true, { buf = buffer })
    lines = { '{ "commits": [' }
    for index, commit in ipairs(editable) do
      table.insert(lines, "  " .. vim.json.encode(commit) .. (index < #editable and "," or ""))
    end
    table.insert(lines, "] }")
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
    vim.api.nvim_set_option_value("filetype", "json", { buf = buffer })
  end

  local function selected_commit()
    local row = vim.api.nvim_win_get_cursor(plan_window)[1]
    for line = math.min(row, #lines), 1, -1 do
      local index = lines[line]:match("^(%d+)%. ")
      if index then
        return tonumber(index)
      end
    end
    return 1
  end
  local function edit_message()
    if editing or confirming or executing or regenerating then
      return
    end
    local index = selected_commit()
    vim.ui.select({ "type", "scope", "description", "body", "breaking_change" }, {
      prompt = "Edit commit message field",
    }, function(field)
      if not field or not vim.api.nvim_buf_is_valid(buffer) then
        return
      end
      vim.ui.input({ prompt = field .. ": ", default = commits[index][field] or "" }, function(value)
        if value == nil or not vim.api.nvim_buf_is_valid(buffer) then
          return
        end
        local candidate = vim.deepcopy(commits)
        candidate[index][field] = value ~= "" and value or nil
        local parsed, err = parse_plan(vim.json.encode({ commits = candidate }), snapshot.units)
        if not parsed then
          vim.notify(err, vim.log.levels.ERROR)
          return
        end
        commits = parsed
        review_plan()
      end)
    end)
  end
  local function move_unit()
    if editing or confirming or executing or regenerating then
      return
    end
    local row = vim.api.nvim_win_get_cursor(plan_window)[1]
    local unit = line_units[row]
    if not unit then
      vim.notify("Select a hunk or file row first", vim.log.levels.INFO)
      return
    end
    local source = selected_commit()
    local destinations = {}
    for index, commit in ipairs(commits) do
      if index ~= source then
        table.insert(destinations, { index = index, label = commit_message(commit):match("[^\n]+") })
      end
    end
    table.insert(destinations, { index = #commits + 1, label = "New commit" })
    vim.ui.select(destinations, {
      prompt = "Move " .. unit.id .. " to commit",
      format_item = function(item)
        return item.index .. ". " .. item.label
      end,
    }, function(target)
      if not target or not vim.api.nvim_buf_is_valid(buffer) then
        return
      end
      local function apply(description)
        local candidate = vim.deepcopy(commits)
        if target.index > #candidate then
          table.insert(candidate, { type = "chore", description = description, units = {} })
        end
        for position, id in ipairs(candidate[source].units) do
          if id == unit.id then
            table.remove(candidate[source].units, position)
            break
          end
        end
        table.insert(candidate[target.index].units, unit.id)
        if #candidate[source].units == 0 then
          table.remove(candidate, source)
        end
        local parsed, err = parse_plan(vim.json.encode({ commits = candidate }), snapshot.units)
        if not parsed then
          vim.notify(err, vim.log.levels.ERROR)
          return
        end
        commits = parsed
        review_plan()
      end
      if target.index > #commits then
        vim.ui.input({ prompt = "New commit description: " }, function(value)
          if value and vim.api.nvim_buf_is_valid(buffer) then
            apply(value)
          end
        end)
      else
        apply()
      end
    end)
  end
  local function regenerate_messages()
    if editing or confirming or executing or regenerating then
      return
    end
    if not config or not model then
      vim.notify("No generation backend attached to this plan", vim.log.levels.ERROR)
      return
    end
    local groups = {}
    for index, commit in ipairs(commits) do
      local changes = {}
      for _, unit in ipairs(commit.resolved_units) do
        table.insert(changes, { path = unit.path, patch = unit.patch })
      end
      table.insert(groups, { group = index, changes = changes })
    end
    local payload = vim.json.encode({ groups = groups })
    if #payload > MAX_CONTEXT_BYTES + MAX_FILE_CONTEXT_BYTES then
      vim.notify("Groups exceed the regeneration context limit", vim.log.levels.ERROR)
      return
    end
    regenerating = true
    vim.notify("Regenerating messages for fixed commit groups")
    stream_request(config, "/chat/completions", {
      model = model,
      temperature = 0.1,
      max_tokens = 9000,
      messages = {
        {
          role = "system",
          content = 'Write one Conventional Commit message per fixed group. Do not regroup changes. Use lowercase type, optional short lowercase scope, single-line imperative description, header at most 72 bytes. Whitespace-only groups require type style. Never mention internal IDs. Return only JSON: {"messages":[{"group":1,"type":"fix","scope":null,"description":"summary","body":null,"breaking_change":null}]}. Include each group exactly once. Describe only supplied changes.',
        },
        { role = "user", content = payload },
      },
    }, function() end, function(content, err)
      regenerating = false
      if not vim.api.nvim_buf_is_valid(buffer) then
        return
      end
      local updated, validation_error
      if content then
        updated, validation_error = merge_messages(content, commits, snapshot.units)
      end
      if not updated then
        vim.notify(err or validation_error or "No messages returned; plan retained", vim.log.levels.ERROR)
        return
      end
      commits = updated
      review_plan()
      vim.notify("Messages updated; review before creating commits")
    end)
  end
  local function confirm()
    if confirming or executing or regenerating then
      vim.notify("The commit plan is already being applied", vim.log.levels.WARN)
      return
    end
    if editing then
      local parsed, err =
        parse_plan(table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n"), snapshot.units)
      if not parsed then
        vim.notify(err, vim.log.levels.ERROR)
        return
      end
      commits = parsed
      review_plan()
      return
    end
    confirming = true
    vim.ui.select({ "Create commits", "Cancel" }, { prompt = "Apply this commit plan?" }, function(choice)
      confirming = false
      if choice == "Create commits" then
        executing = true
        execute_plan(commits, snapshot, buffer, function()
          executing = false
        end)
      end
    end)
  end
  local function close_plan()
    if executing then
      vim.notify("Wait for the current commit operation to finish", vim.log.levels.WARN)
      return
    end
    if editing then
      review_plan()
      return
    end
    if vim.api.nvim_buf_is_valid(buffer) then
      vim.api.nvim_buf_delete(buffer, { force = true })
    end
  end
  vim.keymap.set("n", "<C-s>", confirm, { buffer = buffer, desc = "Create planned commits" })
  vim.keymap.set("n", "e", edit_plan, { buffer = buffer, desc = "Edit messages and hunk assignments" })
  vim.keymap.set("n", "m", edit_message, { buffer = buffer, desc = "Edit commit message" })
  vim.keymap.set("n", "M", move_unit, { buffer = buffer, desc = "Move hunk to commit" })
  vim.keymap.set("n", "r", regenerate_messages, { buffer = buffer, desc = "Regenerate messages for fixed groups" })
  vim.keymap.set("n", "<leader>gC", confirm, { buffer = buffer, desc = "Create planned commits" })
  vim.keymap.set("n", "<Tab>", function()
    vim.api.nvim_set_current_win(preview_window)
  end, { buffer = buffer, desc = "Focus hunk preview" })
  vim.keymap.set("n", "q", close_plan, { buffer = buffer, desc = "Close commit plan" })
  vim.keymap.set("n", "<C-s>", confirm, { buffer = preview_buffer, desc = "Create planned commits" })
  vim.keymap.set("n", "<leader>gC", confirm, { buffer = preview_buffer, desc = "Create planned commits" })
  vim.keymap.set("n", "<Tab>", function()
    vim.api.nvim_set_current_win(plan_window)
  end, { buffer = preview_buffer, desc = "Focus commit plan" })
  vim.keymap.set("n", "q", close_plan, { buffer = preview_buffer, desc = "Close commit plan" })
  vim.api.nvim_buf_create_user_command(buffer, "AICommitConfirm", confirm, { desc = "Create planned commits" })
  vim.api.nvim_buf_create_user_command(buffer, "AICommitDiscard", function()
    if editing then
      review_plan()
    end
  end, { desc = "Discard plan edits" })
  vim.notify(
    "Edit messages and unit assignments with e; Tab switches windows. Confirm with Ctrl-S or :AICommitConfirm."
  )
end

local function generate_plan(config, model, snapshot, activity, attempt, repair_context)
  attempt = attempt or 1
  local user_content = "Changed files:\n"
    .. table.concat(snapshot.files, "\n")
    .. "\n\nChange units and their original patches:\n"
    .. snapshot.context
    .. "\n\nCurrent contents of changed tracked text files (supporting context only; plan units from the patches):\n"
    .. (snapshot.file_context ~= "" and snapshot.file_context or "[no additional file context available]")
  if repair_context then
    user_content = user_content
      .. "\n\nThe previous plan was invalid. Repair it and return the complete JSON plan again.\n"
      .. repair_context
  end

  stream_request(
    config,
    "/chat/completions",
    {
      model = model,
      tool_choice = "none",
      temperature = 0.1,
      max_tokens = math.min(9000, 3000 * attempt),
      messages = {
        {
          role = "system",
          content = table.concat({
            "Plan one or more atomic Conventional Commits 1.0.0 for a Git working tree.",
            "Group change units by one coherent purpose and split unrelated purposes into separate commits.",
            "Assign every provided unit ID exactly once and never invent IDs.",
            "A unit must occur in exactly one commit; distinct hunk units from the same file may belong to different commits.",
            "Units marked file are indivisible, while units marked hunk are independently stageable original Git hunks.",
            "Put units marked whitespace-only in a separate style commit and never mix them into a functional commit.",
            "Use feat for a new user-facing feature and fix for a bug fix.",
            "Use other precise lowercase types when appropriate, including build, chore, ci, docs, style, refactor, perf, test, and revert.",
            "Use refactor only for code changes that neither fix behavior nor add behavior.",
            "The optional scope is one short codebase component, never a filename or list of paths.",
            "Set breaking_change only for an actual incompatible change.",
            "Bodies should explain behavior and intent rather than list files mechanically.",
            "Unit IDs and file paths are internal planning data; never mention them in descriptions, bodies, or footers.",
            "Return only JSON with this shape:",
            '{"commits":[{"type":"fix","scope":"nvim","description":"imperative summary","body":null,"breaking_change":null,"units":["U001"]}]}',
          }, " "),
        },
        {
          role = "user",
          content = user_content,
        },
      },
    },
    activity.append,
    function(content, err)
      if not content then
        if not err and attempt < 3 then
          activity.set_phase(("Reasoning ended without a plan; retrying (%d/2)"):format(attempt))
          vim.notify(
            "oMLX returned reasoning but no final plan; retrying with a larger output budget …",
            vim.log.levels.WARN
          )
          generate_plan(
            config,
            model,
            snapshot,
            activity,
            attempt + 1,
            "The previous response contained no final JSON. Keep reasoning concise and emit the complete JSON plan."
          )
          return
        end
        session_active = false
        local message = err or "oMLX generated reasoning but no final commit plan after two retries"
        activity.fail(message)
        vim.notify(message, vim.log.levels.ERROR)
        return
      end
      local commits, parse_err = parse_plan(content, snapshot.units)
      if not commits then
        if attempt < 3 then
          activity.set_phase(("Repairing invalid plan (%d/2)"):format(attempt))
          vim.notify(("Invalid commit plan; asking oMLX to repair it (%d/2) …"):format(attempt), vim.log.levels.WARN)
          local previous = #content > 10000 and content:sub(1, 10000) .. "\n[response truncated]" or content
          generate_plan(
            config,
            model,
            snapshot,
            activity,
            attempt + 1,
            "Validation error: " .. parse_err .. "\nPrevious JSON:\n" .. previous
          )
        else
          session_active = false
          activity.fail("Could not produce a valid plan: " .. parse_err)
          vim.notify(
            "oMLX could not produce a valid commit plan after two repairs: " .. parse_err,
            vim.log.levels.ERROR
          )
        end
        return
      end
      activity.close()
      show_plan(commits, snapshot, config, model)
    end
  )
end

function M.create()
  if session_active then
    vim.notify("An AI commit plan is already running or open", vim.log.levels.WARN)
    return
  end
  session_active = true
  local ok, config = pcall(connection_config)
  if not ok then
    session_active = false
    vim.notify("Could not resolve AI connection settings", vim.log.levels.ERROR)
    return
  end
  for _, executable in ipairs({ "git", "curl" }) do
    if vim.fn.executable(executable) ~= 1 then
      session_active = false
      vim.notify(executable .. " is required for the AI commit planner", vim.log.levels.ERROR)
      return
    end
  end
  local snapshot, err = collect_snapshot()
  if not snapshot then
    session_active = false
    vim.notify(err, vim.log.levels.WARN)
    return
  end
  if snapshot.truncated then
    vim.notify("The diff is large; oMLX receives the first 50 KB plus the complete file list", vim.log.levels.WARN)
  end

  if
    config.endpoint == ""
    or (
      (config.provider == "openai_compatible" or config.provider == "anthropic") and not non_empty_string(config.model)
    )
  then
    session_active = false
    vim.notify("Configure a model and, for HTTP providers, an endpoint", vim.log.levels.ERROR)
    return
  end
  local activity = show_activity(snapshot)
  select_model(config, function(model, model_error)
    if not model then
      session_active = false
      activity.fail(model_error)
      vim.notify(model_error, vim.log.levels.ERROR)
      return
    end
    activity.set_model(model)
    generate_plan(config, model, snapshot, activity)
  end)
end

if vim.env.NVIM_AI_COMMIT_TEST == "1" then
  M._test = {
    collect_snapshot = collect_snapshot,
    is_loaded = is_loaded,
    largest_loaded_model = largest_loaded_model,
    model_size = model_size,
    parse_plan = parse_plan,
    stream_decoder = stream_decoder,
    curl_timeout_args = curl_timeout_args,
    whitespace_only_patch = whitespace_only_patch,
    show_plan = show_plan,
    stage_unit = stage_unit,
    connection_config = connection_config,
    merge_messages = merge_messages,
    stream_request = stream_request,
  }
end

return M
