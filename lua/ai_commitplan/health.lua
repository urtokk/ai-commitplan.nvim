local M = {}

function M.check()
  vim.health.start("ai-commitplan")
  if vim.fn.has("nvim-0.11") == 1 then
    vim.health.ok("Neovim >= 0.11")
  else
    vim.health.error("Neovim >= 0.11 required")
  end
  for _, executable in ipairs({ "git", "curl" }) do
    if vim.fn.executable(executable) == 1 then
      vim.health.ok(executable .. " found")
    else
      vim.health.error(executable .. " missing")
    end
  end
end

return M
