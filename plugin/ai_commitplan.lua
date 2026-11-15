if vim.g.loaded_ai_commitplan then
  return
end
vim.g.loaded_ai_commitplan = true
vim.api.nvim_create_user_command("AICommit", function()
  require("ai_commitplan").create()
end, { desc = "Plan atomic commits with AI" })
