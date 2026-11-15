local repo_root = assert(vim.env.LOCAL_CONFIG_TEST_ROOT)
local work_dir = assert(vim.env.AI_COMMIT_TEST_REPO)
vim.opt.runtimepath:prepend(repo_root)
vim.cmd.cd(work_dir)

local helpers = assert(require("ai_commitplan")._test)
local planner = require("ai_commitplan")
planner.setup({
  provider = "openai_compatible",
  endpoint = "http://localhost:1234/v1/",
  model = "test",
  api_key = function()
    return "test-key"
  end,
})
local connection = helpers.connection_config()
assert(connection.endpoint == "http://localhost:1234/v1" and connection.model == "test")
assert(connection.api_key == "test-key" and connection.idle_timeout == 120)
planner.setup({})
assert(not pcall(planner.setup, { provider = "aichat" }))
assert(not pcall(planner.setup, { idle_timeout = -1 }))
planner.setup({ provider = "anthropic", model = "test", api_key = "bad\nheader" })
assert(not pcall(helpers.connection_config), "header injection accepted")
planner.setup({})
local snapshot, snapshot_error = helpers.collect_snapshot()
assert(snapshot, snapshot_error)
assert(#snapshot.units == 2, "expected two hunk units, got " .. #snapshot.units)
assert(snapshot.units[1].kind == "hunk" and snapshot.units[2].kind == "hunk")
local staged_probe = vim.system({ "git", "add", "tracked.txt" }, { text = true }):wait()
assert(staged_probe.code == 0)
local staged_snapshot = assert(helpers.collect_snapshot())
assert(snapshot.identity ~= staged_snapshot.identity, "staging changes were not detected")
assert(vim.system({ "git", "restore", "--staged", "tracked.txt" }):wait().code == 0)
assert(vim.system({ "git", "commit", "--allow-empty", "--no-gpg-sign", "-m", "test: move HEAD" }):wait().code == 0)
local moved_head = assert(helpers.collect_snapshot())
assert(snapshot.identity ~= moved_head.identity, "HEAD changes were not detected")
snapshot = moved_head
local marker = assert(io.open(work_dir .. "/.git/MERGE_HEAD", "w"))
marker:write("fixture")
marker:close()
assert(not helpers.collect_snapshot(), "in-progress merge accepted")
assert(os.remove(work_dir .. "/.git/MERGE_HEAD"))
assert(snapshot.file_context:find("### tracked.txt", 1, true), "current file contents were not included")
assert(snapshot.file_context:find("first-change", 1, true), "current changed content is missing")

local plan_json = vim.json.encode({
  commits = {
    { type = "docs", description = "first", units = { snapshot.units[1].id } },
    { type = "docs", description = "second", units = { snapshot.units[2].id } },
  },
})
local plan, plan_error = helpers.parse_plan(plan_json, snapshot.units)
assert(plan, plan_error)
local regenerated = helpers.merge_messages(
  vim.json.encode({
    messages = {
      { group = 2, type = "docs", description = "second refreshed", units = { "invented" } },
      { group = 1, type = "docs", description = "first refreshed", units = {} },
    },
  }),
  plan,
  snapshot.units
)
assert(regenerated and regenerated[1].description == "first refreshed")
assert(vim.deep_equal(regenerated[1].units, plan[1].units), "regeneration changed first group")
assert(vim.deep_equal(regenerated[2].units, plan[2].units), "regeneration changed second group")
assert(plan[1].description == "first", "regeneration mutated original plan")
assert(not helpers.merge_messages('{"messages":[]}', plan, snapshot.units))
assert(not helpers.merge_messages('{"messages":[{"group":1},{"group":1}]}', plan, snapshot.units))
local original_system = vim.system
local provider_reply
vim.system = function(command, opts, callback)
  assert(command[1] == "curl" and command[#command] == "http://localhost/v1/messages")
  assert(vim.tbl_contains(command, "anthropic-version: 2023-06-01"))
  local body = vim.json.decode(opts.stdin)
  assert(body.system == "system prompt" and body.messages[1].content == "private diff")
  assert(body.max_tokens == 200 and body.tool_choice == nil and body.stream == nil)
  callback({ code = 0, stdout = '{"stop_reason":"end_turn","content":[{"type":"text","text":"response"}]}' })
end
helpers.stream_request(
  { provider = "anthropic", endpoint = "http://localhost/v1", connect_timeout = 5, idle_timeout = 120 },
  "/chat/completions",
  {
    model = "client:model",
    max_tokens = 200,
    messages = { { content = "system prompt" }, { content = "private diff" } },
  },
  function() end,
  function(content)
    provider_reply = content
  end
)
assert(vim.wait(1000, function()
  return provider_reply ~= nil
end))
assert(provider_reply == "response")
vim.system = original_system
local invalid_plan = vim.json.encode({
  commits = {
    { type = "docs", description = "document U001", units = { snapshot.units[1].id } },
    { type = "docs", description = "second", units = { snapshot.units[2].id } },
  },
})
assert(not helpers.parse_plan(invalid_plan, snapshot.units), "unit ID leaked into a commit message")
local long_header_plan = vim.json.encode({
  commits = {
    { type = "docs", description = string.rep("x", 80), units = { snapshot.units[1].id } },
    { type = "docs", description = "second", units = { snapshot.units[2].id } },
  },
})
assert(not helpers.parse_plan(long_header_plan, snapshot.units), "oversized commit header was accepted")
assert(helpers.is_loaded({ status = "loaded" }))
assert(helpers.is_loaded({ status = "idle" }))
assert(not helpers.is_loaded({ status = "unloaded" }))
assert(helpers.model_size({ id = "Example-32B-4bit" }) > helpers.model_size({ id = "Example-8B-4bit" }))
assert(helpers.largest_loaded_model({
  { id = "Example-8B-4bit", status = "loaded", model_type = "llm" },
  { id = "Example-70B-4bit", status = "unloaded", model_type = "llm" },
  { id = "Example-32B-4bit", status = "loaded", model_type = "llm" },
}) == "Example-32B-4bit")

local timeout_args = helpers.curl_timeout_args({ connect_timeout = 5, idle_timeout = 120 })
assert(vim.tbl_contains(timeout_args, "--connect-timeout"), "curl connection timeout is missing")
assert(vim.tbl_contains(timeout_args, "--speed-time"), "curl inactivity timeout is missing")
assert(not vim.tbl_contains(timeout_args, "--max-time"), "curl still has an absolute timeout")
assert(helpers.whitespace_only_patch("--- a/a.yml\n+++ b/a.yml\n@@ -1 +1 @@\n-  key: value\n+    key: value\n"))
assert(not helpers.whitespace_only_patch("--- a/a.yml\n+++ b/a.yml\n@@ -1 +1 @@\n-  key: old\n+  key: new\n"))

local streamed = {}
local decoder = helpers.stream_decoder(function(kind, text)
  table.insert(streamed, kind .. ":" .. text)
end)
decoder.feed('data: {"choices":[{"delta":{"reasoning_content":"inspect "}}]}\n')
decoder.feed('data: {"choices":[{"delta":{"reasoning_content":"changes","content":"{\\"commits\\":"}}]}\n')
decoder.feed('data: {"choices":[{"delta":{"content":"[]}"}}]}\n\ndata: [DONE]\n')
local streamed_content, streamed_reasoning = decoder.finish()
assert(streamed_content == '{"commits":[]}', "streamed content was not assembled")
assert(streamed_reasoning == "inspect changes", "streamed reasoning was not assembled")
assert(#streamed == 4, "stream callbacks were not emitted")
local truncated = helpers.stream_decoder(function() end)
truncated.feed('data: {"choices":[{"delta":{"content":"{}"},"finish_reason":"length"}]}\n')
local _, _, truncation_error = truncated.finish()
assert(truncation_error, "truncated OpenAI response was accepted")

helpers.show_plan(
  plan,
  snapshot,
  { provider = "anthropic", endpoint = "http://localhost/v1", connect_timeout = 5, idle_timeout = 120 },
  "client:model"
)
local floating_windows, normal_windows = 0, 0
for _, window in ipairs(vim.api.nvim_list_wins()) do
  local config = vim.api.nvim_win_get_config(window)
  if config.relative == "" then
    normal_windows = normal_windows + 1
  else
    floating_windows = floating_windows + 1
    assert(config.height >= vim.o.lines - 8, "commit plan did not use the available vertical space")
    local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(window))
    if name:find("AI Conventional Commit Plan", 1, true) then
      assert(vim.api.nvim_get_option_value("wrap", { win = window }), "commit messages do not wrap")
    end
  end
end
assert(normal_windows == 1, "commit plan changed the normal window layout")
assert(floating_windows == 2, "commit plan did not open two floating windows")
local preview_found = false
for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_get_name(buffer):find("AI Commit Unit Preview", 1, true) then
    local preview = table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
    preview_found = preview:find("@@", 1, true) ~= nil
  end
end
assert(preview_found, "hunk diff was not shown in the preview split")
local plan_buffer = vim.api.nvim_get_current_buf()
local function press(lhs)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(plan_buffer, "n")) do
    if map.lhs == lhs then
      map.callback()
      return
    end
  end
  error("missing mapping: " .. lhs)
end
local saved_select, saved_input = vim.ui.select, vim.ui.input
vim.ui.select = function(_, _, callback)
  callback("description")
end
vim.ui.input = function(_, callback)
  callback("directly edited")
end
press("m")
assert(table.concat(vim.api.nvim_buf_get_lines(plan_buffer, 0, -1, false), "\n"):find("directly edited", 1, true))
for row, line in ipairs(vim.api.nvim_buf_get_lines(plan_buffer, 0, -1, false)) do
  if line:find(snapshot.units[1].id, 1, true) then
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    break
  end
end
vim.ui.select = function(items, _, callback)
  callback(items[1])
end
press("M")
vim.ui.select, vim.ui.input = saved_select, saved_input
local regeneration_input
vim.system = function(_, opts, callback)
  regeneration_input = vim.json.decode(vim.json.decode(opts.stdin).messages[1].content)
  callback({
    code = 0,
    stdout = vim.json.encode({
      stop_reason = "end_turn",
      content = {
        {
          type = "text",
          text = '{"messages":[{"group":1,"type":"docs","description":"regenerated group","units":[]}]}',
        },
      },
    }),
  })
end
press("r")
assert(vim.wait(1000, function()
  return table.concat(vim.api.nvim_buf_get_lines(plan_buffer, 0, -1, false), "\n"):find("regenerated group", 1, true)
    ~= nil
end))
vim.system = original_system
assert(#regeneration_input.groups == 1 and #regeneration_input.groups[1].changes == 2)
press("e")
local moved = vim.json.decode(table.concat(vim.api.nvim_buf_get_lines(plan_buffer, 0, -1, false), "\n"))
assert(#moved.commits == 1 and #moved.commits[1].units == 2, "move did not remove empty source commit")
vim.cmd("AICommitDiscard")
vim.api.nvim_buf_delete(plan_buffer, { force = true })
helpers.show_plan(plan, snapshot)
plan_buffer = vim.api.nvim_get_current_buf()
press("e")
local edited = vim.json.decode(table.concat(vim.api.nvim_buf_get_lines(plan_buffer, 0, -1, false), "\n"))
edited.commits[1].description = "edited message"
edited.commits[1].units, edited.commits[2].units = edited.commits[2].units, edited.commits[1].units
vim.api.nvim_buf_set_lines(plan_buffer, 0, -1, false, { vim.json.encode(edited) })
local original_select = vim.ui.select
vim.ui.select = function()
  error("saving edits must not create commits")
end
vim.cmd("AICommitConfirm")
vim.ui.select = original_select
assert(not vim.bo[plan_buffer].modifiable, "review remained editable")
local reviewed = table.concat(vim.api.nvim_buf_get_lines(plan_buffer, 0, -1, false), "\n")
assert(reviewed:find("edited message", 1, true), "edited message missing from review")
press("e")
vim.api.nvim_buf_set_lines(plan_buffer, 0, -1, false, { "invalid JSON" })
vim.cmd("AICommitDiscard")
assert(
  table.concat(vim.api.nvim_buf_get_lines(plan_buffer, 0, -1, false), "\n") == reviewed,
  "discard changed the plan"
)
vim.api.nvim_buf_delete(vim.api.nvim_get_current_buf(), { force = true })

local first_stage = helpers.stage_unit(plan[1].resolved_units[1], snapshot.root)
assert(first_stage.code == 0, first_stage.stderr)
local first_commit = vim
  .system({
    "git",
    "-C",
    snapshot.root,
    "commit",
    "--no-gpg-sign",
    "-m",
    "docs: first",
  }, { text = true })
  :wait()
assert(first_commit.code == 0, first_commit.stderr)

local second_stage = helpers.stage_unit(plan[2].resolved_units[1], snapshot.root)
assert(second_stage.code == 0, second_stage.stderr)
local second_commit = vim
  .system({
    "git",
    "-C",
    snapshot.root,
    "commit",
    "--no-gpg-sign",
    "-m",
    "docs: second",
  }, { text = true })
  :wait()
assert(second_commit.code == 0, second_commit.stderr)

local remaining = vim.system({ "git", "-C", snapshot.root, "diff", "HEAD" }, { text = true }):wait()
assert(remaining.code == 0, remaining.stderr)
assert(remaining.stdout == "", remaining.stdout)
print("PASS: ai-commit hunk staging")
