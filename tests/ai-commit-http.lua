vim.opt.runtimepath:prepend(vim.fn.getcwd())
local helpers = require("ai_commitplan")._test
local server = vim.uv.new_tcp()
assert(server:bind("127.0.0.1", 0))
local address = server:getsockname()
local requests = 0
assert(server:listen(8, function(err)
  assert(not err, err)
  local client = vim.uv.new_tcp()
  assert(server:accept(client))
  local received, handled = "", false
  client:read_start(function(read_error, chunk)
    assert(not read_error, read_error)
    if not chunk or handled then
      return
    end
    received = received .. chunk
    local header_end = received:find("\r\n\r\n", 1, true)
    if not header_end then
      return
    end
    local headers = received:sub(1, header_end - 1)
    local size = tonumber(headers:lower():match("content%-length: (%d+)"))
    if not size or #received < header_end + 3 + size then
      return
    end
    handled = true
    assert(headers:find("POST /v1/messages HTTP/1.1", 1, true))
    assert(headers:find("x-api-key: fixture-secret", 1, true))
    assert(headers:find("anthropic-version: 2023-06-01", 1, true))
    local body = vim.json.decode(received:sub(header_end + 4))
    assert(body.system == "system" and body.messages[1].content == "diff")
    requests = requests + 1
    local response =
      vim.json.encode({ stop_reason = "end_turn", content = { { type = "text", text = "fixture reply" } } })
    client:write(
      "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
        .. #response
        .. "\r\nConnection: close\r\n\r\n"
        .. response,
      function()
        client:read_stop()
        client:close()
      end
    )
  end)
end))
local done, result, failure
helpers.stream_request(
  {
    provider = "anthropic",
    endpoint = "http://127.0.0.1:" .. address.port .. "/v1",
    api_key = "fixture-secret",
    connect_timeout = 5,
    idle_timeout = 5,
  },
  "/chat/completions",
  {
    model = "fixture",
    max_tokens = 100,
    messages = { { content = "system" }, { role = "user", content = "diff" } },
  },
  function() end,
  function(content, err)
    result, failure, done = content, err, true
  end
)
assert(
  vim.wait(10000, function()
    return done
  end),
  "request timed out"
)
server:close()
assert(result == "fixture reply", tostring(failure))
assert(requests == 1)
print("PASS: real curl -> local Anthropic HTTP fixture, auth and JSON body")
