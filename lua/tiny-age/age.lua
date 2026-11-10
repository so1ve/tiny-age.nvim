local Config = require("tiny-age.config")
local Process = require("tiny-age.process")

local M = {}

function M.decrypt(path)
  local cmd = { vim.fn.expand(Config.options.age), "--decrypt" }
  for _, identity in ipairs(Config.options.identities) do
    vim.list_extend(cmd, { "--identity", vim.fn.expand(identity) })
  end
  table.insert(cmd, path)
  return Process.run(cmd)
end

function M.encrypt(path, text, armored)
  local recipients = Config.options.recipients
  if type(recipients) == "function" then
    recipients = recipients(path)
  end

  if not vim.islist(recipients) then
    error("`recipients` must supply a list of public keys for " .. path)
  end

  local cmd = { vim.fn.expand(Config.options.age), "--encrypt" }
  for _, recipient in ipairs(recipients) do
    vim.list_extend(cmd, { "--recipient", recipient })
  end

  if armored then
    table.insert(cmd, "--armor")
  end

  return Process.run(cmd, text)
end

return M
