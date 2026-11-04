local Config = require("tiny-age.config")

local M = {}

local function expand(path)
  return vim.fn.expand(path)
end

local function run(args, opts)
  local conf = Config.options
  local executable = expand(conf.age)

  if vim.fn.executable(executable) == 0 then
    return nil,
      ("age executable not found: %s\nAdd age to PATH and restart Neovim, or set `age` in tiny-age.setup()"):format(
        conf.age
      )
  end

  local cmd = { executable }
  vim.list_extend(cmd, args)

  local ok, process = pcall(vim.system, cmd, opts or { text = false })
  if not ok then
    return nil, ("could not run %s: %s"):format(conf.age, tostring(process))
  end

  local result = process:wait()
  if result.code ~= 0 then
    local message = vim.trim(result.stderr or "")
    return nil, message ~= "" and message or ("age exited with status %d"):format(result.code)
  end

  return result.stdout or ""
end

local function add_identities(args)
  for _, identity in ipairs(Config.options.identities) do
    table.insert(args, "--identity")
    table.insert(args, expand(identity))
  end
end

local function add_recipients(args)
  local count = #args

  for _, recipient in ipairs(Config.options.recipients) do
    table.insert(args, "--recipient")
    table.insert(args, recipient)
  end

  for _, path in ipairs(Config.options.recipient_files) do
    table.insert(args, "--recipients-file")
    table.insert(args, expand(path))
  end

  if #args == count and Config.options.encrypt_to_identity then
    add_identities(args)
  end

  if #args == count then
    return false
  end

  return true
end

function M.decrypt(path)
  local args = { "--decrypt" }
  add_identities(args)
  table.insert(args, path)
  return run(args)
end

function M.encrypt(text, armored)
  local args = { "--encrypt" }

  if not add_recipients(args) then
    return nil,
      "no recipients configured\n"
        .. "Set `recipients`, `recipient_files`, or `encrypt_to_identity` in tiny-age.setup()"
  end

  if armored then
    table.insert(args, "--armor")
  end

  return run(args, { stdin = text, text = false })
end

return M
