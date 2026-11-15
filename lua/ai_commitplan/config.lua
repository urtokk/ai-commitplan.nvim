local M = {}
local options = {}

function M.setup(opts)
  opts = opts or {}
  assert(type(opts) == "table", "AICommit setup expects a table")
  assert(
    vim.tbl_contains({ "omlx", "ollama", "openai_compatible", "anthropic" }, opts.provider or "omlx"),
    "Unknown AICommit provider"
  )
  for _, field in ipairs({ "connect_timeout", "idle_timeout" }) do
    assert(opts[field] == nil or (type(opts[field]) == "number" and opts[field] > 0), field .. " must be positive")
  end
  assert(opts.api_key == nil or type(opts.api_key) == "string" or type(opts.api_key) == "function", "Invalid api_key")
  local function valid_model(model)
    return type(model) == "string" and model:match("%S") and not model:find("[\r\n]")
  end
  assert(opts.model == nil or valid_model(opts.model), "model must be a non-empty model ID")
  if opts.models ~= nil then
    assert(
      type(opts.models) == "table" and vim.islist(opts.models) and #opts.models > 0,
      "models must be a non-empty list"
    )
    for _, model in ipairs(opts.models) do
      assert(valid_model(model), "models must contain non-empty model IDs")
    end
  end
  assert(
    opts.endpoint == nil or (type(opts.endpoint) == "string" and opts.endpoint:match("^https?://")),
    "Expected an HTTP(S) endpoint"
  )
  options = vim.deepcopy(opts or {})
end

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
  local config = (
    options.provider == "openai_compatible"
    or options.provider == "anthropic"
    or options.provider == "ollama"
  )
      and { connect_timeout = 5, idle_timeout = 120 }
    or omlx_config()
  config = vim.tbl_extend("force", config, options)
  if config.provider == "ollama" then
    config.endpoint = config.endpoint or "http://127.0.0.1:11434/v1"
  end
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

M.resolve = connection_config
return M
