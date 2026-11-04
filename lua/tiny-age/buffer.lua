local api = vim.api

local Age = require("tiny-age.age")
local Common = require("tiny-age.common")
local Config = require("tiny-age.config")
local Filesystem = require("tiny-age.filesystem")

local M = {}

local function notify(message, level)
  vim.notify("tiny-age: " .. message, level or vim.log.levels.INFO)
end

local function set_private_options(buf)
  vim.bo[buf].swapfile = false
  vim.bo[buf].undofile = false
  vim.bo[buf].fixendofline = false
end

local function group_name(buf)
  return "tiny-age.buffer." .. buf
end

local function detach_write_command(buf)
  pcall(api.nvim_del_augroup_by_name, group_name(buf))
end

local function write(buf, path)
  path = Common.normalize_path(path ~= "" and path or Common.buffer_path(buf))
  local text = Common.lines_to_text(buf)

  if text:find("\0", 1, true) then
    error("tiny-age: binary content cannot be encrypted safely")
  end

  local ciphertext, encrypt_error = Age.encrypt(text, vim.b[buf].tiny_age_armored)
  if ciphertext == nil then
    error("tiny-age: encryption failed\n" .. encrypt_error)
  end

  local ok, write_error = Filesystem.atomic_write(path, ciphertext)
  if not ok then
    error("tiny-age: could not write " .. path .. "\n" .. write_error)
  end

  vim.bo[buf].modified = false
end

local function attach_write_command(buf)
  local group = api.nvim_create_augroup(group_name(buf), { clear = true })
  api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = buf,
    callback = function(event)
      write(buf, event.match)
    end,
  })
end

local function setup_buffer(buf, armored)
  set_private_options(buf)
  vim.bo[buf].buftype = "acwrite"
  vim.b[buf].tiny_age_armored = armored
  attach_write_command(buf)
end

local function set_filetype(buf, path, lines)
  local filetype = vim.filetype.match({
    filename = Common.decrypted_name(path, Config.options.suffixes),
    contents = lines,
  })

  if filetype then
    vim.bo[buf].filetype = filetype
  end
end

local function show_read_error(buf, path, message)
  local lines = {
    "Could not decrypt " .. vim.fs.basename(path),
    "",
  }
  vim.list_extend(lines, vim.split(message, "\n", { plain = true }))

  detach_write_command(buf)
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = "nowrite"
  vim.bo[buf].filetype = ""
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false

  vim.schedule(function()
    notify("could not decrypt " .. path .. "\n" .. message, vim.log.levels.ERROR)
  end)
end

local function new(buf, path)
  path = Common.normalize_path(path)
  setup_buffer(buf, Config.options.new_file_armor)
  set_filetype(buf, path, { "" })
  vim.bo[buf].endofline = true
end

local function read(buf, path)
  path = Common.normalize_path(path)
  set_private_options(buf)

  if vim.fn.filereadable(path) == 0 then
    new(buf, path)
    return
  end

  local armored, header_error = Filesystem.read_header(path)
  if armored == nil then
    show_read_error(buf, path, header_error)
    return
  end

  local plaintext, decrypt_error = Age.decrypt(path)
  if plaintext == nil then
    show_read_error(buf, path, decrypt_error)
    return
  end

  if plaintext:find("\0", 1, true) then
    show_read_error(buf, path, "decrypted content is binary and cannot be edited safely")
    return
  end

  local lines, endofline = Common.text_to_lines(plaintext)
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].endofline = endofline
  vim.bo[buf].modified = false

  setup_buffer(buf, armored)
  set_filetype(buf, path, lines)
end

function M.open(path)
  path = Common.normalize_path(path)
  if vim.fn.filereadable(path) == 0 then
    error("tiny-age: cannot read " .. path)
  end

  local buf = vim.fn.bufadd(path)
  api.nvim_set_current_buf(buf)
  read(buf, path)
end

function M.setup()
  local patterns = {}
  for _, suffix in ipairs(Config.options.suffixes) do
    table.insert(patterns, "*" .. suffix)
  end

  local group = api.nvim_create_augroup("tiny-age", { clear = true })

  if #patterns > 0 then
    api.nvim_create_autocmd("BufReadCmd", {
      group = group,
      pattern = patterns,
      callback = function(event)
        read(event.buf, Common.buffer_path(event.buf))
      end,
    })

    api.nvim_create_autocmd("BufNewFile", {
      group = group,
      pattern = patterns,
      callback = function(event)
        new(event.buf, Common.buffer_path(event.buf))
      end,
    })
  end

  api.nvim_create_user_command("AgeEdit", function(event)
    M.open(event.args)
  end, {
    nargs = 1,
    complete = "file",
    desc = "Edit an age-encrypted file",
    force = true,
  })
end

return M
