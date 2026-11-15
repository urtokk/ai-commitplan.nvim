local root = assert(vim.env.LOCAL_CONFIG_TEST_ROOT)
local work = assert(vim.env.AI_COMMIT_TEST_REPO) .. "-execution"
vim.fn.mkdir(work, "p")
vim.opt.runtimepath:prepend(root)
vim.cmd.cd(work)
local helpers = require("ai_commitplan")._test
local function git(...)
  local args = { "git" }
  vim.list_extend(args, { ... })
  local result = vim.system(args, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout)
end
git("-c", "init.templateDir=", "init", "-q")
git("config", "user.name", "Test")
git("config", "user.email", "test@example.invalid")
git("config", "commit.gpgsign", "false")
git("config", "core.hooksPath", work .. "/.git/hooks")
vim.fn.mkdir(work .. "/.git/hooks", "p")
local lines = {}
for index = 1, 120 do
  lines[index] = "line " .. index
end
vim.fn.writefile(lines, "tracked.txt")
git("add", "tracked.txt")
git("commit", "-qm", "test: baseline")
lines[10], lines[100] = "first change", "second change"
vim.fn.writefile(lines, "tracked.txt")
local function plan()
  local snapshot = assert(helpers.collect_snapshot())
  local commits = assert(helpers.parse_plan(
    vim.json.encode({
      commits = {
        { type = "docs", description = "first", units = { snapshot.units[1].id } },
        { type = "docs", description = "second", units = { snapshot.units[2].id } },
      },
    }),
    snapshot.units
  ))
  return commits, snapshot
end
local function run(expect_failure)
  local commits, snapshot = plan()
  local buffer = vim.api.nvim_create_buf(false, true)
  local failed = false
  helpers.execute_plan(commits, snapshot, buffer, function()
    failed = true
  end)
  assert(vim.wait(10000, function()
    return failed or not vim.api.nvim_buf_is_valid(buffer)
  end))
  assert(failed == expect_failure)
  if vim.api.nvim_buf_is_valid(buffer) then
    vim.api.nvim_buf_delete(buffer, { force = true })
  end
end
local original_head = git("rev-parse", "HEAD")
local hook = work .. "/.git/hooks/pre-commit"
vim.fn.writefile({ "#!/bin/sh", "exit 1" }, hook)
assert(vim.fn.setfperm(hook, "rwx------") == 1)
run(true)
assert(git("rev-parse", "HEAD") == original_head, "hook failure created a commit")
assert(git("diff", "--cached") ~= "", "failed staging should remain inspectable")
assert(os.remove(hook))
git("restore", "--staged", ":/")
git("config", "commit.gpgsign", "true")
git("config", "gpg.program", work .. "/missing-gpg")
run(true)
assert(git("rev-parse", "HEAD") == original_head, "signing failure created a commit")
git("config", "commit.gpgsign", "false")
git("restore", "--staged", ":/")
vim.fn.writefile({ "#!/bin/sh", "if test \"$(git log -1 --format=%s)\" = 'docs: first'; then exit 1; fi" }, hook)
assert(vim.fn.setfperm(hook, "rwx------") == 1)
run(true)
assert(git("rev-list", "--count", "HEAD") == "2", "partial failure lost or added commits")
assert(git("log", "-1", "--format=%s") == "docs: first")
assert(git("diff", "--cached") ~= "", "second group must remain staged after failure")
assert(os.remove(hook))
print("PASS: real hook, signing and partial-sequence failures")
